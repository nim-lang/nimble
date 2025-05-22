#[
Name of the file is temporary.
VNext is a new code path for some actions where we assume solver is SAT and declarative parser are enabled.
The first thing we do, is to try to resolve Nim assuming there is no Nim installed (so we cant fallback to the vm parser to read deps)
After we resolve nim, we try to resolve the dependencies for a root package. Root package can be the package we want to install or the package in the current directory.
]#

#[
Steps:
  - toRequiresInfo should accept an additional argument so we can decide to dont fallback to the vm parser when the declarative parser fails.
  - isolate nim selection
  - if nim cant be decided, we should stop (for now. Later on we can 1. see if there is a nim in the path. 2 See if there is a nim in the pkgklist. 3 Download latest nim release)
  - After we have nim, we can try to resolve the dependencies (later on, only re-run the solver if we needed nim in the step above)
  - Once we have the graph solved. We can proceed with the action.

]#
import std/[sequtils, sets, options, os, strutils]
import nimblesat, packageinfotypes, options, version, declarativeparser, packageinfo, common,
  nimenv, lockfile, cli, downloadnim, packageparser, tools, nimscriptexecutor, packagemetadatafile,
  displaymessages

type 
    
  NimResolved* = object
    pkg: Option[PackageInfo] #when none, we need to install it
    version: Version

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
  let lockFile = options.lockFile(getCurrentDir())
  if options.hasNimInLockFile():
    if options.useSystemNim and systemNimPkg.isSome:
      return NimResolved(pkg: some(systemNimPkg.get), version: systemNimPkg.get.basicInfo.version)
    else:
      for name, dep in lockFile.getLockedDependencies.lockedDepsFor(options):
        if name.isNim:
          return NimResolved(version: dep.version)
    
  options.satResult.pkgs = solvePackages(rootPackage, pkgListDecl, options.satResult.pkgsToInstall, options, options.satResult.output, options.satResult.solvedPkgs)
  if options.satResult.solvedPkgs.len == 0:
    displayError(options.satResult.output)
    raise newNimbleError[NimbleError]("Couldnt find a solution for the packages. Check there is no contradictory dependencies.")

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

    # echo "SAT result ", result.satResult.pkgs.mapIt(it.basicInfo.name)
    # echo "SolvedPkgs ", result.satResult.solvedPkgs
    # echo "PkgsToInstall ", result.satResult.pkgsToInstall
    # echo "Root package ", rootPackage.basicInfo, " requires ", rootPackage.requires
    # echo "PkglistDecl ", pkgListDecl.mapIt(it.basicInfo.name & " " & $it.basicInfo.version)
    echo options.satResult.output
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

proc setNimBin(pkgInfo: PackageInfo, options: var Options) =
  assert pkgInfo.basicInfo.name.isNim
  if options.nimBin.isSome and options.nimBin.get.path == pkgInfo.getRealDir / "bin" / "nim":
    return #We dont want to set the same Nim twice. Notice, this can only happen when installing multiple packages outside of the project dir i.e nimble install pkg1 pkg2
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

  resolvedNim.pkg.get.setNimBin(options)
  return resolvedNim

proc solvePkgsWithVmParserAllowingFallback*(rootPackage: PackageInfo, resolvedNim: NimResolved, pkgList: seq[PackageInfo], options: var Options)=
  var rootPackage = getPkgInfo(rootPackage.myPath.parentDir, options)
  options.satResult.rootPackage = rootPackage
  # echo "***Root package: ", options.satResult.rootPackage.basicInfo.name, " requires: ", options.satResult.rootPackage.requires
  var pkgList = 
    pkgList
    .mapIt(it.toRequiresInfo(options))
  pkgList.add(resolvedNim.pkg.get)
  options.satResult.pkgList = pkgList.toHashSet()

  options.satResult.pkgs = solvePackages(rootPackage, pkgList, options.satResult.pkgsToInstall, options, options.satResult.output, options.satResult.solvedPkgs)
  if options.satResult.solvedPkgs.len == 0:
    displayError(options.satResult.output)
    raise newNimbleError[NimbleError]("Couldnt find a solution for the packages. Check there is no contradictory dependencies.")

proc executeHook(dir: string, options: Options, action: ActionType, before: bool) =
  cd dir: # Make sure `execHook` executes the correct .nimble file.
    if not execHook(options, action, before):
      if before:
        raise nimbleError("Pre-hook prevented further execution.")
      else:
        raise nimbleError("Post-hook prevented further execution.")

proc installFromDirDownloadInfo(dl: PackageDownloadInfo, options: Options): PackageInfo = 

  let dir = dl.downloadDir
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
  # let binDir = options.getBinDir()
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
  pkgInfo.metaData.url = dl.url
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

    #TODO Binary handling
    # var binariesInstalled: HashSet[string]
    # if pkgInfo.bin.len > 0 and not pkgInfo.basicInfo.name.isNim:
    #   # Make sure ~/.nimble/bin directory is created.
    #   createDir(binDir)
    #   # Set file permissions to +x for all binaries built,
    #   # and symlink them on *nix OS' to $nimbleDir/bin/
    #   for bin, src in pkgInfo.bin:
    #     let binDest =
    #       # Issue #308
    #       if dirExists(pkgDestDir / bin):
    #         bin & ".out"
    #       else: bin

    #     if fileExists(pkgDestDir / binDest):
    #       display("Warning:", ("Binary '$1' was already installed from source" &
    #                           " directory. Will be overwritten.") % bin, Warning,
    #               MediumPriority)

    #     # Copy the binary file.
    #     createDir((pkgDestDir / binDest).parentDir())
    #     filesInstalled.incl copyFileD(pkgInfo.getOutputDir(bin),
    #                                   pkgDestDir / binDest)

    #     # Set up a symlink.
    #     let symlinkDest = pkgDestDir / binDest
    #     let symlinkFilename = options.getBinDir() / bin.extractFilename
    #     binariesInstalled.incl(
    #       setupBinSymlink(symlinkDest, symlinkFilename, options))

    # Update package path to point to installed directory rather than the temp
    # directory.
    pkgInfo.myPath = dest
    pkgInfo.metaData.files = filesInstalled.toSeq
    # pkgInfo.metaData.binaries = binariesInstalled.toSeq

    saveMetaData(pkgInfo.metaData, pkgDestDir)
  else:
    display("Warning:", "Skipped copy in project local deps mode", Warning)

  pkgInfo.isInstalled = true

  displaySuccess(pkgInstalledMsg(pkgInfo.basicInfo.name), MediumPriority)

  # Run post-install hook now that package is installed. The `execHook` proc
  # executes the hook defined in the CWD, so we set it to where the package
  # has been installed.
  executeHook(pkgInfo.myPath.splitFile.dir, options, actionInstall, before = false)

  pkgInfo

proc installPkgs*(satResult: var SATResult, options: Options) =
  let isInRootDir = satResult.rootPackage.myPath.parentDir == getCurrentDir()
  #At this point the packages are already downloaded. 
  #We still need to install them aka copy them from the cache to the nimbleDir + run preInstall and postInstall scripts
  #preInstall hook is always executed for the current directory
  if isInRootDir:
    executeHook(getCurrentDir(), options, actionInstall, before = true) #likely incorrect if we are not in a nimble dir
  var pkgsToInstall = satResult.pkgsToInstall
   #If we are not in the root folder, means user is installing a package globally so we need to install root
  if not isInRootDir: #TODO only install if not already installed    
    pkgsToInstall.add((name: satResult.rootPackage.basicInfo.name, ver: satResult.rootPackage.basicInfo.version))

  for (name, ver) in pkgsToInstall:
    # echo "Installing package: ", name, " ", ver
    let pv = (name: name, ver: ver.toVersionRange())
    let dlInfo = getPackageDownloadInfo(pv, options)
    if not dirExists(dlInfo.downloadDir):
      #The reason for this is that the download cache may have a constrained version
      #this could be improved by creating a copy of the package in the cache dir when downloading
      #and also when enumerating. 
      #Instead of redownload the actual version of the package here. Not important as this only happens per 
      #package once across all nimble projects (even in local mode)
      discard downloadFromDownloadInfo(dlInfo, options)
  
    assert dirExists(dlInfo.downloadDir)
    #TODO this needs to be improved as we are redonwloading certain packages
    let pkgInfo = installFromDirDownloadInfo(dlInfo, options)
    satResult.pkgs.incl(pkgInfo)
    
 
  if isInRootDir:
    #postInstall hook is always executed for the current directory
    executeHook(getCurrentDir(), options, actionInstall, before = false)
