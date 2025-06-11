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

proc debug*(satResult: SATResult) =
  echo "--------------------------------"
  echo "Pass: ", satResult.pass
  echo "Root package: ", satResult.rootPackage.basicInfo.name, " ", satResult.rootPackage.basicInfo.version
  echo "Solved packages: ", satResult.solvedPkgs.mapIt(it.pkgName & " " & $it.deps.mapIt(it.pkgName))
  echo "Packages to install: ", satResult.pkgsToInstall
  echo "Packages: ", satResult.pkgs.mapIt(it.basicInfo.name)
  echo "Packages url: ", satResult.pkgs.mapIt(it.metaData.url)
  echo "Package list: ", satResult.pkgList.mapIt(it.basicInfo.name)
  echo "PkgList path: ", satResult.pkgList.mapIt(it.myPath.parentDir)
  echo "--------------------------------"

proc nameMatches(pkg: PackageInfo, pv: PkgTuple, options: Options): bool =
  pkg.basicInfo.name.toLowerAscii() == pv.resolveAlias(options).name.toLowerAscii() or pkg.metaData.url == pv.name

proc nameMatches*(pkg: PackageInfo, name: string, options: Options): bool =
  pkg.basicInfo.name.toLowerAscii() == resolveAlias(name, options).toLowerAscii() or pkg.metaData.url.toLowerAscii() == name.toLowerAscii()

proc nameMatches*(pkg: PackageInfo, name: string, options: Options): bool =
  pkg.basicInfo.name.toLowerAscii() == resolveAlias(name, options).toLowerAscii() or pkg.metaData.url == name

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
  let allPkgs = satResult.pkgs.toSeq & satResult.pkgList.toSeq
  for pkg in allPkgs:
    if nameMatches(pkg, solvedPkg.pkgName, options) and pkg.basicInfo.version == solvedPkg.version:
      return pkg
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
    let solvedNim = options.satResult.solvedPkgs.filterIt(it.pkgName.isNim)
    if solvedNim.len > 0:
      # echo "Solved nim ", solvedNim[0].version
      return NimResolved(version: solvedNim[0].version)
    let pkgListDeclNims = pkgListDecl.filterIt(it.basicInfo.name.isNim)
    # echo "PkgListDeclNims ", pkgListDeclNims.mapIt(it.basicInfo.name & " " & $it.basicInfo.version)
    var bestNim: Option[PackageInfo] = none(PackageInfo)
    #TODO fail if there is none compatible with the current solution
    for pkg in pkgListDeclNims:
      if bestNim.isNone or pkg.basicInfo.version > bestNim.get.basicInfo.version:
        bestNim = some(pkg)
    if bestNim.isSome:
      return NimResolved(pkg: some(bestNim.get), version: bestNim.get.basicInfo.version)

    # echo "SAT result ", options.satResult.pkgs.mapIt(it.basicInfo.name)
    # echo "SolvedPkgs ", options.satResult.solvedPkgs
    # echo "PkgsToInstall ", options.satResult.pkgsToInstall
    # echo "Root package ", rootPackage.basicInfo, " requires ", rootPackage.requires
    # echo "PkglistDecl ", pkgListDecl.mapIt(it.basicInfo.name & " " & $it.basicInfo.version)
    # echo options.satResult.output
    # echo ""
    #TODO if we ever reach this point, we should just download the latest nim release
    raise newNimbleError[NimbleError]("No Nim found") 
  if nims.len > 1:    
    #Before erroying make sure the version are actually different
    var versions = nims.mapIt(it.basicInfo.version)
    if versions.deduplicate().len > 1:
      raise newNimbleError[NimbleError]("Multiple Nims found " & $nims.mapIt(it.basicInfo)) #TODO this cant be reached
  
  # echo "Pgs result ", result.satResult.pkgs.mapIt(it.basicInfo.name)
  # echo "SolvedPkgs ", result.satResult.solvedPkgs.mapIt(it.pkgName)
  # echo "PkgsToInstall ", result.satResult.pkgsToInstall
  # echo "Root package ", rootPackage.basicInfo, " requires ", rootPackage.requires
  # echo "PkglistDecl ", pkgListDecl.mapIt(it.basicInfo.name & " " & $it.basicInfo.version)
  result.pkg = some(nims[0])
  result.version = nims[0].basicInfo.version

proc getSolvedPkgFromInstalledPkgs*(satResult: SATResult, solvedPkg: SolvedPackage, options: Options): Option[PackageInfo] =
  for pkg in satResult.pkgList:
    if pkg.basicInfo.name == solvedPkg.pkgName and pkg.basicInfo.version == solvedPkg.version:
      return some(pkg)
  echo "Couldnt find ", solvedPkg.pkgName, " ", solvedPkg.version, " in installed pkgs"
  return none(PackageInfo)

proc solveLockFileDeps*(satResult: var SATResult, options: Options) = 
  #TODO develop mode has to be taken into account
  let lockFile = options.lockFile(satResult.rootPackage.myPath.parentDir())
  for name, dep in lockFile.getLockedDependencies.lockedDepsFor(options):
    if name.isNim: continue #Nim is already handled. 
    let solvedPkg = SolvedPackage(pkgName: name, version: dep.version) #TODO what about the other fields? Should we mark it as from lock file?
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
  options.useNimFromDir(pkgInfo.getRealDir, pkgInfo.basicInfo.version.toVersionRange())

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
  # echo "***Root package: ", options.satResult.rootPackage.basicInfo.name, " requires: ", options.satResult.rootPackage.requires
  var pkgList = 
    pkgList
    .mapIt(it.toRequiresInfo(options))
  pkgList.add(resolvedNim.pkg.get)
  options.satResult.pkgList = pkgList.toHashSet()
  options.satResult.pkgs = solvePackages(rootPackage, pkgList, options.satResult.pkgsToInstall, options, options.satResult.output, options.satResult.solvedPkgs)
  # echo "SAT RESULT IS ", options.satResult.output
  # for solvedPkg in options.satResult.solvedPkgs:
  #   echo "SOLVED PKG IS ", solvedPkg.pkgName, " ", solvedPkg.version, " requires ", solvedPkg.requirements.mapIt(it.name & " " & $it.ver)
  # for pkg in options.satResult.pkgs:
  #   echo "PKG IS ", pkg.basicInfo.name, " ", pkg.basicInfo.version, " requires ", pkg.requires.mapIt(it.name & " " & $it.ver)
  if options.satResult.solvedPkgs.len == 0:
    displayError(options.satResult.output)
    raise newNimbleError[NimbleError]("Couldnt find a solution for the packages. Unsatisfiable dependencies. Check there is no contradictory dependencies.")

proc addReverseDeps*(satResult: SATResult, options: Options) = 
  for solvedPkg in satResult.solvedPkgs:
    if solvedPkg.pkgName.isNim: continue 
    var reverseDepPkg = satResult.getPkgInfoFromSolved(solvedPkg, options)
    # Check if THIS package (the one that depends on others) is a development package
    if reverseDepPkg.developFileExists or not reverseDepPkg.myPath.startsWith(options.getPkgsDir):
      reverseDepPkg.isLink = true
    
    for dep in solvedPkg.deps:
      if dep.pkgName.isNim: continue 
      let depPkg = satResult.getPkgInfoFromSolved(dep, options)
      # echo "Checking ", depPkg.basicInfo.name, " ", depPkg.basicInfo.version, " ", depPkg.myPath.parentDir
      
      addRevDep(options.nimbleData, depPkg.basicInfo, reverseDepPkg)

proc executeHook(dir: string, options: Options, action: ActionType, before: bool) =
  cd dir: # Make sure `execHook` executes the correct .nimble file.
    if not execHook(options, action, before):
      if before:
        raise nimbleError("Pre-hook prevented further execution.")
      else:
        raise nimbleError("Post-hook prevented further execution.")

proc installFromDirDownloadInfo(downloadDir: string, url: string, options: Options): PackageInfo = 

  let dir = downloadDir
  # Handle pre-`install` hook.
  executeHook(dir, options, actionInstall, before = true)

  var pkgInfo = getPkgInfo(dir, options)
  # Set the flag that the package is not in develop mode before saving it to the
  # reverse dependencies.
  pkgInfo.isLink = false
  # if vcsRevision != notSetSha1Hash: #TODO review this
  #   ## In the case we downloaded the package as tarball we have to set the VCS
  #   ## revision returned by download procedure because it cannot be queried from
  #   ## the package directory.
  #   pkgInfo.metaData.vcsRevision = vcsRevision

  let realDir = pkgInfo.getRealDir()
  var depsOptions = options
  depsOptions.depsOnly = false

  display("Installing", "$1@$2" %
    [pkgInfo.basicInfo.name, $pkgInfo.basicInfo.version],
    priority = MediumPriority)

  #TODO review this as we may want to this not hold anymore (i.e nimble install nim could replace choosenim)
  # nim is intended only for local project local usage, so avoid installing it
  # in .nimble/bin
  # let isNimPackage = pkgInfo.basicInfo.name.isNim

  # Build before removing an existing package (if one exists). This way
  # if the build fails then the old package will still be installed.

  #TODO Review this and build later in the pipeline
  # if pkgInfo.bin.len > 0 and not isNimPackage:
  #   let paths = result.deps.map(dep => dep.expandPaths(options))
  #   let flags = if options.action.typ in {actionInstall, actionPath, actionUninstall, actionDevelop}:
  #                 options.action.passNimFlags
  #               else:
  #                 @[]

  #   try:
  #     buildFromDir(pkgInfo, paths, "-d:release" & flags, options)
  #   except CatchableError:
  #     removeRevDep(options.nimbleData, pkgInfo)
  #     raise

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
    iterInstallFiles(realDir, pkgInfo, options,
      proc (file: string) =
        createDir(changeRoot(realDir, pkgDestDir, file.splitFile.dir))
        let dest = changeRoot(realDir, pkgDestDir, file)
        filesInstalled.incl copyFileD(file, dest)
    )

    # Copy the .nimble file.
    let dest = changeRoot(pkgInfo.myPath.splitFile.dir, pkgDestDir,
                          pkgInfo.myPath)
    filesInstalled.incl copyFileD(pkgInfo.myPath, dest)

    # Update package path to point to installed directory rather than the temp
    # directory.
    pkgInfo.myPath = dest
    pkgInfo.metaData.files = filesInstalled.toSeq
    # pkgInfo.metaData.binaries = binariesInstalled.toSeq #TODO update the metadata after the build step

    saveMetaData(pkgInfo.metaData, pkgDestDir)
  else:
    display("Warning:", "Skipped copy in project local deps mode", Warning)


  displaySuccess(pkgInstalledMsg(pkgInfo.basicInfo.name), MediumPriority)

  # Run post-install hook now that package is installed. The `execHook` proc
  # executes the hook defined in the CWD, so we set it to where the package
  # has been installed.
  executeHook(pkgInfo.myPath.splitFile.dir, options, actionInstall, before = false)

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
  var pkgInfo = pkgInfo.toFullInfo(options)
  let baseDir = pkgInfo.getRealDir()
  result = @[baseDir]
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

proc getPathsAllPkgs*(satResult: SATResult, options: Options): HashSet[string] =
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

    let outputOpt = "-o:" & pkgInfo.getOutputDir(bin).quoteShell
    display("Building", "$1/$2 using $3 backend" %
            [pkginfo.basicInfo.name, bin, pkgInfo.backend], priority = HighPriority)

    let input = realDir / src.changeFileExt("nim")
    # `quoteShell` would be more robust than `\"` (and avoid quoting when
    # un-necessary) but would require changing `extractBin`
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

      if fileExists(pkgDestDir / binDest):
        display("Warning:", ("Binary '$1' was already installed from source" &
                            " directory. Will be overwritten.") % bin, Warning,
                MediumPriority)
      
      createDir((pkgDestDir / binDest).parentDir())  # Set up a symlink.
      let symlinkDest = pkgDestDir / binDest
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

proc buildPkg(pkgToBuild: PackageInfo, rootDir: bool, options: Options) =
  # let paths = getPathsToBuildFor(options.satResult, pkgToBuild, recursive = true, options)
  let paths = getPathsAllPkgs(options.satResult, options)
  # echo "Paths ", paths
  # echo "Requires ", pkgToBuild.requires
  # echo "Package ", pkgToBuild.basicInfo.name
  let flags = if options.action.typ in {actionInstall, actionPath, actionUninstall, actionDevelop}:
                options.action.passNimFlags
              else:
                @[]
  buildFromDir(pkgToBuild, paths, "-d:release" & flags, options)
  #Should we create symlinks for the root package? Before behavior was to dont create them
  #In general for nim we should not create them if we are not in the local mode
  #But if we are installing only nim (i.e nim is root) we should create them which will
  #convert nimble a choosenim replacement
  let isRootInRootDir = pkgToBuild.isRoot(options.satResult) and rootDir
  if not isRootInRootDir : #Dont create symlinks for the root package
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
  for (name, ver) in pkgsToInstall:
    let verRange = satResult.getVersionRangeFoPkgToInstall(name, ver)
    var pv = (name: name, ver: verRange)
    var installedPkgInfo: PackageInfo
    let root = satResult.rootPackage
    if root notin installedPkgs and pv.name == root.basicInfo.name and root.basicInfo.version.withinRange(pv.ver): 
      installedPkgInfo = installFromDirDownloadInfo(root.getNimbleFileDir(), root.metaData.url, options).toRequiresInfo(options)
    else:
      var dlInfo = getPackageDownloadInfo(pv, options)
      let downloadDir = dlInfo.downloadDir / dlInfo.subdir 
      # echo "DL INFO IS ", dlInfo
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
      installedPkgInfo = installFromDirDownloadInfo(downloadDir, dlInfo.url, options).toRequiresInfo(options)

    satResult.pkgs.incl(installedPkgInfo)
    installedPkgs.incl(installedPkgInfo)
  
  #we need to activate the features for the recently installed package
  #so they are activated in the build step
  options.satResult.activateSolvedPkgFeatures(options)

  for pkg in installedPkgs:
    var pkg = pkg
    # fillMetaData(pkg, pkg.getRealDir(), false, options)
    options.satResult.pkgs.incl pkg 

  let buildActions = { actionInstall, actionBuild, actionRun }
  for pkgToBuild in installedPkgs:
    if pkgToBuild.bin.len == 0:
      continue

    echo "Building package: ", pkgToBuild.basicInfo.name
    let isRoot = pkgToBuild.isRoot(options.satResult) and isInRootDir
    if options.action.typ in buildActions:
      buildPkg(pkgToBuild, isRoot, options)

  satResult.installedPkgs = installedPkgs.toSeq()
  for pkg in satResult.installedPkgs.mitems:
    pkg.isInstalled = true
    satResult.pkgs.incl pkg
    
  if isInRootDir and options.action.typ == actionInstall:
    #postInstall hook is always executed for the current directory
    executeHook(getCurrentDir(), options, actionInstall, before = false)
