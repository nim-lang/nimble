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
import std/[sequtils, sets, options, os, strutils, tables, strformat, algorithm]
import nimblesat, packageinfotypes, options, version, declarativeparser, packageinfo, common,
  nimenv, lockfile, cli, downloadnim, packageparser, tools, nimscriptexecutor, packagemetadatafile,
  displaymessages, packageinstaller, reversedeps, developfile, urls, download

when defined(windows):
  import std/strscans

proc debugSATResult*(options: Options, calledFrom: string) =
  let satResult = options.satResult
  let color = "\e[32m"
  let reset = "\e[0m"
  echo "=== DEBUG SAT RESULT ==="
  echo "Called from: ", calledFrom
  echo "--------------------------------"
  echo color, "Pass: ", reset, satResult.pass
  if satResult.nimResolved.pkg.isSome:
    echo color, "Selected Nim: ", reset, satResult.nimResolved.pkg.get.basicInfo.name, " ", satResult.nimResolved.version
  else:
    echo "No Nim selected"
  echo color, "Bootstrap Nim: ", reset, "isSet: ", satResult.bootstrapNim.nimResolved.pkg.isSome, " version: ", satResult.bootstrapNim.nimResolved.version
  echo color, "Declarative parser failed: ", reset, satResult.declarativeParseFailed
  if satResult.declarativeParseFailed:
    echo color, "Declarative parser error lines: ", reset, satResult.declarativeParserErrorLines
 
  if satResult.rootPackage.hasLockFile(options):
    echo "Root package has lock file: ", satResult.rootPackage.myPath.parentDir() / "nimble.lock"
  else:
    echo "Root package does not have lock file"
  echo color, "Root package: ", reset, satResult.rootPackage.basicInfo.name, " ", satResult.rootPackage.basicInfo.version, " ", satResult.rootPackage.myPath
  echo color, "Root requires: ", reset, satResult.rootPackage.requires.mapIt(it.name & " " & $it.ver)
  echo color, "Solved packages: ", reset, satResult.solvedPkgs.mapIt(it.pkgName & " " & $it.version & " " & $it.deps.mapIt(it.pkgName))
  echo color, "Solution as Packages Info: ", reset, satResult.pkgs.mapIt(it.basicInfo.name & " " & $it.basicInfo.version)
  if options.action.typ == actionUpgrade:
    echo color, "Upgrade versions: ", reset, options.action.packages.mapIt(it.name & " " & $it.ver)
    echo color, "RESULT REVISIONS ", reset, satResult.pkgs.mapIt(it.basicInfo.name & " " & $it.metaData.vcsRevision)
    echo color, "PKG LIST REVISIONS ", reset, satResult.pkgList.mapIt(it.basicInfo.name & " " & $it.metaData.vcsRevision)
  echo color, "Packages to install: ", reset, satResult.pkgsToInstall
  echo color, "Installed pkgs: ", reset, satResult.pkgs.mapIt(it.basicInfo.name)
  echo color, "Build pkgs: ", reset, satResult.buildPkgs.mapIt(it.basicInfo.name)
  echo color, "Packages url: ", reset, satResult.pkgs.mapIt(it.metaData.url)
  echo color, "Package list: ", reset, satResult.pkgList.mapIt(it.basicInfo.name)
  echo color, "PkgList path: ", reset, satResult.pkgList.mapIt(it.myPath.parentDir)
  echo color, "Nimbledir: ", reset, options.getNimbleDir()
  echo color, "Nimble Action: ", reset, options.action.typ
  if options.action.typ == actionDevelop:
    echo color, "Path: ", reset, options.action.packages.mapIt(it.name)
    echo color, "Dev actions: ", reset, options.action.devActions.mapIt(it.actionType)
    echo color, "Dependencies: ", reset, options.action.packages.mapIt(it.name)
    for devAction in options.action.devActions:
      echo color, "Dev action: ", reset, devAction.actionType
      echo color, "Argument: ", reset, devAction.argument
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
  raise newNimbleError[NimbleError]("Package not found in solution: " & $pv)

proc getPkgInfoFromSolved*(satResult: SATResult, solvedPkg: SolvedPackage, options: Options): PackageInfo =
  for pkg in satResult.pkgs.toSeq:
    if nameMatches(pkg, solvedPkg.pkgName, options):
      return pkg
  for pkg in satResult.pkgList.toSeq: 
    #For the pkg list we need to check the version as there may be multiple versions of the same package
    if nameMatches(pkg, solvedPkg.pkgName, options) and pkg.basicInfo.version == solvedPkg.version:
      return pkg
  writeStackTrace()
  options.debugSATResult("getPkgInfoFromSolved")
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
    var effectivePnim = pnim
    when defined(windows):
      if pnim.toLowerAscii().endsWith(".cmd"):
        let nearbyNim = pnim.changeFileExt("") # Remove .cmd extension
        if fileExists(nearbyNim):
          try:
            let scriptContent = readFile(nearbyNim).strip()
            # Extract path from: "`dirname "$0"`\..\nimbinaries\nim-2.2.4\bin\nim.exe" "$@"
            var ignore, pathPath: string
            if scanf(scriptContent, """$*\$*"""", ignore, pathPath):
              var resolvedPath = pnim.parentDir / pathPath.replace("\\", $DirSep)
              normalizePath(resolvedPath)
              if fileExists(resolvedPath):
                effectivePnim = resolvedPath
          except CatchableError:
            discard # Fall back to original pnim
    let dir = effectivePnim.parentDir.parentDir
    try:
      return some getPkgInfoFromDirWithDeclarativeParser(dir, options, nimBin = "") #Can be empty as the code path for nim doesnt need it. 
    except CatchableError:
      discard # Fall back to original pnim
  return none(PackageInfo)

proc enableFeatures*(rootPackage: var PackageInfo, options: var Options) =
  for feature in options.features:
    if feature in rootPackage.features:
      rootPackage.requires &= rootPackage.features[feature]
  for pkgName, activeFeatures in rootPackage.activeFeatures:
    appendGloballyActiveFeatures(pkgName[0], activeFeatures)
  
  #If root is a development package, we need to activate it as well:
  if rootPackage.isTopLevel(options) and ("dev" in rootPackage.features or "patch" in rootPackage.features):
    if "dev" in rootPackage.features:
      rootPackage.requires &= rootPackage.features["dev"]
      appendGloballyActiveFeatures(rootPackage.basicInfo.name, @["dev"])
    if "patch" in rootPackage.features:
      rootPackage.requires &= rootPackage.features["patch"]
      appendGloballyActiveFeatures(rootPackage.basicInfo.name, @["patch"])

proc isSystemNim*(resolvedNim: NimResolved, options: Options): bool =
  if resolvedNim.pkg.isSome:
    let systemNimPkg = getNimFromSystem(options)
    if systemNimPkg.isSome:
      return resolvedNim.pkg.get.basicInfo.version == systemNimPkg.get.basicInfo.version
  return false

proc solvePackagesWithSystemNimFallback*(
    rootPackage: PackageInfo, 
    pkgList: seq[PackageInfo], 
    options: var Options,
    resolvedNim: Option[NimResolved], nimBin: string): HashSet[PackageInfo] {.instrument.} =
  ## Solves packages with system Nim as a hard requirement, falling back to 
  ## solving without it if the first attempt fails due to unsatisfiable dependencies.
  
  var rootPackageWithSystemNim = rootPackage
  var systemNimPass = false
  
  # If there is systemNim, we will try to do a first pass with the systemNim 
  # as a hard requirement. If it fails, we will fallback to 
  # retry without it as a hard requirement. The idea behind it is that a 
  # compatible version of the packages is used for the current nim.
  if resolvedNim.isSome and resolvedNim.get.isSystemNim(options):
    rootPackageWithSystemNim.requires.add(parseRequires("nim " & $resolvedNim.get.version))
    systemNimPass = true

  result = solvePackages(rootPackageWithSystemNim, pkgList, 
                        options.satResult.pkgsToInstall, options, 
                        options.satResult.output, options.satResult.solvedPkgs, nimBin)
  if options.satResult.solvedPkgs.len == 0 and systemNimPass:
    # If the first pass failed, we will retry without the systemNim as a hard requirement
    result = solvePackages(rootPackage, pkgList, 
                          options.satResult.pkgsToInstall, options, 
                          options.satResult.output, options.satResult.solvedPkgs, nimBin)

proc compPkgListByVersion*(a, b: PackageInfo): int =
  if  a.basicInfo.version > b.basicInfo.version: return -1
  elif a.basicInfo.version < b.basicInfo.version: return 1
  else: return 0

proc resolveNim*(rootPackage: PackageInfo, pkgListDecl: seq[PackageInfo], systemNimPkg: Option[PackageInfo], options: var Options): NimResolved {.instrument.} =
  
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
          # Check if the locked version satisfies the current requirement
          let nimRequirement = rootPackage.requires.filterIt(it.name.isNim)
          if nimRequirement.len > 0:
            if not dep.version.withinRange(nimRequirement[0].ver):
              # Lock file nim doesn't match current requirement - need to re-solve
              break
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
  var resolvedNim: Option[NimResolved]  
  if systemNimPkg.isSome:
    resolvedNim = some(NimResolved(pkg: systemNimPkg, version: systemNimPkg.get.basicInfo.version))
  var nimBin: string
  if resolvedNim.isSome:
    nimBin = resolvedNim.get.getNimBin()
  else:
    if options.satResult.bootstrapNim.nimResolved.pkg.isNone:
      let nimPkg = (name: "nim", ver: parseVersionRange(options.satResult.bootstrapNim.nimResolved.version))
      let nimInstalled = installNimFromBinariesDir(nimPkg, options)
      if nimInstalled.isSome:
        options.satResult.bootstrapNim.nimResolved.pkg = some getPkgInfoFromDirWithDeclarativeParser(nimInstalled.get.dir, options, nimBin = "") #Can be empty as the code path for nim doesnt need it. 
      else:
        raise newNimbleError[NimbleError]("Failed to install nim")
    nimBin = options.satResult.bootstrapNim.nimResolved.getNimBin()

  options.satResult.pkgs = solvePackagesWithSystemNimFallback(
      rootPackage, pkgListDecl, options,  resolvedNim, nimBin)
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

proc thereIsNimbleFile*(options: Options): bool =
  return findNimbleFile(getCurrentDir(), error = false, options, warn = false) != ""

proc solveLockFileDeps*(satResult: var SATResult, pkgList: seq[PackageInfo], options: Options, nimBin: string) = 
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
      # echo "New requirement detected: ", current.name, " ", current.ver
      shouldSolve = true
      break

  var pkgListDecl = pkgList.mapIt(it.toRequiresInfo(options, nimBin))

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
  #Do not re-solve if we are outside the project dir (i.e. installing a package globally)
  if not thereIsNimbleFile(options):
    shouldSolve = false

  satResult.pkgList = pkgListDecl.toHashSet()
  if shouldSolve:
    # echo "New requirements detected, solving ALL requirements fresh: "
    # Create fresh package list and solve ALL requirements
    satResult.pkgs = solvePackages(
      satResult.rootPackage, 
      pkgListDecl, 
      satResult.pkgsToInstall, 
      options, 
      satResult.output, 
      satResult.solvedPkgs,
      nimBin
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
            tempSatResult.solvedPkgs,
            nimBin
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
    

proc setNimBin*(pkgInfo: PackageInfo, options: var Options) {.instrument.} =
  assert pkgInfo.basicInfo.name.isNim
  if options.nimBin.isSome and options.nimBin.get.path == pkgInfo.getRealDir / "bin" / "nim":
    return #We dont want to set the same Nim twice. Notice, this can only happen when installing multiple packages outside of the project dir i.e nimble install pkg1 pkg2 if voth
  options.useNimFromDir(pkgInfo.getRealDir, pkgInfo.basicInfo.version.toVersionRange(), tryCompiling = true)

proc setBootstrapNim*(systemNimPkg: Option[PackageInfo], pkgList: seq[PackageInfo], options: var Options) =
  var bootstrapNim: NimResolved
  let nimPkgList = pkgList.filterIt(it.basicInfo.name.isNim)
  #we want to use actual systemNimPkg as bootstrap nim.
  if systemNimPkg.isSome:
    # echo "SETTING BOOTSTRAP NIM TO SYSTEM NIM PKG: ", systemNimPkg.get.basicInfo.name, " ", systemNimPkg.get.basicInfo.version, " path ", systemNimPkg.get.getNimbleFileDir()
    bootstrapNim.pkg = some(systemNimPkg.get)
    bootstrapNim.version = systemNimPkg.get.basicInfo.version
  elif nimPkgList.len > 0: #If no system nim, we use the best nim available (they are ordered by version)
    # echo nimPkgList.mapIt(it.basicInfo.name & " " & $it.basicInfo.version & " path " & it.getNimbleFileDir())
    # echo "SETTING BOOTSTRAP NIM TO: ", nimPkgList[0].basicInfo.name, " ", nimPkgList[0].basicInfo.version, " path ", nimPkgList[0].getNimbleFileDir()
    bootstrapNim.pkg = some(nimPkgList[0])
    bootstrapNim.version = nimPkgList[0].basicInfo.version
  else:
    #if none of the above, we just set the version to be used. We dont want to install a nim until we 
    #are clear that we need to actually use it. In order to pick the version, we get the releases.
    #Notice we should never call setNimBin for it. Rather we should attempt to use it directly.     
    let bestRelease = getOfficialReleases(options).max
    bootstrapNim.version = bestRelease

    # echo "SETTING BOOTSTRAP NIM TO BEST RELEASE: ", bestRelease
    #TODO Only install when we actually need it. Meaning in a subsequent PR when we failed to parse a nimble fail with the declarative parser.
    #Ideally it should be triggered from the declarative parser when it detects the failure. 
    #Important: we need to refactor the code path to the nim parser to make sure we parametrize the Nim instead of setting the bootstrap nim directly, this should never be the case. 
  
  options.satResult.bootstrapNim = BootstrapNim(nimResolved: bootstrapNim, allowToUse: true)

proc getNimBinariesPackages*(options: Options): seq[PackageInfo] =
  for kind, path in walkDir(options.nimBinariesDir):
    if kind == pcDir:
      let nimbleFile = path / "nim.nimble"
      if fileExists(nimbleFile):
        var pkgInfo = getNimPkgInfo(nimbleFile.parentDir, options, nimBin = "") #Can be empty as the code path for nim doesnt need it.
        # Check if directory name indicates a special version (e.g., nim-#devel)
        # The directory name format is "nim-<version>" 
        let dirName = path.extractFilename
        if dirName.startsWith("nim-#"):
          # This is a special version like #devel
          let specialVersionStr = dirName[4..^1]  # Extract "#devel" from "nim-#devel"
          var specialVer = newVersion(specialVersionStr)
          let semanticVer = extractNimVersion(nimbleFile)
          if semanticVer != "":
            specialVer.speSemanticVersion = some(semanticVer)
          pkgInfo.basicInfo.version = specialVer
        result.add pkgInfo 

proc getBootstrapNimResolved*(options: var Options): NimResolved =  
  var pkgList: seq[PackageInfo] = @[] #Should we use the install nim pkgs? In most cases they should already be in the nim binaries dir
  let nimBinariesPackages = getNimBinariesPackages(options).sortedByIt(it.basicInfo.version).reversed()
  pkgList.add(nimBinariesPackages)
  setBootstrapNim(getNimFromSystem(options), pkgList, options)  
  var bootstrapNim = options.satResult.bootstrapNim
  if bootstrapNim.nimResolved.pkg.isNone:   
    let nimInstalled = installNimFromBinariesDir(("nim", bootstrapNim.nimResolved.version.toVersionRange()), options)
    if nimInstalled.isSome:
      bootstrapNim.nimResolved.pkg = some getPkgInfoFromDirWithDeclarativeParser(nimInstalled.get.dir, options, nimBin = "") #Can be empty as the code path for nim doesnt need it. 
    else:
      raise nimbleError("Failed to install nim") #What to do here? Is this ever possible?
  options.satResult.bootstrapNim = bootstrapNim
  return bootstrapNim.nimResolved

proc resolveAndConfigureNim*(rootPackage: PackageInfo, pkgList: seq[PackageInfo], options: var Options, nimBin: string): NimResolved {.instrument.} =
  #Before resolving nim, we bootstrap it, so if we fail resolving it when can use the bootstrapped version.
  #Notice when implemented it would make the second sat pass obsolete.
  let systemNimPkg = getNimFromSystem(options)
  if options.useSystemNim:
    if systemNimPkg.isNone:
      raise newNimbleError[NimbleError]("No system nim found")
    # If there's a lock file, return early - solveLockFileDeps will handle resolution
    # If there's no lock file, we need to run the SAT solver with system nim
    if rootPackage.hasLockFile(options) and not options.disableLockFile:
      return NimResolved(pkg: some(systemNimPkg.get), version: systemNimPkg.get.basicInfo.version)
    # No lock file - run SAT solver with system nim as the resolved nim
    var pkgListDecl = pkgList.mapIt(it.toRequiresInfo(options, nimBin))
    pkgListDecl.add(systemNimPkg.get)
    pkgListDecl.sort(compPkgListByVersion)
    options.satResult.pkgList = pkgListDecl.toHashSet()
    options.satResult.pkgs = solvePackagesWithSystemNimFallback(
        rootPackage, pkgListDecl, options, some(NimResolved(pkg: systemNimPkg, version: systemNimPkg.get.basicInfo.version)), nimBin)
    if options.satResult.solvedPkgs.len == 0:
      displayError(options.satResult.output)
      raise newNimbleError[NimbleError]("Couldnt find a solution for the packages. Unsatisfiable dependencies.")
    return NimResolved(pkg: some(systemNimPkg.get), version: systemNimPkg.get.basicInfo.version)

  # Special case: when installing nim itself globally, we want to install that specific version
  # Don't run SAT solver which would pick a nim for compilation - we want the nim we're installing
  if rootPackage.basicInfo.name.isNim:
    let nimPkg = (name: "nim", ver: parseVersionRange(rootPackage.basicInfo.version))
    let nimInstalled = installNimFromBinariesDir(nimPkg, options)
    if nimInstalled.isSome:
      let resolvedNim = NimResolved(
        pkg: some getPkgInfoFromDirWithDeclarativeParser(nimInstalled.get.dir, options, nimBin = ""), #Can be empty as the code path for nim doesnt need it. 
        version: nimInstalled.get.ver
      )
      # Still need to set bootstrap nim and configure it
      var pkgListDecl = pkgList.mapIt(it.toRequiresInfo(options, resolvedNim.getNimBin()))
      if systemNimPkg.isSome:
        pkgListDecl.add(systemNimPkg.get)
      pkgListDecl.sort(compPkgListByVersion)
      options.satResult.pkgList = pkgListDecl.toHashSet()
      return resolvedNim
    else:
      raise nimbleError("Failed to install nim version " & $rootPackage.basicInfo.version)

  var pkgListDecl =
    pkgList
    .mapIt(it.toRequiresInfo(options, nimBin)) #Notice this could fail to parse, but shouldnt be an issue as it wont be falling back yet. We are only interested in selecting nim
  if systemNimPkg.isSome:
    pkgListDecl.add(systemNimPkg.get)
  #Order the pkglist by version
  pkgListDecl.sort(compPkgListByVersion)

  options.satResult.pkgList = pkgListDecl.toHashSet()
  # setBootstrapNim(systemNimPkg, pkgListDecl, options)
  #TODO NEXT PR
  #At this point, if we failed before to parse the pkglist. We need to reparse with the bootsrapped nim as we may have missed some deps.
  # if options.satResult.declarativeParseFailed:
  #   echo "FAILED TO PARSE THE PKGLIST, REPARSING WITH BOOTSTRAPPED NIM"
  #   debugSatResult(options, "resolveAndConfigureNim")
    
    
  var resolvedNim = resolveNim(rootPackage, pkgListDecl, systemNimPkg, options)
  if resolvedNim.pkg.isNone:
    #we need to install it
    let nimPkg = (name: "nim", ver: parseVersionRange(resolvedNim.version))
    #TODO handle the case where the user doesnt want to reuse nim binaries 
    #It can be done inside the installNimFromBinariesDir function to simplify things out by
    #forcing a recompilation of nim.
    let nimInstalled = installNimFromBinariesDir(nimPkg, options)
    if nimInstalled.isSome:
      resolvedNim.pkg = some getPkgInfoFromDirWithDeclarativeParser(nimInstalled.get.dir, options, nimBin = "") #Can be empty as the code path for nim doesnt need it. 
      resolvedNim.version = nimInstalled.get.ver
    elif rootPackage.basicInfo.name.isNim: #special version/not in releases nim binaries
      resolvedNim.pkg = some rootPackage
      resolvedNim.version = rootPackage.basicInfo.version
    else:      
      raise nimbleError("Failed to install nim")

  return resolvedNim

proc isInDevelopMode*(pkgInfo: PackageInfo, options: Options): bool =
  if pkgInfo.developFileExists or 
    (not pkgInfo.myPath.startsWith(options.getPkgsDir) and pkgInfo.basicInfo.name != options.satResult.rootPackage.basicInfo.name):
    return true
  return false

proc addReverseDeps*(satResult: SATResult, options: Options) = 
  for solvedPkg in satResult.solvedPkgs:
    if solvedPkg.pkgName.isNim or solvedPkg.pkgName.isFileURL: continue #Dont add fileUrl to reverse deps.
    var reverseDepPkg = satResult.getPkgInfoFromSolved(solvedPkg, options)
    # Check if THIS package (the one that depends on others) is a development package
    if reverseDepPkg.isInDevelopMode(options):
      reverseDepPkg.isLink = true
    
    for dep in solvedPkg.deps:
      if dep.pkgName.isNim: continue 
      try:
        if dep.pkgName.isFileURL:
          continue
        let depPkg = satResult.getPkgInfoFromSolved(dep, options)              
        addRevDep(options.nimbleData, depPkg.basicInfo, reverseDepPkg)
      except CatchableError:
        # Skip packages that can't be found (e.g., installed during hook execution)
        # This can happen when packages are installed recursively during hooks
        displayInfo("Skipping reverse dependency for package not found in solution: " & $dep, MediumPriority)



proc executeHook(nimBin: string, dir: string, options: var Options, action: ActionType, before: bool) =
  let nimbleFile = findNimbleFile(dir, false, options).splitFile.name
  let hook = VisitedHook(pkgName: nimbleFile, action: action, before: before)
  if hook in options.visitedHooks:
    return
  options.visitedHooks.add(hook)

  cd dir: # Make sure `execHook` executes the correct .nimble file.
    if not execHook(nimBin, options, action, before):
      if before:
        raise nimbleError("Pre-hook prevented further execution.")
      else:
        raise nimbleError("Post-hook prevented further execution.")

proc packageExists(nimBin: string, pkgInfo: PackageInfo, options: Options):
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
      oldPkgInfo = pkgDestDir.getPkgInfo(options, nimBin = nimBin)
    except CatchableError as error:
      raise nimbleError(&"The package inside \"{pkgDestDir}\" is invalid.",
                        details = error)
    fillMetaData(oldPkgInfo, pkgDestDir, true, options)
    return some(oldPkgInfo)


proc installFromDirDownloadInfo(nimBin: string,downloadDir: string, url: string, pv: PkgTuple, options: Options): PackageInfo {.instrument.} = 

  let dir = downloadDir
  var pkgInfo = getPkgInfo(dir, options, nimBin = nimBin)
  var depsOptions = options
  depsOptions.depsOnly = false

  # Check for version mismatch between git tag and .nimble file
  # pv.ver.ver is the version from the SAT solver, which was discovered from git tags
  # (e.g., tag v0.36.0 -> version 0.36.0). If the .nimble file declares a different
  # version (e.g., 0.1.0), we use the tag version since that's what was requested.
  if pv.ver.kind == verEq and pkgInfo.basicInfo.version != pv.ver.ver:
    pkgInfo.basicInfo.version = pv.ver.ver

  display("Installing", "$1@$2" %
    [pkgInfo.basicInfo.name, $pkgInfo.basicInfo.version],
    priority = MediumPriority)

  let oldPkg = packageExists(nimBin, pkgInfo, options)
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
    iterInstallFilesSimple(pkgInfo.getNimbleFileDir(), pkgInfo, options,
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
    if pv.ver.kind == verSpecial:
      pkgInfo.metadata.specialVersions.incl pv.ver.spe

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

proc expandPaths*(pkgInfo: PackageInfo, nimBin: string, options: Options): seq[string] =
  var pkgInfo = pkgInfo.toFullInfo(options, nimBin = nimBin) #TODO is this needed in VNEXT? I dont think so
  if not options.isLegacy: 
    pkgInfo = pkgInfo.toRequiresInfo(options, nimBin = nimBin)
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
  let nimBin = satResult.nimResolved.getNimBin()
  for depInfo in getDepsPkgInfo(satResult, pkgInfo, options):
    for path in depInfo.expandPaths(nimBin, options):
      result.incl(path)
    if recursive:
      for path in satResult.getPathsToBuildFor(depInfo, recursive = true, options):
        result.incl(path)
  result.incl(pkgInfo.expandPaths(nimBin, options))

proc getPathsAllPkgs*(options: Options): HashSet[string] =
  let satResult = options.satResult
  for pkg in satResult.pkgs:
    for path in pkg.expandPaths(satResult.nimResolved.getNimBin(), options):
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
                  args: seq[string], options: Options, nimBin: string) =
  ## Builds a package as specified by ``pkgInfo``.
  # Handle pre-`build` hook.
  let
    realDir = pkgInfo.getRealDir()
    pkgDir = pkgInfo.myPath.parentDir()
  cd pkgDir: # Make sure `execHook` executes the correct .nimble file.
    if not execHook(nimBin, options, actionBuild, true):
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
    discard execHook(nimBin, options, actionBuild, false)

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
        elif dirExists(pkgDestDir / pkgInfo.binDir):
          pkgInfo.binDir / bin
        else:
          bin

      # For develop mode packages, the binary is in the source directory, not installed directory
      let symlinkDest = 
        if pkgInfo.isLink:
          # Develop mode: binary is in the source directory
          pkgInfo.getOutputDir(bin)
        else:
          # Installed package: binary is in the installed directory
          pkgDestDir / binDest

      if not fileExists(symlinkDest):
        raise nimbleError(&"Binary '{bin}' was not found at expected location: {symlinkDest}. BinDir is {binDir}. binDest is {binDest}. pkgDestDir is {pkgDestDir}. isLink is {pkgInfo.isLink}")
      
      # if fileExists(symlinkDest) and not pkgInfo.isLink:
      #   display("Warning:", ("Binary '$1' was already installed from source" &
      #                       " directory. Will be overwritten.") % bin, Warning,
      #           MediumPriority)
      if not pkgInfo.isLink:
        createDir((pkgDestDir / binDest).parentDir())
      let symlinkFilename = options.getBinDir() / bin.extractFilename
      binariesInstalled.incl(
        setupBinSymlink(symlinkDest, symlinkFilename, options))


proc createBinSymlinkForNim(pkgInfo: PackageInfo, options: Options) =
  let binDir = options.getBinDir()
  createDir(binDir)
  let symlinkDest =  pkgInfo.getNimbleFileDir() / "bin" / "nim".addFileExt(ExeExt)
  let symlinkFilename = options.getBinDir() / "nim"
  discard setupBinSymlink(symlinkDest, symlinkFilename, options)

proc solutionToFullInfo*(satResult: SATResult, options: var Options) {.instrument.} =
  # for pkg in satResult.pkgs:
  #   if pkg.infoKind != pikFull:   
  #     satResult.pkgs.incl(getPkgInfo(pkg.getNimbleFileDir, options))
  let nimBin = satResult.nimResolved.getNimBin()
  if satResult.rootPackage.infoKind != pikFull and not satResult.rootPackage.basicInfo.name.isNim: 
    satResult.rootPackage = getPkgInfo(satResult.rootPackage.getNimbleFileDir, options, nimBin = nimBin).toRequiresInfo(options, nimBin = nimBin)
    satResult.rootPackage.enableFeatures(options)

proc isRoot(pkgInfo: PackageInfo, satResult: SATResult): bool =
  pkgInfo.basicInfo.name == satResult.rootPackage.basicInfo.name and pkgInfo.basicInfo.version == satResult.rootPackage.basicInfo.version

proc buildPkg*(nimBin: string, pkgToBuild: PackageInfo, isRootInRootDir: bool, options: Options) {.instrument.} =
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
  buildFromDir(pkgToBuild, paths, "-d:release" & flags, options, nimBin)
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
 
proc installPkgs*(satResult: var SATResult, options: var Options) {.instrument.} =
  # options.debugSATResult("installPkgs")
  #At this point the packages are already downloaded. 
  #We still need to install them aka copy them from the cache to the nimbleDir + run preInstall and postInstall scripts
  let isInRootDir = options.startDir == satResult.rootPackage.myPath.parentDir
  var pkgsToInstall = satResult.pkgsToInstall
  # Always filter out nim - it's handled separately through installNimFromBinariesDir
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
  let nimBin = satResult.nimResolved.getNimBin()
  if isInRootDir and options.action.typ == actionInstall:
    executeHook(nimBin, getCurrentDir(), options, actionInstall, before = true)
  
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
        if satResult.rootPackage.basicInfo.name.isNim:
          # When installing nim itself, use the root package (the nim version we're installing)
          # not the nimResolved (which is the nim used for compilation)
          createBinSymlinkForNim(satResult.rootPackage, options)
          installedPkgInfo = satResult.rootPackage
          wasNewlyInstalled = true
        else:
          # Check if package already exists before installing
          let tempPkgInfo = getPkgInfo(satResult.rootPackage.getNimbleFileDir(), options, nimBin = nimBin)
          let oldPkg = packageExists(nimBin, tempPkgInfo, options)
          installedPkgInfo = installFromDirDownloadInfo(nimBin, satResult.rootPackage.getNimbleFileDir(), satResult.rootPackage.metaData.url, pv, options).toRequiresInfo(options, nimBin = nimBin)
          wasNewlyInstalled = oldPkg.isNone
        
    else:      
      # echo "NORMALIZING REQUIREMENT: ", pv.name
      # echo "ROOT PACKAGE: ", satResult.rootPackage.basicInfo.name, " ", $satResult.rootPackage.basicInfo.version, " ", satResult.rootPackage.metaData.url
      # options.debugSATResult()
      if pv.name in options.satResult.normalizedRequirements:
        pv.name = options.satResult.normalizedRequirements[pv.name]    
      
      var dlInfo: PackageDownloadInfo
      try:
        dlInfo = getPackageDownloadInfo(pv, options, doPrompt = true)
      except CatchableError as e:
        #if we fail, we try to find the url for the req:
        let url = getUrlFromPkgName(pv.name, options.satResult.pkgVersionTable, options)
        if url != "":
          pv.name = url
          dlInfo = getPackageDownloadInfo(pv, options, doPrompt = true)
        else:
          raise e
      var downloadDir = dlInfo.downloadDir / dlInfo.subdir       
      if not dirExists(dlInfo.downloadDir):        
        #The reason for this is that the download cache may have a constrained version
        #this could be improved by creating a copy of the package in the cache dir when downloading
        #and also when enumerating. 
        #Instead of redownload the actual version of the package here. Not important as this only happens per 
        #package once across all nimble projects (even in local mode)
        #But it would still be needed for the lock file case, although we could constraint it. 
        if pv.name.isFileURL:
          downloadDir = dlInfo.url.extractFilePathFromURL()
        else:
          #Since cache expansion is implemented, this point shouldnt be reached anymore.
          let downloadPkgResult = downloadFromDownloadInfo(dlInfo, options, nimBin)
          discard downloadPkgResult
        # dlInfo.downloadDir = downloadPkgResult.dir 
      assert dirExists(downloadDir)
      # Ensure submodules are populated if needed.
      # Version discovery caches packages without submodules for speed and potential errors in old pkgs,
      # so we need to fetch them here during actual installation.
      if not options.ignoreSubmodules and fileExists(downloadDir / ".gitmodules"):
        updateSubmodules(downloadDir)
      if pv.name.isFileURL:
        # echo "*** GETTING PACKAGE FROM FILE URL: ", dlInfo.url
        installedPkgInfo = getPackageFromFileUrl(dlInfo.url, options, nimBin = nimBin).toRequiresInfo(options, nimBin = nimBin)
      else:
        #TODO this : PackageInfoneeds to be improved as we are redonwloading certain packages
        # Check if package already exists before installing
        let tempPkgInfo = getPkgInfo(downloadDir, options, nimBin = nimBin)
        let oldPkg = packageExists(nimBin, tempPkgInfo, options)
        installedPkgInfo = installFromDirDownloadInfo(nimBin, downloadDir, dlInfo.url, pv, options).toRequiresInfo(options, nimBin = nimBin)     
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

  #Only build root for this actions
  let rootBuildActions = { actionInstall, actionBuild, actionRun }
  
  
  # For build action, only build the root package
  # For install action, only build newly installed packages
  var pkgsToBuild = if options.action.typ == actionBuild:
    installedPkgs.toSeq.filterIt(it.isRoot(options.satResult))
  else:
    # Only build packages that were newly installed in this session
    newlyInstalledPkgs.toSeq
  if options.action.typ == actionInstall and not options.thereIsNimbleFile:
    if not satResult.rootPackage.basicInfo.name.isNim:
      #RootPackage shouldnt be in the pkgcache for global installs. We need to move it to the 
      #install dir.
      let downloadDir = satResult.rootPackage.myPath.parentDir()
      let pv = (name: satResult.rootPackage.basicInfo.name, ver: satResult.rootPackage.basicInfo.version.toVersionRange())
      satResult.rootPackage = installFromDirDownloadInfo(nimBin, downloadDir, satResult.rootPackage.metaData.url, pv, options).toRequiresInfo(options, nimBin)    
    pkgsToBuild.add(satResult.rootPackage)

  satResult.installedPkgs = installedPkgs.toSeq()
  for pkgInfo in satResult.installedPkgs:
    # Run before-install hook now that package before the build step but after the package is copied over to the 
    #install dir.
    let hookDir = pkgInfo.myPath.splitFile.dir
    if dirExists(hookDir):
      executeHook(nimBin, hookDir, options, actionInstall, before = true)

  for pkgToBuild in pkgsToBuild:
    if pkgToBuild.bin.len == 0:
      if options.action.typ == actionBuild:
        raise nimbleError(
          "Nothing to build. Did you specify a module to build using the" &
          " `bin` key in your .nimble file?")
      else: #Skips building the package if it has no binaries
        continue
    # echo "Building package: ", pkgToBuild.basicInfo.name, " at ", pkgToBuild.myPath, " binaries: ", pkgToBuild.bin
    let isRoot = pkgToBuild.isRoot(options.satResult) and isInRootDir
    if isRoot and options.action.typ in rootBuildActions:
      buildPkg(nimBin, pkgToBuild, isRoot, options)
      satResult.buildPkgs.add(pkgToBuild)
    elif not isRoot:
      #Build non root package for all actions that requires the package as a dependency
      buildPkg(nimBin, pkgToBuild, isRoot, options)
      satResult.buildPkgs.add(pkgToBuild)

  for pkg in satResult.installedPkgs.mitems:
    satResult.pkgs.incl pkg
    
  for pkgInfo in satResult.installedPkgs:
    # Run post-install hook now that package is installed. The `execHook` proc
    # executes the hook defined in the CWD, so we set it to where the package
    # has been installed. Notice for legacy reasons this needs to happen after the build step
    let hookDir = pkgInfo.myPath.splitFile.dir
    if dirExists(hookDir):
      executeHook(nimBin, hookDir, options, actionInstall, before = false)
