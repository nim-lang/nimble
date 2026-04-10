## Package install pipeline: downloading (via download.nim), copying into
## pkgcache/pkgs2, before/after hooks, bin symlinks and reverse-dep bookkeeping.

import std/[sequtils, sets, options, os, strutils, tables, strformat]
import nimblesat, packageinfotypes, options, version, declarativeparser, packageinfo, common,
  cli, tools, nimscriptexecutor, packagemetadatafile,
  displaymessages, reversedeps, developfile, urls, download, sha1hashes,
  versiondiscovery, nimresolution, build

proc getPkgInfoFromSolved*(satResult: SATResult, solvedPkg: SolvedPackage, options: Options): PackageInfo =
  for pkg in satResult.pkgs.toSeq:
    if nameMatches(pkg, solvedPkg.pkgName, options):
      return pkg
  for pkg in satResult.pkgList.toSeq:
    #For the pkg list we need to check the version as there may be multiple versions of the same package
    if nameMatches(pkg, solvedPkg.pkgName, options) and pkg.basicInfo.version == solvedPkg.version:
      return pkg
  writeStackTrace()
  raise newNimbleError[NimbleError]("Package not found in solution: " & $solvedPkg.pkgName & " " & $solvedPkg.version)

proc isInDevelopMode*(pkgInfo: PackageInfo, options: Options): bool =
  if pkgInfo.developFileExists or
    (not pkgInfo.myPath.startsWith(options.getPkgsDir) and pkgInfo.basicInfo.name != options.satResult.rootPackage.basicInfo.name):
    return true
  return false

proc displaySatisfiedMsg*(solvedPkgs: seq[SolvedPackage], pkgToInstall: seq[(string, Version)], options: Options) =
  if options.verbosity == LowPriority:
    for pkg in solvedPkgs:
      if pkg.pkgName notin pkgToInstall.mapIt(it[0]):
        for req in pkg.requirements:
          displayInfo(pkgDepsAlreadySatisfiedMsg(req), MediumPriority)

proc activateSolvedPkgFeatures*(satResult: SATResult, options: Options) =
  for pkg in satResult.pkgs:
    for pkgTuple, activeFeatures in pkg.activeFeatures:
      let pkgWithFeature = satResult.getPkgInfoFromSolution(pkgTuple, options)
      appendGloballyActiveFeatures(pkgWithFeature.basicInfo.name, activeFeatures)

proc addReverseDeps*(satResult: SATResult, options: Options) =
  for solvedPkg in satResult.solvedPkgs:
    if solvedPkg.pkgName.isNim or solvedPkg.pkgName.isFileURL: continue #Dont add fileUrl to reverse deps.
    var reverseDepPkg = satResult.getPkgInfoFromSolved(solvedPkg, options)
    # Check if THIS package (the one that depends on others) is a development package
    if reverseDepPkg.isInDevelopMode(options):
      reverseDepPkg.source = psDevelop

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

proc executeHook(nimBin: Option[string], dir: string, options: var Options, action: ActionType, before: bool) =
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

proc packageExists(nimBin: Option[string], pkgInfo: PackageInfo, options: Options):
    Option[PackageInfo] =
  ## Checks whether a package `pkgInfo` already exists in the Nimble cache. If a
  ## package already exists returns the `PackageInfo` of the package in the
  ## cache otherwise returns `none`. Raises a `NimbleError` in the case the
  ## package exists in the cache but it is not valid.
  ##
  ## Also checks for packages with the same name and checksum but different version
  ## to avoid storing the same content multiple times with different version labels.
  let pkgDestDir = pkgInfo.getPkgDest(options)
  if fileExists(pkgDestDir / packageMetaDataFileName):
    var oldPkgInfo = initPackageInfo()
    try:
      oldPkgInfo = pkgDestDir.getPkgInfo(options, nimBin = nimBin)
    except CatchableError as error:
      raise nimbleError(&"The package inside \"{pkgDestDir}\" is invalid.",
                        details = error)
    fillMetaData(oldPkgInfo, pkgDestDir, true, options)
    return some(oldPkgInfo)

  # Check if a package with the same name and checksum exists with a different version.
  # This prevents storing the same content multiple times with different version labels.
  if pkgInfo.basicInfo.checksum != notSetSha1Hash:
    let pkgsDir = options.getPkgsDir()
    let pkgNamePrefix = pkgInfo.basicInfo.name & "-"
    let checksumSuffix = "-" & $pkgInfo.basicInfo.checksum
    for kind, path in walkDir(pkgsDir):
      if kind == pcDir:
        let dirName = path.extractFilename
        # Check if this is the same package (name matches) with same checksum
        if dirName.startsWith(pkgNamePrefix) and dirName.endsWith(checksumSuffix):
          if fileExists(path / packageMetaDataFileName):
            var oldPkgInfo = initPackageInfo()
            try:
              oldPkgInfo = path.getPkgInfo(options, nimBin = nimBin)
            except CatchableError:
              continue  # Skip invalid packages
            fillMetaData(oldPkgInfo, path, true, options)
            return some(oldPkgInfo)

  return none[PackageInfo]()


proc copyInstallFiles(srcDir, destDir: string, pkgInfo: PackageInfo,
                      options: Options): HashSet[string] =
  ## Copies selected files from srcDir to destDir during installation.
  ## Skips dot directories (like .git) and tests unless explicitly in installDirs.
  var copied: HashSet[string]
  iterInstallFiles(srcDir, pkgInfo, options,
    proc (file: string) =
      let relPath = file.relativePath(srcDir).replace('\\', '/')
      for part in relPath.split('/'):
        if part.len > 0 and part[0] == '.':
          if part notin pkgInfo.installDirs:
            return
        if part == "tests":
          if part notin pkgInfo.installDirs:
            return
      createDir(changeRoot(srcDir, destDir, file.splitFile.dir))
      let dest = changeRoot(srcDir, destDir, file)
      copied.incl copyFileD(file, dest)
  )
  copied


proc installFromDirDownloadInfo(nimBin: Option[string], downloadDir: string, url: string, pv: PkgTuple, options: var Options): PackageInfo {.instrument.} =
  ## Installs a package from a download directory (pkgcache).
  ## flow: pkgcache -> buildtemp (build) -> pkgs2 (install minimum)

  let dir = downloadDir
  var pkgInfo = getPkgInfo(dir, options, nimBin = nimBin)
  var depsOptions = options
  depsOptions.depsOnly = false

  # Handle version mismatch between git tag/lock file and .nimble file.
  # Tag version takes precedence - if the nimble file has a different version,
  # it's simply stale/wrong. Override it with the tag version.
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
    # Add the requested version to specialVersions so this package can satisfy
    # requirements for that version (important when same content has multiple version tags)
    oldPkg.metaData.specialVersions.incl pkgInfo.basicInfo.version
    oldPkg.metaData.specialVersions.incl pkgInfo.metaData.specialVersions
    saveMetaData(oldPkg.metaData, oldPkg.getNimbleFileDir, changeRoots = false)
    return oldPkg

  let pkgDestDir = pkgInfo.getPkgDest(options)

  # Fill package Meta data
  pkgInfo.metaData.url = url
  pkgInfo.source = psLocal  # Not psDevelop — this is being installed, not developed

  # Don't copy artifacts if project local deps mode and "installing" the top level package.
  if not (options.localdeps and options.isInstallingTopLevel(dir)):
    var filesInstalled: HashSet[string]
    let hasBinaries = pkgInfo.bin.len > 0 and not pkgInfo.basicInfo.name.isNim
    let hasPreInstallHook = pkgInfo.hasBeforeInstallHook and not pkgInfo.basicInfo.name.isNim

    # Install pipeline: workDir → before-install hook → build → copy to pkgDestDir → after-install hook
    # Optimization: skip buildtemp when we know it's safe (no binaries, no before-install hook, no submodules)
    let hasSubmodules = not options.ignoreSubmodules and fileExists(downloadDir / ".gitmodules")
    let canSkipBuildTemp = not hasBinaries and not hasPreInstallHook and not hasSubmodules

    var workDir, buildTempDir: string
    var workPkgInfo: PackageInfo

    if canSkipBuildTemp:
      # Optimized path: work directly from pkgcache
      workDir = downloadDir
      workPkgInfo = pkgInfo
    else:
      display("Info:", "Using buildtemp for " & pkgInfo.basicInfo.name &
              " (binaries: " & $hasBinaries & ", before-install hook: " & $hasPreInstallHook &
              ", submodules: " & $hasSubmodules & ")",
              priority = LowPriority)
      buildTempDir = options.getPkgBuildTempDir(
        pkgInfo.basicInfo.name,
        pkgInfo.basicInfo.version.toDirectoryName,
        $pkgInfo.basicInfo.checksum
      )

      # Clean up any existing temp dir from previous failed install
      if dirExists(buildTempDir):
        removeDir(buildTempDir)
      createDir(buildTempDir)

      # Copy ALL files and directories from pkgcache to temp build dir
      let buildTempBase = options.getBuildTempDir()
      let nimbleDirBase = options.getNimbleDir()
      let buildTempIsInsideDownload = buildTempBase.len > 0 and
                                       buildTempBase.startsWith(downloadDir & "/")
      let nimbleDirIsInsideDownload = nimbleDirBase.len > 0 and
                                       nimbleDirBase.startsWith(downloadDir & "/")

      # Use yieldFilter to also yield directories (important for empty dirs like .git/refs/)
      for path in walkDirRec(downloadDir, yieldFilter = {pcFile, pcDir}):
        if buildTempIsInsideDownload and path.startsWith(buildTempBase):
          continue
        if nimbleDirIsInsideDownload and path.startsWith(nimbleDirBase):
          continue
        let relPath = path.substr(downloadDir.len)
        if (DirSep & "nimbledeps" & DirSep) in relPath or
           relPath.endsWith(DirSep & "nimbledeps"):
          continue

        if (DirSep & "tests" & DirSep) in relPath or
           (DirSep & "testdata" & DirSep) in relPath:
          continue

        let destPath = changeRoot(downloadDir, buildTempDir, path)
        if path.dirExists:
          createDir(destPath)
        else:
          createDir(destPath.splitFile.dir)
          discard copyFileD(path, destPath)

      workPkgInfo = getPkgInfo(buildTempDir, options, nimBin = nimBin)
      if pv.ver.kind == verEq and workPkgInfo.basicInfo.version != pv.ver.ver:
        workPkgInfo.basicInfo.version = pv.ver.ver
      workDir = buildTempDir

      # Populate submodules in buildtemp
      if hasSubmodules:
        updateSubmodules(workDir)

      # Run before-install hook (in buildtemp, before build)
      executeHook(nimBin, workDir, options, actionInstall, before = true)

      # Build binaries (only if there are any)
      if hasBinaries:
        let paths = getPathsAllPkgs(options, nimBin)
        let flags = if options.action.typ in {actionInstall, actionPath, actionUninstall, actionDevelop}:
                      options.action.passNimFlags
                    else:
                      @[]
        buildFromDir(workPkgInfo, paths, "-d:release" & flags, options, nimBin)

    try:
      createDir(pkgDestDir)
      # For global installs, flatten srcDir so --nimblePath scanning finds modules
      # at the package root (e.g. pkgs2/intops-xxx/intops.nim instead of .../src/intops.nim).
      # For local installs (nimbledeps), keep srcDir structure because --path entries
      # use getRealDir() which points to the srcDir subdirectory.
      let isLocalInstall = dirExists(nimbledeps) or fileExists(developFileName)
      let installSrcDir = if isLocalInstall: workPkgInfo.getNimbleFileDir()
                          else: workPkgInfo.getRealDir()
      filesInstalled.incl copyInstallFiles(installSrcDir, pkgDestDir, workPkgInfo, options)

      # When srcDir is flattened (global install), installDirs at the package root
      # won't be found by copyInstallFiles (which starts from srcDir). Copy them separately.
      if not isLocalInstall and workPkgInfo.srcDir.len > 0:
        let realDir = workPkgInfo.getRealDir()
        for dir in workPkgInfo.installDirs:
          let srcDirPath = workDir / dir
          if dirExists(srcDirPath) and not dirExists(realDir / dir):
            let destDirPath = pkgDestDir / dir
            createDir(destDirPath)
            for path in walkDirRec(srcDirPath):
              let relPath = path.relativePath(srcDirPath)
              let dest = destDirPath / relPath
              createDir(dest.splitFile.dir)
              filesInstalled.incl copyFileD(path, dest)

      # Copy the .nimble file
      let nimbleFileDest = changeRoot(workPkgInfo.myPath.splitFile.dir, pkgDestDir, workPkgInfo.myPath)
      filesInstalled.incl copyFileD(workPkgInfo.myPath, nimbleFileDest)

      # Copy built binaries (only if there are any)
      if hasBinaries:
        for bin, src in workPkgInfo.bin:
          let binDest = if dirExists(pkgDestDir / bin): bin & ".out" else: bin
          let srcBin = workPkgInfo.getOutputDir(bin)
          if fileExists(srcBin):
            createDir((pkgDestDir / binDest).parentDir())
            filesInstalled.incl copyFileD(srcBin, pkgDestDir / binDest)

      pkgInfo.myPath = nimbleFileDest
      pkgInfo.metaData.files = filesInstalled.toSeq
      if pv.ver.kind == verSpecial:
        pkgInfo.metadata.specialVersions.incl pv.ver.spe

      saveMetaData(pkgInfo.metaData, pkgDestDir)

      # Run after-install hook
      executeHook(nimBin, pkgDestDir, options, actionInstall, before = false)

      # Create bin symlinks (only if there are binaries)
      if hasBinaries:
        createBinSymlink(pkgInfo, options)

    finally:
      # Cleanup buildtemp if used
      if not canSkipBuildTemp and dirExists(buildTempDir):
        removeDir(buildTempDir)

  else:
    display("Warning:", "Skipped copy in project local deps mode", Warning)

  pkgInfo.source = psInstalled
  displaySuccess(pkgInstalledMsg(pkgInfo.basicInfo.name), MediumPriority)
  pkgInfo

proc isRoot(pkgInfo: PackageInfo, satResult: SATResult): bool =
  pkgInfo.basicInfo.name == satResult.rootPackage.basicInfo.name and pkgInfo.basicInfo.version == satResult.rootPackage.basicInfo.version


proc getVersionRangeFoPkgToInstall(satResult: SATResult, name: string, ver: Version): VersionRange =
  if satResult.rootPackage.basicInfo.name == name and satResult.rootPackage.basicInfo.version == ver:
    #It could be the case that we are installing a special version of a root package
    if name == satResult.rootPackage.basicInfo.name and ver == satResult.rootPackage.basicInfo.version:
      let specialVersion = satResult.rootPackage.getNimbleFileDir().lastPathPart().split("_")[^1]
      if "#" in specialVersion:
        return parseVersionRange(specialVersion)
  return ver.toVersionRange()

proc installPkgs*(satResult: var SATResult, options: var Options, nimBin: Option[string]) {.instrument.} =
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
  if options.action.typ == actionInstall and not options.depsOnly: #only install action install the root package: #skip root when in localdeps mode and in rootdir
    pkgsToInstall.add((name: satResult.rootPackage.basicInfo.name, ver: satResult.rootPackage.basicInfo.version))
  else:
    #Root can be assumed as installed as the only global action one can do is install
    installedPkgs.incl(satResult.rootPackage)

  displaySatisfiedMsg(satResult.solvedPkgs, pkgsToInstall, options)
  #If package is in develop mode, we dont need to install it.
  var newlyInstalledPkgs = initHashSet[PackageInfo]()
  let rootName = satResult.rootPackage.basicInfo.name
  # options.debugSATResult()

  # For develop, resolve pkgsToInstall from vendor packages instead of downloading.
  # The SAT solver may flag vendor packages for installation when cached versions
  # shadow them in processRequirements's hasVersion check.
  if options.action.typ == actionDevelop:
    let developPkgs = processDevelopDependencies(satResult.rootPackage, options, nimBin)
    var remaining: seq[(string, Version)] = @[]
    for (name, ver) in pkgsToInstall:
      var found = false
      for devPkg in developPkgs:
        if cmpIgnoreCase(devPkg.basicInfo.name, name) == 0:
          satResult.pkgs.incl(devPkg)
          found = true
          break
      if not found:
        remaining.add((name, ver))
    pkgsToInstall = remaining

  if isInRootDir and options.action.typ == actionInstall and not options.depsOnly:
    executeHook(nimBin, getCurrentDir(), options, actionInstall, before = true)

  for (name, ver) in pkgsToInstall:
    var verRange = satResult.getVersionRangeFoPkgToInstall(name, ver)
    # Get vcsRevision from lock file if available - will be passed to download functions
    let vcsRevision = if name in options.satResult.lockFileVcsRevisions:
      options.satResult.lockFileVcsRevisions[name]
    else:
      notSetSha1Hash
    var pv = (name: name, ver: verRange)
    var installedPkgInfo: PackageInfo
    var wasNewlyInstalled = false
    if pv.name == rootName and (rootName notin installedPkgs.mapIt(it.basicInfo.name) or satResult.rootPackage.hasLockFile(options)):
      if satResult.rootPackage.developFileExists or options.localdeps:
        # Treat as link package if in develop mode OR local deps mode
        satResult.rootPackage.source = psDevelop
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
        dlInfo = getPackageDownloadInfo(pv, options, doPrompt = true, vcsRevision = vcsRevision)
      except CatchableError as e:
        #if we fail, we try to find the url for the req:
        let url = getUrlFromPkgName(pv.name, options.satResult.pkgVersionTable, options)
        if url != "":
          pv.name = url
          dlInfo = getPackageDownloadInfo(pv, options, doPrompt = true, vcsRevision = vcsRevision)
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

          var dlOptions = options
          dlOptions.ignoreSubmodules = true
          dlOptions.enableTarballs = false
          let downloadPkgResult = downloadFromDownloadInfo(dlInfo, dlOptions, nimBin)
          discard downloadPkgResult
        # dlInfo.downloadDir = downloadPkgResult.dir
      assert dirExists(downloadDir)

      # Check if cache is corrupted (directory exists but has no nimble file)
      if not pv.name.isFileURL and not pkgDirHasNimble(dlInfo.downloadDir, options):
        displayWarning(&"Cache directory is corrupted (no .nimble file found): {dlInfo.downloadDir}", HighPriority)
        displayWarning("Removing corrupted cache and re-downloading...", HighPriority)
        try:
          removeDir(dlInfo.downloadDir)
        except CatchableError as e:
          displayWarning(&"Failed to remove corrupted cache: {e.msg}", HighPriority)
        # Re-download to pkgcache WITHOUT submodules (issue #1592)
        # Force git clone (not tarball) so .git and .gitmodules are preserved for buildtemp
        var dlOptions = options
        dlOptions.ignoreSubmodules = true
        dlOptions.enableTarballs = false
        let downloadPkgResult = downloadFromDownloadInfo(dlInfo, dlOptions, nimBin)
        discard downloadPkgResult
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
  if options.action.typ == actionInstall and not options.thereIsNimbleFile and not options.depsOnly:
    if not satResult.rootPackage.basicInfo.name.isNim:
      #RootPackage shouldnt be in the pkgcache for global installs. We need to move it to the
      #install dir.
      let downloadDir = satResult.rootPackage.myPath.parentDir()
      let pv = (name: satResult.rootPackage.basicInfo.name, ver: satResult.rootPackage.basicInfo.version.toVersionRange())
      satResult.rootPackage = installFromDirDownloadInfo(nimBin, downloadDir, satResult.rootPackage.metaData.url, pv, options).toRequiresInfo(options, nimBin)
    pkgsToBuild.add(satResult.rootPackage)

  satResult.installedPkgs = installedPkgs.toSeq()

  # Note: before-install and after-install hooks for installed packages now run
  # inside installFromDirDownloadInfo (in buildtemp and install dir respectively).
  # We only need to build packages that were NOT installed via installFromDirDownloadInfo:
  # - Root package for actionBuild (built in current directory)
  # - Develop mode packages (isLink = true)

  for pkgToBuild in pkgsToBuild:
    # Skip packages that were already built during install (not isLink)
    # Only build root package in place or develop mode packages
    if not pkgToBuild.isLink:
      let isRoot = pkgToBuild.isRoot(options.satResult)
      if not (isRoot and isInRootDir and options.action.typ == actionBuild):
        # Package was installed via installFromDirDownloadInfo, already built
        continue

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
    elif pkgToBuild.isLink:
      # Build develop mode packages
      buildPkg(nimBin, pkgToBuild, false, options)
      satResult.buildPkgs.add(pkgToBuild)

  for pkg in satResult.installedPkgs.mitems:
    satResult.pkgs.incl pkg
