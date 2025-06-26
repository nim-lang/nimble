#[
Name of the file is temporary.
VNext is a new code path for some actions where we assume solver is SAT and declarative parser are enabled.
The first thing we do, is to try to resolve Nim assuming there is no Nim installed (so we cant fallback to the vm parser to read deps)
After we resolve nim, we try to resolve the dependencies for a root package. Root package can be the package we want to install or the package in the current directory.
]#

#[
  - toRequiresInfo marks the pass as failed if it founds a require inside a control flow statement (or if babel is used)
  - isolate nim selection
   - After we have nim, we can try to resolve the dependencies (later on, only re-run the solver if we needed nim in the step above)
  - Once we have the graph solved. We can proceed with the action.

]#
import std/[sequtils, sets, options, os, strutils, tables, strformat]
import nimblesat, packageinfotypes, options, version, declarativeparser, packageinfo, common,
  nimenv, lockfile, cli, downloadnim, packageparser, tools, nimscriptexecutor, packagemetadatafile,
  displaymessages, packageinstaller, reversedeps, developfile, urls

proc debugSATResult*(options: Options) =
  # return
  echo "=== DEBUG SAT RESULT ==="
  echo "Called from: ", getStackTrace()[^2]
  let satResult = options.satResult
  echo "--------------------------------"
  echo "Pass: ", satResult.pass
  if satResult.nimResolved.pkg.isSome:
    echo "Selected Nim: ", satResult.nimResolved.pkg.get.basicInfo.name, " ", satResult.nimResolved.version
  else:
    echo "No Nim selected"
  echo "Declarative parser failed: ", satResult.declarativeParseFailed
  if satResult.declarativeParseFailed:
    echo "Declarative parser error lines: ", satResult.declarativeParserErrorLines
 
  if satResult.rootPackage.hasLockFile(options):
    echo "Root package has lock file: ", satResult.rootPackage.myPath.parentDir() / "nimble.lock"
  else:
    echo "Root package does not have lock file"
  echo "Root package: ", satResult.rootPackage.basicInfo.name, " ", satResult.rootPackage.basicInfo.version, " ", satResult.rootPackage.myPath
  echo "Root requires: ", satResult.rootPackage.requires.mapIt(it.name & " " & $it.ver)
  echo "Solved packages: ", satResult.solvedPkgs.mapIt(it.pkgName & " " & $it.version & " " & $it.deps.mapIt(it.pkgName))
  echo "Solution as Packages Info: ", satResult.pkgs.mapIt(it.basicInfo.name & " " & $it.basicInfo.version)
  if options.action.typ == actionUpgrade:
    echo "Upgrade versions: ", options.action.packages.mapIt(it.name & " " & $it.ver)
    echo "RESULT REVISIONS ", satResult.pkgs.mapIt(it.basicInfo.name & " " & $it.metaData.vcsRevision)
    echo "PKG LIST REVISIONS ", satResult.pkgList.mapIt(it.basicInfo.name & " " & $it.metaData.vcsRevision)
  echo "Packages to install: ", satResult.pkgsToInstall
  echo "Installed pkgs: ", satResult.pkgs.mapIt(it.basicInfo.name)
  echo "Build pkgs: ", satResult.buildPkgs.mapIt(it.basicInfo.name)
  echo "Packages url: ", satResult.pkgs.mapIt(it.metaData.url)
  echo "Package list: ", satResult.pkgList.mapIt(it.basicInfo.name)
  echo "PkgList path: ", satResult.pkgList.mapIt(it.myPath.parentDir)
  echo "Nimbledir: ", options.getNimbleDir()
  echo "Nimble Action: ", options.action.typ
  if options.action.typ == actionDevelop:
    echo "Path: ", options.action.packages.mapIt(it.name)
    echo "Dev actions: ", options.action.devActions.mapIt(it.actionType)
    echo "Dependencies: ", options.action.packages.mapIt(it.name)
    for devAction in options.action.devActions:
      echo "Dev action: ", devAction.actionType
      echo "Argument: ", devAction.argument
  echo "--------------------------------"

proc nameMatches(pkg: PackageInfo, pv: PkgTuple, options: Options): bool =
  pkg.basicInfo.name.toLowerAscii() == pv.resolveAlias(options).name.toLowerAscii() or pkg.metaData.url == pv.name

proc nameMatches*(pkg: PackageInfo, name: string, options: Options): bool =
  let resolvedName = resolveAlias(name, options).toLowerAscii()
  let pkgName = pkg.basicInfo.name.toLowerAscii()
  let pkgUrl = pkg.metaData.url.toLowerAscii()
  
  if pkgName == resolvedName or pkgUrl == name.toLowerAscii():
    return true
  
  # For GitHub URLs, extract repository name and match
  if name.contains("github.com/") and name.contains("/"):
    let repoName = name.split("/")[^1].replace(".git", "").toLowerAscii()
    if pkgName == repoName:
      return true
  
  return false

proc getSolvedPkg*(satResult: SATResult, pkgInfo: PackageInfo): SolvedPackage =
  for solvedPkg in satResult.solvedPkgs:
    if pkgInfo.basicInfo.name.toLowerAscii() == solvedPkg.pkgName.toLowerAscii(): #No need to check version as they should match by design
      return solvedPkg
  raise newNimbleError[NimbleError]("Package not found in solution: " & $pkgInfo.basicInfo.name & " " & $pkgInfo.basicInfo.version)

proc getPkgInfoFromSolution(satResult: SATResult, pv: PkgTuple, options: Options): PackageInfo =
  for pkg in satResult.pkgs:
    if pv.isNim and pkg.basicInfo.name.isNim and pkg.basicInfo.version.withinRange(pv.ver): return pkg 
    if nameMatches(pkg, pv, options) and pkg.basicInfo.version.withinRange(pv.ver):
      return pkg
  options.debugSATResult()
  raise newNimbleError[NimbleError]("Package not found in solution: " & $pv)

proc getPkgInfoFromSolved*(satResult: SATResult, solvedPkg: SolvedPackage, options: Options): PackageInfo =
  for pkg in satResult.pkgs.toSeq:
    if nameMatches(pkg, solvedPkg.pkgName, options):
      return pkg
  for pkg in satResult.pkgList.toSeq: 
    #For the pkg list we need to check the version as there may be multiple versions of the same package
    if nameMatches(pkg, solvedPkg.pkgName, options) and pkg.basicInfo.version == solvedPkg.version:
      return pkg
  
  options.debugSATResult()
  raise newNimbleError[NimbleError]("Package not found in solution: " & $solvedPkg.pkgName & " " & $solvedPkg.version)

proc displaySatisfiedMsg*(solvedPkgs: seq[SolvedPackage], pkgToInstall: seq[(string, Version)], options: Options) =
  if options.verbosity == LowPriority:
    for pkg in solvedPkgs:
      if pkg.pkgName notin pkgToInstall.mapIt(it[0]):
        for req in pkg.requirements:
          displayInfo(pkgDepsAlreadySatisfiedMsg(req), MediumPriority)

proc getNimFromSystem*(options: Options): Option[PackageInfo] =
  # --nim:<path> takes priority over system nim but its only forced if we also specify useSystemNim
  # Just filename, search in PATH - nim_temp shortcut
  var pnim = ""
  if options.nimBin.isSome:
    pnim = findExe(options.nimBin.get.path)
  else:
    pnim = findExe("nim")
  if pnim != "": 
    let dir = pnim.parentDir.parentDir
    return some getPkgInfoFromDirWithDeclarativeParser(dir, options)
  return none(PackageInfo)

proc enableFeatures*(rootPackage: var PackageInfo, options: var Options) =
  for feature in options.features:
    if feature in rootPackage.features:
      rootPackage.requires &= rootPackage.features[feature]
  for pkgName, activeFeatures in rootPackage.activeFeatures:
    appendGloballyActiveFeatures(pkgName[0], activeFeatures)
  
  #If root is a development package, we need to activate it as well:
  if rootPackage.isDevelopment(options) and "dev" in rootPackage.features:
    rootPackage.requires &= rootPackage.features["dev"]
    appendGloballyActiveFeatures(rootPackage.basicInfo.name, @["dev"])

proc resolveNim*(rootPackage: PackageInfo, pkgList: seq[PackageInfo], options: var Options): NimResolved =
  #TODO if we are able to resolve the packages in one go, we should not re-run the solver in the next step.
  #TODO Introduce the concept of bootstrap nimble where we detect a failure in the declarative parser and fallback to a concrete nim version to re-run the nim selection with the vm parser
  let systemNimPkg = getNimFromSystem(options)
  if options.useSystemNim:
    if systemNimPkg.isSome:
      return NimResolved(pkg: some(systemNimPkg.get), version: systemNimPkg.get.basicInfo.version)
    else:
      raise newNimbleError[NimbleError]("No system nim found") 
  
  #We assume we dont have an available nim yet  
  var pkgListDecl = 
    pkgList
    .mapIt(it.toRequiresInfo(options))
  if systemNimPkg.isSome:
    pkgListDecl.add(systemNimPkg.get)

  options.satResult.pkgList = pkgListDecl.toHashSet()
  
  #If there is a lock file we should use it straight away (if the user didnt specify --useSystemNim)
  let lockFile = options.lockFile(rootPackage.myPath.parentDir())

  if options.hasNimInLockFile(rootPackage.myPath.parentDir()):
    if options.useSystemNim and systemNimPkg.isSome:
      return NimResolved(pkg: some(systemNimPkg.get), version: systemNimPkg.get.basicInfo.version)
    else:
      for name, dep in lockFile.getLockedDependencies.lockedDepsFor(options):
        if name.isNim:
          # echo "Found Nim in lock file: ", name, " ", dep.version
          #Test if the version in the lock is the same as in the system nim (in case devel is set in the lock file and system nim is devel)
          if systemNimPkg.isSome and dep.version == systemNimPkg.get.basicInfo.version:
            return NimResolved(pkg: some(systemNimPkg.get), version: systemNimPkg.get.basicInfo.version)
          return NimResolved(version: dep.version)
  
  let runSolver = options.satResult.pass notin [satLockFile]
  if not runSolver:
    #We come from a lock file with no Nim so we can use any Nim.
    #First system nim
    if systemNimPkg.isSome:
      return NimResolved(pkg: some(systemNimPkg.get), version: systemNimPkg.get.basicInfo.version)
    
    #TODO look in the installed binaries dir
    #If none is found return the latest version by looking at getOfficialReleases
    raise newNimbleError[NimbleError]("No Nim found in lock file and no Nim in the system")

    #Then latest nim release
    # let latestNim = getLatestNimRelease()
    # if latestNim.isSome:
    #   return NimResolved(version: latestNim.get)

  var rootPackage = rootPackage
  options.satResult.pkgs = solvePackages(rootPackage, pkgListDecl, options.satResult.pkgsToInstall, options, options.satResult.output, options.satResult.solvedPkgs)
  if options.satResult.solvedPkgs.len == 0:
    displayError(options.satResult.output)
    raise newNimbleError[NimbleError]("Couldnt find a solution for the packages. Unsatisfiable dependencies. Check there is no contradictory dependencies.")

  var nims = options.satResult.pkgs.toSeq.filterIt(it.basicInfo.name.isNim)
  if nims.len == 0:
    let pkgListDeclNims = pkgListDecl.filterIt(it.basicInfo.name.isNim)
    # echo "PkgListDeclNims ", pkgListDeclNims.mapIt(it.basicInfo.name & " " & $it.basicInfo.version)
    var bestNim: Option[PackageInfo] = none(PackageInfo)
    let solvedNim = options.satResult.solvedPkgs.filterIt(it.pkgName.isNim)
    # echo "SolvedPkgs ", options.satResult.solvedPkgs
    if solvedNim.len > 0:
      
      # echo "Solved nim ", solvedNim[0].version, " len ", solvedNim.len
      result = NimResolved(version: solvedNim[0].version)
      #Now we need to see if any of the nim pkgs is compatible with the Nim from the solution so 
      #we dont download it again.
      for nimPkg in pkgListDeclNims:
        #At this point we lost range information, but we should be ok
        #as we feed the solver with all the versions available already.
        # echo "Checking ", nimPkg.basicInfo.name, " ", nimPkg.basicInfo.version, " ", solvedNim[0].version
        if nimPkg.basicInfo.version == solvedNim[0].version: 
          options.satResult.pkgs.incl(nimPkg)
          return NimResolved(pkg: some(nimPkg), version: nimPkg.basicInfo.version)
      return result

    for pkg in pkgListDeclNims:
      #TODO test if its compatible with the current solution.
      if bestNim.isNone or pkg.basicInfo.version > bestNim.get.basicInfo.version:
        bestNim = some(pkg)
    if bestNim.isSome:
      options.satResult.pkgs.incl(bestNim.get)
      return NimResolved(pkg: some(bestNim.get), version: bestNim.get.basicInfo.version)
    
    #TODO if we ever reach this point, we should just download the latest nim release
    raise newNimbleError[NimbleError]("No Nim found") 
  if nims.len > 1:  
    #Before erroying make sure the version are actually different
    var versions = nims.mapIt(it.basicInfo.version)
    if versions.deduplicate().len > 1:
      raise newNimbleError[NimbleError]("Multiple Nims found " & $nims.mapIt(it.basicInfo)) #TODO this cant be reached
  
  result.pkg = some(nims[0])
  result.version = nims[0].basicInfo.version

proc getSolvedPkgFromInstalledPkgs*(satResult: SATResult, solvedPkg: SolvedPackage, options: Options): Option[PackageInfo] =
  for pkg in satResult.pkgList:
    if pkg.basicInfo.name == solvedPkg.pkgName and pkg.basicInfo.version == solvedPkg.version:
      return some(pkg)
  return none(PackageInfo)

proc solveLockFileDeps*(satResult: var SATResult, pkgList: seq[PackageInfo], options: Options) = 
  let lockFile = options.lockFile(satResult.rootPackage.myPath.parentDir())
  let currentRequires = satResult.rootPackage.requires
  var existingRequires = newSeq[(string, Version)]()
  for name, dep in lockFile.getLockedDependencies.lockedDepsFor(options):
    existingRequires.add((name, dep.version))
  
  # Check for new requirements not in lock file
  # let newRequirements = currentRequires - existingDeps - ["nim"].toHashSet()
  var shouldSolve = false
  for current in currentRequires:
    let currentName = current.name.resolveAlias(options).toLowerAscii()
    var found = false
    for existing in existingRequires:
      let existingName = existing[0].resolveAlias(options).toLowerAscii()
      if currentName == existingName and existing[1].withinRange(current.ver):
        found = true
        break
    if not found:
      if current.name.isNim:
        #ignore if nim wasnt present in the lock file as by default we dont save nim in the lock file
        if not existingRequires.anyIt(it[0].isNim):
          continue
      echo "New requirement detected: ", current.name, " ", current.ver
      shouldSolve = true
      break

  var pkgListDecl = pkgList.mapIt(it.toRequiresInfo(options))

  # if options.action.typ == actionUpgrade:
  #   for upgradePkg in options.action.packages:
  #     for pkg in pkgList:
  #       if pkg.basicInfo.name == upgradePkg.name:
  #         echo "REMOVING ", upgradePkg.name
  #         #Lets reload the pkg
  #         #Remove it from the the package list so it gets reinstalled (aka added to the pkgsToInstall by sat)
  #         pkgListDecl = pkgListDecl.filterIt(it.name != upgradePkg.name)
  #         #We also need to update the root requires with the upgraded version
  #         for req in satResult.rootPackage.requires.mitems:
  #           if req.name == upgradePkg.name:
  #             req.ver = upgradePkg.ver
  #             break
  #         break
  satResult.pkgList = pkgListDecl.toHashSet()
  if shouldSolve:
    echo "New requirements detected, solving ALL requirements fresh: "
    # Create fresh package list and solve ALL requirements
    satResult.pkgs = solvePackages(
      satResult.rootPackage, 
      pkgListDecl, 
      satResult.pkgsToInstall, 
      options, 
      satResult.output, 
      satResult.solvedPkgs
    )
    if satResult.solvedPkgs.len == 0:
      displayError(satResult.output)
      raise newNimbleError[NimbleError]("Couldn't find a solution for the packages.")
  elif options.action.typ == actionUpgrade: #TODO EXTACT THIS TO A FUNCTION
    #[
    Retrocompatibility (goes against SAT in some edge cases)
    When upgrading dep1: Only dep1 should change, dep2 should stay at it is
    We also need to check if the upgraded version adds or removes any other deps.
    
    ]#
    for name, dep in lockFile.getLockedDependencies.lockedDepsFor(options):
      if name.isNim: continue
      let solvedPkg = SolvedPackage(pkgName: name, version: dep.version)
      if options.action.typ == actionUpgrade:
        if solvedPkg.pkgName in satResult.solvedPkgs.mapIt(it.pkgName):
          #We need to remove the initial package from the satResult.solvedPkgs
          satResult.solvedPkgs = satResult.solvedPkgs.filterIt(it.pkgName != name)
          satResult.pkgs = satResult.pkgs.toSeq.filterIt(it.basicInfo.name != name).toHashSet()
        var addedUpgradePkg = false
        for upgradePkg in options.action.packages:
          if upgradePkg.name == name:
            #this is assuming version is special version (likely not correct)
            satResult.pkgsToInstall.add((name, upgradePkg.ver.spe))
            addedUpgradePkg = true
        if not addedUpgradePkg:
          for pkg in pkgListDecl.toHashSet():
            if pkg.basicInfo.name == name and pkg.basicInfo.version == dep.version and pkg.metaData.vcsRevision == dep.vcsRevision:
              satResult.pkgs.incl(pkg)
              break      
        satResult.solvedPkgs.add(solvedPkg)
      # THE CODE BELOW DEALS WITH ADD/REMOVE DIFF DEPS in another SAT pass
      var pkgListDecl = pkgListDecl
      #Finally we need to re-run sat just to check if there are new deps. Although we dont want to update
      #existing deps, only add the new ones.
      for upgradePkg in options.action.packages:
        for pkg in pkgList:
          if pkg.basicInfo.name == upgradePkg.name:
            #Lets reload the pkg
            #Remove it from the the package list so it gets reinstalled (aka added to the pkgsToInstall by sat)
            pkgListDecl = pkgListDecl.filterIt(it.name != upgradePkg.name)
            #We also need to update the root requires with the upgraded version
            for req in satResult.rootPackage.requires.mitems:
              if req.name == upgradePkg.name:
                req.ver = upgradePkg.ver
                break
            break
           
      var tempSatResult = initSATResult(satResult.pass)                
      var newPkgsToInstall = newSeq[(string, Version)]()
      discard solvePackages(
            satResult.rootPackage, 
            pkgListDecl, 
            newPkgsToInstall, 
            options, 
            tempSatResult.output, 
            tempSatResult.solvedPkgs
          )
      for newPkgToInstall in newPkgsToInstall:
        if newPkgToInstall[0] notin satResult.pkgsToInstall.mapIt(it[0]):
          satResult.pkgsToInstall.add(newPkgToInstall)
      #We also need to update the satResult.solvedPkgs with the new packages
      for solvedPkg in tempSatResult.solvedPkgs:
        if solvedPkg.pkgName notin satResult.solvedPkgs.mapIt(it.pkgName):
          satResult.solvedPkgs.add(solvedPkg)
      
      # Also we need to remove the upgraded package from the installed once so it gets redownloaded with 
      # the correct revision
      for upgradePkg in options.action.packages:
        satResult.pkgs = satResult.pkgs.toSeq.filterIt(it.basicInfo.name != upgradePkg.name).toHashSet()

      var actuallyNeededDeps = initHashSet[string]()
      
      # Add all dependencies from the temp solve result (these are what's actually needed)
      for solvedPkg in tempSatResult.solvedPkgs:
        actuallyNeededDeps.incl(solvedPkg.pkgName)
      
      for upgradePkg in options.action.packages:
        actuallyNeededDeps.incl(upgradePkg.name)
      
      # Now filter satResult.solvedPkgs to only include actually needed deps
      satResult.solvedPkgs = satResult.solvedPkgs.filterIt(
        it.pkgName in actuallyNeededDeps or it.pkgName == satResult.rootPackage.basicInfo.name
      )
      satResult.pkgs = satResult.pkgs.toSeq.filterIt(
        it.basicInfo.name in actuallyNeededDeps or it.basicInfo.name == satResult.rootPackage.basicInfo.name
      ).toHashSet()
      satResult.pkgsToInstall = satResult.pkgsToInstall.filterIt(
        it[0] in actuallyNeededDeps
      )

  else:
    # No new requirements and not upgrading
    for name, dep in lockFile.getLockedDependencies.lockedDepsFor(options):
      if name.isNim: continue
      let solvedPkg = SolvedPackage(pkgName: name, version: dep.version)
      satResult.solvedPkgs.add(solvedPkg)
      let depInfo = satResult.getSolvedPkgFromInstalledPkgs(solvedPkg, options)
      if depInfo.isSome:
        satResult.pkgs.incl(depInfo.get)
      else:
        satResult.pkgsToInstall.add((name, dep.version))
    

proc setNimBin*(pkgInfo: PackageInfo, options: var Options) =
  assert pkgInfo.basicInfo.name.isNim
  if options.nimBin.isSome and options.nimBin.get.path == pkgInfo.getRealDir / "bin" / "nim":
    return #We dont want to set the same Nim twice. Notice, this can only happen when installing multiple packages outside of the project dir i.e nimble install pkg1 pkg2 if voth
  options.useNimFromDir(pkgInfo.getRealDir, pkgInfo.basicInfo.version.toVersionRange(), tryCompiling = true)

proc resolveAndConfigureNim*(rootPackage: PackageInfo, pkgList: seq[PackageInfo], options: var Options): NimResolved =
  var resolvedNim = resolveNim(rootPackage, pkgList, options)
  if resolvedNim.pkg.isNone:
    #we need to install it
    let nimPkg = (name: "nim", ver: parseVersionRange(resolvedNim.version))
    #TODO handle the case where the user doesnt want to reuse nim binaries 
    #It can be done inside the installNimFromBinariesDir function to simplify things out by
    #forcing a recompilation of nim.
    let nimInstalled = installNimFromBinariesDir(nimPkg, options)
    if nimInstalled.isSome:
      resolvedNim.pkg = some getPkgInfoFromDirWithDeclarativeParser(nimInstalled.get.dir, options)
      resolvedNim.version = nimInstalled.get.ver
    else:
      raise nimbleError("Failed to install nim")

  return resolvedNim

proc solvePkgsWithVmParserAllowingFallback*(rootPackage: PackageInfo, resolvedNim: NimResolved, pkgList: seq[PackageInfo], options: var Options)=
  var pkgList = 
    pkgList
    .mapIt(it.toRequiresInfo(options))
  pkgList.add(resolvedNim.pkg.get)
  options.satResult.pkgList = pkgList.toHashSet()
  options.satResult.pkgs = solvePackages(rootPackage, pkgList, options.satResult.pkgsToInstall, options, options.satResult.output, options.satResult.solvedPkgs)
  if options.satResult.solvedPkgs.len == 0:
    displayError(options.satResult.output)
    raise newNimbleError[NimbleError]("Couldnt find a solution for the packages. Unsatisfiable dependencies. Check there is no contradictory dependencies.")

proc isInDevelopMode*(pkgInfo: PackageInfo, options: Options): bool =
  if pkgInfo.developFileExists or 
    (not pkgInfo.myPath.startsWith(options.getPkgsDir) and pkgInfo.basicInfo.name != options.satResult.rootPackage.basicInfo.name):
    return true
  return false

proc addReverseDeps*(satResult: SATResult, options: Options) = 
  for solvedPkg in satResult.solvedPkgs:
    if solvedPkg.pkgName.isNim: continue 
    var reverseDepPkg = satResult.getPkgInfoFromSolved(solvedPkg, options)
    # Check if THIS package (the one that depends on others) is a development package
    if reverseDepPkg.isInDevelopMode(options):
      reverseDepPkg.isLink = true
    
    for dep in solvedPkg.deps:
      if dep.pkgName.isNim: continue 
      let depPkg = satResult.getPkgInfoFromSolved(dep, options)      
      addRevDep(options.nimbleData, depPkg.basicInfo, reverseDepPkg)

proc executeHook(dir: string, options: Options, action: ActionType, before: bool) =
  cd dir: # Make sure `execHook` executes the correct .nimble file.
    if not execHook(options, action, before):
      if before:
        raise nimbleError("Pre-hook prevented further execution.")
      else:
        raise nimbleError("Post-hook prevented further execution.")

proc packageExists(pkgInfo: PackageInfo, options: Options):
    Option[PackageInfo] =
  ## Checks whether a package `pkgInfo` already exists in the Nimble cache. If a
  ## package already exists returns the `PackageInfo` of the package in the
  ## cache otherwise returns `none`. Raises a `NimbleError` in the case the
  ## package exists in the cache but it is not valid.
  let pkgDestDir = pkgInfo.getPkgDest(options)
  if not fileExists(pkgDestDir / packageMetaDataFileName):
    return none[PackageInfo]()
  else:
    var oldPkgInfo = initPackageInfo()
    try:
      oldPkgInfo = pkgDestDir.getPkgInfo(options)
    except CatchableError as error:
      raise nimbleError(&"The package inside \"{pkgDestDir}\" is invalid.",
                        details = error)
    fillMetaData(oldPkgInfo, pkgDestDir, true, options)
    return some(oldPkgInfo)


proc installFromDirDownloadInfo(downloadDir: string, url: string, options: Options): PackageInfo = 

  let dir = downloadDir
  # Handle pre-`install` hook.
  executeHook(dir, options, actionInstall, before = true)

  var pkgInfo = getPkgInfo(dir, options)
  var depsOptions = options
  depsOptions.depsOnly = false

  display("Installing", "$1@$2" %
    [pkgInfo.basicInfo.name, $pkgInfo.basicInfo.version],
    priority = MediumPriority)

  let oldPkg = pkgInfo.packageExists(options)
  if oldPkg.isSome:
    # In the case we already have the same package in the cache then only merge
    # the new package special versions to the old one.
    displayWarning(pkgAlreadyExistsInTheCacheMsg(pkgInfo), MediumPriority)
    var oldPkg = oldPkg.get
    oldPkg.metaData.specialVersions.incl pkgInfo.metaData.specialVersions
    saveMetaData(oldPkg.metaData, oldPkg.getNimbleFileDir, changeRoots = false)
    return oldPkg

  let pkgDestDir = pkgInfo.getPkgDest(options)

  # Fill package Meta data
  pkgInfo.metaData.url = url
  pkgInfo.isLink = false

  # Don't copy artifacts if project local deps mode and "installing" the top
  # level package.
  if not (options.localdeps and options.isInstallingTopLevel(dir)): #Unnecesary check
    createDir(pkgDestDir)
    # Copy this package's files based on the preferences specified in PkgInfo.
    var filesInstalled: HashSet[string]
    iterInstallFiles(pkgInfo.getNimbleFileDir(), pkgInfo, options,
      proc (file: string) =
        createDir(changeRoot(pkgInfo.getNimbleFileDir(), pkgDestDir, file.splitFile.dir))
        let dest = changeRoot(pkgInfo.getNimbleFileDir(), pkgDestDir, file)
        filesInstalled.incl copyFileD(file, dest)
    )

    # Copy the .nimble file.
    let dest = changeRoot(pkgInfo.myPath.splitFile.dir, pkgDestDir,
                          pkgInfo.myPath)
    filesInstalled.incl copyFileD(pkgInfo.myPath, dest)
    pkgInfo.myPath = dest
    pkgInfo.metaData.files = filesInstalled.toSeq

    saveMetaData(pkgInfo.metaData, pkgDestDir)
  else:
    display("Warning:", "Skipped copy in project local deps mode", Warning)

  pkgInfo.isInstalled = true
  displaySuccess(pkgInstalledMsg(pkgInfo.basicInfo.name), MediumPriority)
  pkgInfo

proc activateSolvedPkgFeatures*(satResult: SATResult, options: Options) =
  for pkg in satResult.pkgs:
    for pkgTuple, activeFeatures in pkg.activeFeatures:
      let pkgWithFeature = satResult.getPkgInfoFromSolution(pkgTuple, options)
      appendGloballyActiveFeatures(pkgWithFeature.basicInfo.name, activeFeatures)

#We could cache this info in the satResult (if called multiple times down the road)
proc getDepsPkgInfo(satResult: SATResult, pkgInfo: PackageInfo, options: Options): seq[PackageInfo] = 
  for solvedPkg in pkgInfo.requires:
    let depInfo = getPkgInfoFromSolution(satResult, solvedPkg, options)
    result.add(depInfo)

proc expandPaths*(pkgInfo: PackageInfo, options: Options): seq[string] =
  var pkgInfo = pkgInfo.toFullInfo(options) #TODO is this needed in VNEXT? I dont think so
  if options.isVNext: 
    pkgInfo = pkgInfo.toRequiresInfo(options)
  let baseDir = pkgInfo.getRealDir()
  result = @[baseDir]
  # Also add srcDir if it exists and is different from baseDir
  if pkgInfo.srcDir != "":
    let srcPath = pkgInfo.getNimbleFileDir() / pkgInfo.srcDir
    if srcPath != baseDir and dirExists(srcPath):
      result.add srcPath
  
  for relativePath in pkgInfo.paths:
    let path = baseDir & "/" & relativePath
    if path.isSubdirOf(baseDir):
      result.add path

proc getPathsToBuildFor*(satResult: SATResult, pkgInfo: PackageInfo, recursive: bool, options: Options): HashSet[string] =
  for depInfo in getDepsPkgInfo(satResult, pkgInfo, options):
    for path in depInfo.expandPaths(options):
      result.incl(path)
    if recursive:
      for path in satResult.getPathsToBuildFor(depInfo, recursive = true, options):
        result.incl(path)
  result.incl(pkgInfo.expandPaths(options))

proc getPathsAllPkgs*(options: Options): HashSet[string] =
  let satResult = options.satResult
  for pkg in satResult.pkgs:
    for path in pkg.expandPaths(options):
      result.incl(path)

proc getNimBin(satResult: SATResult): string =
  #TODO change this so nim is passed as a parameter but we also need to change getPkgInfo so for the time being its also in options
  if satResult.nimResolved.pkg.isSome:
    let nimPkgInfo = satResult.nimResolved.pkg.get
    var binaryPath = "bin" / "nim"
    when defined(windows):
      binaryPath &= ".exe" 
    return nimPkgInfo.getNimbleFileDir() / binaryPath
  else:
    raise newNimbleError[NimbleError]("No Nim found")

proc buildFromDir(pkgInfo: PackageInfo, paths: HashSet[string],
                  args: seq[string], options: Options) =
  ## Builds a package as specified by ``pkgInfo``.
  # Handle pre-`build` hook.
  let
    realDir = pkgInfo.getRealDir()
    pkgDir = pkgInfo.myPath.parentDir()

  cd pkgDir: # Make sure `execHook` executes the correct .nimble file.
    if not execHook(options, actionBuild, true):
      raise nimbleError("Pre-hook prevented further execution.")

  if pkgInfo.bin.len == 0:
    raise nimbleError(
        "Nothing to build. Did you specify a module to build using the" &
        " `bin` key in your .nimble file?")

  var
    binariesBuilt = 0
    args = args
  args.add "-d:NimblePkgVersion=" & $pkgInfo.basicInfo.version
  for path in paths:
      args.add("--path:" & path.quoteShell)
  if options.verbosity >= HighPriority:
    # Hide Nim hints by default
    args.add("--hints:off")
  if options.verbosity == SilentPriority:
    # Hide Nim warnings
    args.add("--warnings:off")
  if options.noColor:
    # Disable coloured output
    args.add("--colors:off")

  if options.features.len > 0 and not options.useDeclarativeParser:
    raise nimbleError("Features are only supported when using the declarative parser")

  for feature in options.features: #Features enabled with the cli    
    let featureStr = &"features.{pkgInfo.basicInfo.name}.{feature}"
    # displayInfo &"Adding feature {featureStr}", priority = HighPriority
    args.add &"-d:{featureStr}"
  
  # displayInfo &"All active features: {getGloballyActiveFeatures()}", priority = HighPriority
  for featureStr in getGloballyActiveFeatures():
    args.add &"-d:{featureStr}"

  let binToBuild =
    # Only build binaries specified by user if any, but only if top-level package,
    # dependencies should have every binary built.
    if options.isInstallingTopLevel(pkgInfo.myPath.parentDir()):
      options.getCompilationBinary(pkgInfo).get("")
    else: ""

  for bin, src in pkgInfo.bin:
    # Check if this is the only binary that we want to build.
    if binToBuild.len != 0 and binToBuild != bin:
      if bin.extractFilename().changeFileExt("") != binToBuild:
        continue

    let outputDir = pkgInfo.getOutputDir("")
    if dirExists(outputDir):
      if fileExists(outputDir / bin):
        if not pkgInfo.needsRebuild(outputDir / bin, realDir, options):
          display("Skipping", "$1/$2 (up-to-date)" %
                  [pkginfo.basicInfo.name, bin], priority = HighPriority)
          binariesBuilt.inc()
          continue
    else:
      createDir(outputDir)

    # Check if we can copy an existing binary from source directory when --noRebuild is used
    if options.action.typ in {actionInstall, actionPath, actionUninstall, actionDevelop, actionUpgrade, actionLock, actionAdd} and 
       options.action.noRebuild:
      # When installing from a local directory, check for binary in the original directory
      let sourceBinary = 
        if options.startDir != pkgDir:
          options.startDir / bin
        else:
          pkgDir / bin
      
      if fileExists(sourceBinary):
        # Check if the source binary is up-to-date
        if not pkgInfo.needsRebuild(sourceBinary, realDir, options):
          let targetBinary = outputDir / bin
          display("Skipping", "$1/$2 (up-to-date)" %
                  [pkginfo.basicInfo.name, bin], priority = HighPriority)
          copyFile(sourceBinary, targetBinary)
          when not defined(windows):
            # Preserve executable permissions
            setFilePermissions(targetBinary, getFilePermissions(sourceBinary))
          binariesBuilt.inc()
          continue

    let outputOpt = "-o:" & pkgInfo.getOutputDir(bin).quoteShell
    display("Building", "$1/$2 using $3 backend" %
            [pkginfo.basicInfo.name, bin, pkgInfo.backend], priority = HighPriority)

    # For installed packages, we need to handle srcDir correctly
    let input = 
      if pkgInfo.isInstalled and not pkgInfo.isLink and pkgInfo.srcDir != "":
        # For installed packages with srcDir, the source file is in srcDir
        realDir / pkgInfo.srcDir / src.changeFileExt("nim")
      else:
        # For non-installed packages or packages without srcDir, use realDir directly
        realDir / src.changeFileExt("nim")

    let cmd = "$# $# --colors:$# --noNimblePath $# $# $#" % [
      options.satResult.getNimBin().quoteShell, pkgInfo.backend, if options.noColor: "off" else: "on", join(args, " "),
      outputOpt, input.quoteShell]
    try:
      # echo "***Executing cmd: ", cmd
      doCmd(cmd)
      binariesBuilt.inc()
    except CatchableError as error:
      raise buildFailed(
        &"Build failed for the package: {pkgInfo.basicInfo.name}", details = error)

  if binariesBuilt == 0:
    let binary = options.getCompilationBinary(pkgInfo).get("")
    if binary != "":
      raise nimbleError(binaryNotDefinedInPkgMsg(binary, pkgInfo.basicInfo.name))

    raise nimbleError(
      "No binaries built, did you specify a valid binary name?"
    )

  # Handle post-`build` hook.
  cd pkgDir: # Make sure `execHook` executes the correct .nimble file.
    discard execHook(options, actionBuild, false)

proc createBinSymlink(pkgInfo: PackageInfo, options: Options) =
  var binariesInstalled: HashSet[string]
  let binDir = options.getBinDir()
  let pkgDestDir = pkgInfo.getPkgDest(options)
  if pkgInfo.bin.len > 0 and not pkgInfo.basicInfo.name.isNim:
    # Make sure ~/.nimble/bin directory is created.
    createDir(binDir)
    # Set file permissions to +x for all binaries built,
    # and symlink them on *nix OS' to $nimbleDir/bin/
    for bin, src in pkgInfo.bin:
      let binDest =
        # Issue #308
        if dirExists(pkgDestDir / bin):
          bin & ".out"
        else: bin

      # For develop mode packages, the binary is in the source directory, not installed directory
      let symlinkDest = 
        if pkgInfo.isLink:
          # Develop mode: binary is in the source directory
          pkgInfo.getOutputDir(bin)
        else:
          # Installed package: binary is in the installed directory
          pkgDestDir / binDest

      if not fileExists(symlinkDest):
        raise nimbleError(&"Binary '{bin}' was not found at expected location: {symlinkDest}")
      
      if fileExists(symlinkDest) and not pkgInfo.isLink:
        display("Warning:", ("Binary '$1' was already installed from source" &
                            " directory. Will be overwritten.") % bin, Warning,
                MediumPriority)
      
      if not pkgInfo.isLink:
        createDir((pkgDestDir / binDest).parentDir())
      let symlinkFilename = options.getBinDir() / bin.extractFilename
      binariesInstalled.incl(
        setupBinSymlink(symlinkDest, symlinkFilename, options))

proc solutionToFullInfo*(satResult: SATResult, options: var Options) =
  # for pkg in satResult.pkgs:
  #   if pkg.infoKind != pikFull:   
  #     satResult.pkgs.incl(getPkgInfo(pkg.getNimbleFileDir, options))
  if satResult.rootPackage.infoKind != pikFull: #Likely only needed for the root package
    satResult.rootPackage = getPkgInfo(satResult.rootPackage.getNimbleFileDir, options).toRequiresInfo(options)
    satResult.rootPackage.enableFeatures(options)

proc isRoot(pkgInfo: PackageInfo, satResult: SATResult): bool =
  pkgInfo.basicInfo.name == satResult.rootPackage.basicInfo.name and pkgInfo.basicInfo.version == satResult.rootPackage.basicInfo.version

proc buildPkg*(pkgToBuild: PackageInfo, isRootInRootDir: bool, options: Options) =
  # let paths = getPathsToBuildFor(options.satResult, pkgToBuild, recursive = true, options)
  let paths = getPathsAllPkgs(options)
  # echo "Paths ", paths
  # echo "Requires ", pkgToBuild.requires
  # echo "Package ", pkgToBuild.basicInfo.name
  let flags = if options.action.typ in {actionInstall, actionPath, actionUninstall, actionDevelop}:
                options.action.passNimFlags
              elif options.action.typ in { actionRun, actionBuild, actionDoc, actionCompile, actionCustom }:
                options.getCompilationFlags()
              else:
                @[]
  var pkgToBuild = pkgToBuild
  if isRootInRootDir:
    pkgToBuild.isInstalled = false
  buildFromDir(pkgToBuild, paths, "-d:release" & flags, options)
  # For globally installed packages, always create symlinks
  # Only skip symlinks if we're building the root package in its own directory
  let shouldCreateSymlinks = not isRootInRootDir or options.action.typ == actionInstall
  if shouldCreateSymlinks:
    createBinSymlink(pkgToBuild, options)

proc getVersionRangeFoPkgToInstall(satResult: SATResult, name: string, ver: Version): VersionRange =
  if satResult.rootPackage.basicInfo.name == name and satResult.rootPackage.basicInfo.version == ver:
    #It could be the case that we are installing a special version of a root package
    if name == satResult.rootPackage.basicInfo.name and ver == satResult.rootPackage.basicInfo.version:
      let specialVersion = satResult.rootPackage.getNimbleFileDir().lastPathPart().split("_")[^1]
      if "#" in specialVersion:
        return parseVersionRange(specialVersion)  
  return ver.toVersionRange()
 
proc installPkgs*(satResult: var SATResult, options: Options) =
  #At this point the packages are already downloaded. 
  #We still need to install them aka copy them from the cache to the nimbleDir + run preInstall and postInstall scripts
  #preInstall hook is always executed for the current directory
  let isInRootDir = options.startDir == satResult.rootPackage.myPath.parentDir
  if isInRootDir and options.action.typ == actionInstall:
    executeHook(getCurrentDir(), options, actionInstall, before = true) #likely incorrect if we are not in a nimble dir
  var pkgsToInstall = satResult.pkgsToInstall
  if options.useSystemNim: #Dont install Nim if we are using the system nim (TODO likely we need to dont install it neither if we have a binary set)
    pkgsToInstall = pkgsToInstall.filterIt(not it[0].isNim)
   #If we are not in the root folder, means user is installing a package globally so we need to install root
  var installedPkgs = initHashSet[PackageInfo]()
  # echo "isInRootDir ", isInRootDir, " startDir ", options.startDir, " rootDir ", satResult.rootPackage.myPath.parentDir
  if options.action.typ == actionInstall: #only install action install the root package: #skip root when in localdeps mode and in rootdir
    pkgsToInstall.add((name: satResult.rootPackage.basicInfo.name, ver: satResult.rootPackage.basicInfo.version))
  else:
    #Root can be assumed as installed as the only global action one can do is install
    installedPkgs.incl(satResult.rootPackage)
    
  displaySatisfiedMsg(satResult.solvedPkgs, pkgsToInstall, options)
  #If package is in develop mode, we dont need to install it.
  var newlyInstalledPkgs = initHashSet[PackageInfo]()
  let rootName = satResult.rootPackage.basicInfo.name
  # options.debugSATResult()
  for (name, ver) in pkgsToInstall:
    let verRange = satResult.getVersionRangeFoPkgToInstall(name, ver)
    var pv = (name: name, ver: verRange)
    var installedPkgInfo: PackageInfo
    var wasNewlyInstalled = false
    if pv.name == rootName and (rootName notin installedPkgs.mapIt(it.basicInfo.name) or satResult.rootPackage.hasLockFile(options)): 
      if satResult.rootPackage.developFileExists or options.localdeps:
        # Treat as link package if in develop mode OR local deps mode
        satResult.rootPackage.isInstalled = false
        satResult.rootPackage.isLink = true
        installedPkgInfo = satResult.rootPackage
        wasNewlyInstalled = true
      else:
        # Check if package already exists before installing
        let tempPkgInfo = getPkgInfo(satResult.rootPackage.getNimbleFileDir(), options)
        let oldPkg = tempPkgInfo.packageExists(options)
        installedPkgInfo = installFromDirDownloadInfo(satResult.rootPackage.getNimbleFileDir(), satResult.rootPackage.metaData.url, options).toRequiresInfo(options)
        wasNewlyInstalled = oldPkg.isNone
    else:      
      var dlInfo = getPackageDownloadInfo(pv, options, doPrompt = true)
      var downloadDir = dlInfo.downloadDir / dlInfo.subdir       
      if not dirExists(dlInfo.downloadDir):        
        #The reason for this is that the download cache may have a constrained version
        #this could be improved by creating a copy of the package in the cache dir when downloading
        #and also when enumerating. 
        #Instead of redownload the actual version of the package here. Not important as this only happens per 
        #package once across all nimble projects (even in local mode)
        #But it would still be needed for the lock file case, although we could constraint it. 
        discard downloadFromDownloadInfo(dlInfo, options)
        # dlInfo.downloadDir = downloadPkgResult.dir 
      assert dirExists(downloadDir)
      #TODO this : PackageInfoneeds to be improved as we are redonwloading certain packages
      # Check if package already exists before installing
      let tempPkgInfo = getPkgInfo(downloadDir, options)
      let oldPkg = tempPkgInfo.packageExists(options)
      installedPkgInfo = installFromDirDownloadInfo(downloadDir, dlInfo.url, options).toRequiresInfo(options)
      wasNewlyInstalled = oldPkg.isNone
      if installedPkgInfo.metadata.url == "" and pv.name.isUrl:
        installedPkgInfo.metadata.url = pv.name

    satResult.pkgs.incl(installedPkgInfo)
    installedPkgs.incl(installedPkgInfo)
    if wasNewlyInstalled:
      newlyInstalledPkgs.incl(installedPkgInfo)
  
  #we need to activate the features for the recently installed package
  #so they are activated in the build step
  options.satResult.activateSolvedPkgFeatures(options)

  for pkg in installedPkgs:
    var pkg = pkg
    # fillMetaData(pkg, pkg.getRealDir(), false, options)
    options.satResult.pkgs.incl pkg 

  let buildActions = { actionInstall, actionBuild, actionRun }
  
  # For build action, only build the root package
  # For install action, only build newly installed packages
  let pkgsToBuild = if options.action.typ == actionBuild:
    installedPkgs.toSeq.filterIt(it.isRoot(options.satResult))
  else:
    # Only build packages that were newly installed in this session
    newlyInstalledPkgs.toSeq
  
  for pkgToBuild in pkgsToBuild:
    if pkgToBuild.bin.len == 0:
      if options.action.typ == actionBuild:
        raise nimbleError(
          "Nothing to build. Did you specify a module to build using the" &
          " `bin` key in your .nimble file?")
      else: #Skips building the package if it has no binaries
        continue
    echo "Building package: ", pkgToBuild.basicInfo.name, " at ", pkgToBuild.myPath, " binaries: ", pkgToBuild.bin
    let isRoot = pkgToBuild.isRoot(options.satResult) and isInRootDir
    if options.action.typ in buildActions:
      buildPkg(pkgToBuild, isRoot, options)
      satResult.buildPkgs.add(pkgToBuild)

  satResult.installedPkgs = installedPkgs.toSeq()
  for pkg in satResult.installedPkgs.mitems:
    satResult.pkgs.incl pkg
    
  for pkgInfo in satResult.installedPkgs:
    # Run post-install hook now that package is installed. The `execHook` proc
    # executes the hook defined in the CWD, so we set it to where the package
    # has been installed. Notice for legacy reasons this needs to happen after the build step
    # TODO investigate where it should happen before or after the after build step, I think after is better
    let hookDir = pkgInfo.myPath.splitFile.dir
    if dirExists(hookDir):
      executeHook(hookDir, options, actionInstall, before = false)
    
