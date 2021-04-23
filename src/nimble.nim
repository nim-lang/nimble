# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import system except TResult

import os, tables, strtabs, json, algorithm, sets, uri, sugar, sequtils, osproc,
       strformat

import std/options as std_opt

import strutils except toLower
from unicode import toLower

import nimblepkg/packageinfotypes, nimblepkg/packageinfo, nimblepkg/version,
       nimblepkg/tools, nimblepkg/download, nimblepkg/config, nimblepkg/common,
       nimblepkg/publish, nimblepkg/options, nimblepkg/packageparser,
       nimblepkg/cli, nimblepkg/packageinstaller, nimblepkg/reversedeps,
       nimblepkg/nimscriptexecutor, nimblepkg/init, nimblepkg/vcstools,
       nimblepkg/checksums, nimblepkg/topologicalsort, nimblepkg/lockfile,
       nimblepkg/nimscriptwrapper, nimblepkg/developfile, nimblepkg/paths,
       nimblepkg/nimbledatafile, nimblepkg/packagemetadatafile,
       nimblepkg/displaymessages, nimblepkg/sha1hashes, nimblepkg/syncfile

const
  nimblePathsFileName* = "nimble.paths"
  nimbleConfigFileName* = "config.nims"
  gitIgnoreFileName = ".gitignore"
  hgIgnoreFileName = ".hgignore"

proc refresh(options: Options) =
  ## Downloads the package list from the specified URL.
  ##
  ## If the download is not successful, an exception is raised.
  let parameter =
    if options.action.typ == actionRefresh:
      options.action.optionalURL
    else:
      ""

  if parameter.len > 0:
    if parameter.isUrl:
      let cmdLine = PackageList(name: "commandline", urls: @[parameter])
      fetchList(cmdLine, options)
    else:
      if parameter notin options.config.packageLists:
        let msg = "Package list with the specified name not found."
        raise nimbleError(msg)

      fetchList(options.config.packageLists[parameter], options)
  else:
    # Try each package list in config
    for name, list in options.config.packageLists:
      fetchList(list, options)

proc initPkgList(pkgInfo: PackageInfo, options: Options): seq[PackageInfo] =
  let
    installedPkgs = getInstalledPkgsMin(options.getPkgsDir(), options)
    developPkgs = processDevelopDependencies(pkgInfo, options)
  {.warning[ProveInit]: off.}
  result = concat(installedPkgs, developPkgs)
  {.warning[ProveInit]: on.}

proc install(packages: seq[PkgTuple], options: Options,
             doPrompt, first, fromLockFile: bool): PackageDependenciesInfo

proc processFreeDependencies(pkgInfo: PackageInfo, options: Options):
    HashSet[PackageInfo] =
  ## Verifies and installs dependencies.
  ##
  ## Returns set of PackageInfo (for paths) to pass to the compiler
  ## during build phase.

  assert not pkgInfo.isMinimal,
         "processFreeDependencies needs pkgInfo.requires"

  var pkgList {.global.}: seq[PackageInfo] = @[]
  once: pkgList = initPkgList(pkgInfo, options)

  display("Verifying",
          "dependencies for $1@$2" % [pkgInfo.name, $pkgInfo.specialVersion],
          priority = HighPriority)

  var reverseDependencies: seq[PackageBasicInfo] = @[]
  for dep in pkgInfo.requires:
    if dep.name == "nimrod" or dep.name == "nim":
      let nimVer = getNimrodVersion(options)
      if not withinRange(nimVer, dep.ver):
        let msg = "Unsatisfied dependency: " & dep.name & " (" & $dep.ver & ")"
        raise nimbleError(msg)
    else:
      let resolvedDep = dep.resolveAlias(options)
      display("Checking", "for $1" % $resolvedDep, priority = MediumPriority)
      var pkg = initPackageInfo()
      var found = findPkg(pkgList, resolvedDep, pkg)
      # Check if the original name exists.
      if not found and resolvedDep.name != dep.name:
        display("Checking", "for $1" % $dep, priority = MediumPriority)
        found = findPkg(pkgList, dep, pkg)
        if found:
          displayWarning(&"Installed package {dep.name} should be renamed to " &
                         resolvedDep.name)

      if not found:
        display("Installing", $resolvedDep, priority = HighPriority)
        let toInstall = @[(resolvedDep.name, resolvedDep.ver)]
        let (packages, installedPkg) = install(toInstall, options,
          doPrompt = false, first = false, fromLockFile = false)

        result.incl packages

        pkg = installedPkg # For addRevDep
        fillMetaData(pkg, pkg.getRealDir(), false)

        # This package has been installed so we add it to our pkgList.
        pkgList.add pkg
      else:
        displayInfo(pkgDepsAlreadySatisfiedMsg(dep))
        result.incl pkg
        # Process the dependencies of this dependency.
        result.incl processFreeDependencies(pkg.toFullInfo(options), options)
      if not pkg.isLink:
        reverseDependencies.add((pkg.name, pkg.specialVersion, pkg.checksum))

  # Check if two packages of the same name (but different version) are listed
  # in the path.
  var pkgsInPath: Table[string, Version]
  for pkgInfo in result:
    let currentVer = pkgInfo.getConcreteVersion(options)
    if pkgsInPath.hasKey(pkgInfo.name) and
       pkgsInPath[pkgInfo.name] != currentVer:
      raise nimbleError(
        "Cannot satisfy the dependency on $1 $2 and $1 $3" %
          [pkgInfo.name, $currentVer, $pkgsInPath[pkgInfo.name]])
    pkgsInPath[pkgInfo.name] = currentVer

  # We add the reverse deps to the JSON file here because we don't want
  # them added if the above errorenous condition occurs
  # (unsatisfiable dependendencies).
  # N.B. NimbleData is saved in installFromDir.
  for i in reverseDependencies:
    addRevDep(options.nimbleData, i, pkgInfo)

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
  args.add "-d:NimblePkgVersion=" & $pkgInfo.version
  for path in paths:
    args.add("--path:" & path.quoteShell)
  if options.verbosity >= HighPriority:
    # Hide Nim hints by default
    args.add("--hints:off")
  if options.verbosity == SilentPriority:
    # Hide Nim warnings
    args.add("--warnings:off")

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

    let outputOpt = "-o:" & pkgInfo.getOutputDir(bin).quoteShell
    display("Building", "$1/$2 using $3 backend" %
            [pkginfo.name, bin, pkgInfo.backend], priority = HighPriority)

    let outputDir = pkgInfo.getOutputDir("")
    if not dirExists(outputDir):
      createDir(outputDir)

    let input = realDir / src.changeFileExt("nim")
    # `quoteShell` would be more robust than `\"` (and avoid quoting when
    # un-necessary) but would require changing `extractBin`
    let cmd = "$# $# --colors:on --noNimblePath $# $# $#" % [
      getNimBin(options).quoteShell, pkgInfo.backend, join(args, " "),
      outputOpt, input.quoteShell]
    try:
      doCmd(cmd)
      binariesBuilt.inc()
    except CatchableError as error:
      raise buildFailed(
        &"Build failed for the package: {pkgInfo.name}", details = error)

  if binariesBuilt == 0:
    raise nimbleError(
      "No binaries built, did you specify a valid binary name?"
    )

  # Handle post-`build` hook.
  cd pkgDir: # Make sure `execHook` executes the correct .nimble file.
    discard execHook(options, actionBuild, false)

proc promptRemoveEntirePackageDir(pkgDir: string, options: Options) =
  let exceptionMsg = getCurrentExceptionMsg()
  let warningMsgEnd = if exceptionMsg.len > 0: &": {exceptionMsg}" else: "."
  let warningMsg = &"Unable to read {packageMetaDataFileName}{warningMsgEnd}"

  display("Warning", warningMsg, Warning, HighPriority)

  if not options.prompt(
      &"Would you like to COMPLETELY remove ALL files in {pkgDir}?"):
    raise nimbleQuit()

proc removePackageDir(pkgInfo: PackageInfo, pkgDestDir: string) =
  removePackageDir(pkgInfo.files & packageMetaDataFileName, pkgDestDir)

proc removeBinariesSymlinks(pkgInfo: PackageInfo, binDir: string) =
  for bin in pkgInfo.binaries:
    when defined(windows):
      removeFile(binDir / bin.changeFileExt("cmd"))
    removeFile(binDir / bin)

proc reinstallSymlinksForOlderVersion(pkgDir: string, options: Options) =
  let (pkgName, _, _) = getNameVersionChecksum(pkgDir)
  let pkgList = getInstalledPkgsMin(options.getPkgsDir(), options)
  var newPkgInfo = initPackageInfo()
  if pkgList.findPkg((pkgName, newVRAny()), newPkgInfo):
    newPkgInfo = newPkgInfo.toFullInfo(options)
    for bin, _ in newPkgInfo.bin:
      let symlinkDest = newPkgInfo.getOutputDir(bin)
      let symlinkFilename = options.getBinDir() / bin.extractFilename
      discard setupBinSymlink(symlinkDest, symlinkFilename, options)

proc removePackage(pkgInfo: PackageInfo, options: Options) =
  var pkgInfo = pkgInfo
  let pkgDestDir = pkgInfo.getPkgDest(options)

  if not pkgInfo.hasMetaData:
    try:
      fillMetaData(pkgInfo, pkgDestDir, true)
    except MetaDataError, ValueError:
      promptRemoveEntirePackageDir(pkgDestDir, options)
      removeDir(pkgDestDir)

  removePackageDir(pkgInfo, pkgDestDir)
  removeBinariesSymlinks(pkgInfo, options.getBinDir())
  reinstallSymlinksForOlderVersion(pkgDestDir, options)
  options.nimbleData.removeRevDep(pkgInfo)

proc packageExists(pkgInfo: PackageInfo, options: Options): bool =
  let pkgDestDir = pkgInfo.getPkgDest(options)
  return fileExists(pkgDestDir / packageMetaDataFileName)

proc promptOverwriteExistingPackage(pkgInfo: PackageInfo,
                                    options: Options): bool =
  let message = "$1@$2 already exists. Overwrite?" %
                [pkgInfo.name, $pkgInfo.specialVersion]
  return options.prompt(message)

proc removeOldPackage(pkgInfo: PackageInfo, options: Options) =
  let pkgDestDir = pkgInfo.getPkgDest(options)
  let oldPkgInfo = getPkgInfo(pkgDestDir, options)
  removePackage(oldPkgInfo, options)

proc promptRemovePackageIfExists(pkgInfo: PackageInfo, options: Options): bool =
  if packageExists(pkgInfo, options):
    if not promptOverwriteExistingPackage(pkgInfo, options):
      return false
    removeOldPackage(pkgInfo, options)
  return true

proc processLockedDependencies(pkgInfo: PackageInfo, options: Options):
  HashSet[PackageInfo]

proc processAllDependencies(pkgInfo: PackageInfo, options: Options):
    HashSet[PackageInfo] =
  if pkgInfo.lockedDeps.len > 0:
    pkgInfo.processLockedDependencies(options)
  else:
    pkgInfo.processFreeDependencies(options)

proc installFromDir(dir: string, requestedVer: VersionRange, options: Options,
                    url: string, first: bool, fromLockFile: bool):
    PackageDependenciesInfo =
  ## Returns where package has been installed to, together with paths
  ## to the packages this package depends on.
  ## 
  ## The return value of this function is used by
  ## ``processFreeDependencies``
  ##   To gather a list of paths to pass to the Nim compiler.
  ##
  ## ``first``
  ##   True if this is the first level of the indirect recursion.
  ## ``fromLockFile``
  ##   True if we are installing dependencies from the lock file.

  # Handle pre-`install` hook.
  if not options.depsOnly:
    cd dir: # Make sure `execHook` executes the correct .nimble file.
      if not execHook(options, actionInstall, true):
        raise nimbleError("Pre-hook prevented further execution.")

  var pkgInfo = getPkgInfo(dir, options)
  # Set the flag that the package is not in develop mode before saving it to the
  # reverse dependencies.
  pkgInfo.isLink = false

  let realDir = pkgInfo.getRealDir()
  let binDir = options.getBinDir()
  var depsOptions = options
  depsOptions.depsOnly = false

  # Overwrite the version if the requested version is "#head" or similar.
  if requestedVer.kind == verSpecial:
    pkgInfo.specialVersion = requestedVer.spe

  # Dependencies need to be processed before the creation of the pkg dir.
  if first and pkgInfo.lockedDeps.len > 0:
    result.deps = pkgInfo.processLockedDependencies(depsOptions)
  elif not fromLockFile:
    result.deps = pkgInfo.processFreeDependencies(depsOptions)

  if options.depsOnly:
    result.pkg = pkgInfo
    return result

  display("Installing", "$1@$2" % [pkginfo.name, $pkginfo.specialVersion],
          priority = HighPriority)

  let isPackageAlreadyInCache = pkgInfo.packageExists(options)

  # Build before removing an existing package (if one exists). This way
  # if the build fails then the old package will still be installed.

  if pkgInfo.bin.len > 0:
    let paths = result.deps.map(dep => dep.getRealDir())
    let flags = if options.action.typ in {actionInstall, actionPath, actionUninstall, actionDevelop}:
                  options.action.passNimFlags
                else:
                  @[]

    try:
      buildFromDir(pkgInfo, paths, "-d:release" & flags, options)
    except CatchableError:
      if not isPackageAlreadyInCache:
        removeRevDep(options.nimbleData, pkgInfo)
      raise

  let pkgDestDir = pkgInfo.getPkgDest(options)

  # Fill package Meta data
  pkgInfo.url = url
  pkgInfo.isLink = false

  # Don't copy artifacts if project local deps mode and "installing" the top
  # level package.
  if not (options.localdeps and options.isInstallingTopLevel(dir)):
    if not promptRemovePackageIfExists(pkgInfo, options):
      return

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

    var binariesInstalled: HashSet[string]
    if pkgInfo.bin.len > 0:
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

        # Copy the binary file.
        createDir((pkgDestDir / binDest).parentDir())
        filesInstalled.incl copyFileD(pkgInfo.getOutputDir(bin),
                                      pkgDestDir / binDest)

        # Set up a symlink.
        let symlinkDest = pkgDestDir / binDest
        let symlinkFilename = options.getBinDir() / bin.extractFilename
        binariesInstalled.incl(
          setupBinSymlink(symlinkDest, symlinkFilename, options))

    # Update package path to point to installed directory rather than the temp
    # directory.
    pkgInfo.myPath = dest
    pkgInfo.files = filesInstalled.toSeq
    pkgInfo.binaries = binariesInstalled.toSeq

    saveMetaData(pkgInfo.metaData, pkgDestDir)
  else:
    display("Warning:", "Skipped copy in project local deps mode", Warning)

  pkgInfo.isInstalled = true

  displaySuccess(pkgInstalledMsg(pkgInfo.name))

  result.deps.incl pkgInfo
  result.pkg = pkgInfo

  # Run post-install hook now that package is installed. The `execHook` proc
  # executes the hook defined in the CWD, so we set it to where the package
  # has been installed.
  cd pkgInfo.myPath.splitFile.dir:
    discard execHook(options, actionInstall, false)

proc getLockedDep(pkgInfo: PackageInfo, name: string, dep: LockFileDep,
                  options: Options): PackageInfo =
  ## Returns the package info for dependency package `dep` with name `name` from
  ## the lock file of the package `pkgInfo` by searching for it in the local
  ## Nimble cache and downloading it from its repository if the version with the
  ## required checksum is not found locally.

  let packagesDir = options.getPkgsDir()
  let depDirName = packagesDir / &"{name}-{dep.version}-{dep.checksums.sha1}"

  if not fileExists(depDirName / packageMetaDataFileName):
    if depDirName.dirExists:
      promptRemoveEntirePackageDir(depDirName, options)
      removeDir(depDirName)

    let (url, metadata) = getUrlData(dep.url)
    let version =  dep.version.parseVersionRange
    let subdir = metadata.getOrDefault("subdir")

    let (downloadDir, _) = downloadPkg(
      url, version, dep.downloadMethod, subdir, options,
      downloadPath = "", dep.vcsRevision)

    let downloadedPackageChecksum = calculateDirSha1Checksum(downloadDir)
    if downloadedPackageChecksum != dep.checksums.sha1:
      raise checksumError(name, dep.version, dep.vcsRevision,
                          downloadedPackageChecksum, dep.checksums.sha1)

    let (_, newlyInstalledPackageInfo) = installFromDir(
      downloadDir, version, options, url, first = false, fromLockFile = true)

    for depDepName in dep.dependencies:
      let depDep = pkgInfo.lockedDeps[depDepName]
      let revDep = (name: depDepName, version: depDep.version,
                    checksum: depDep.checksums.sha1) 
      options.nimbleData.addRevDep(revDep, newlyInstalledPackageInfo)

    return newlyInstalledPackageInfo
  else:
    let nimbleFilePath = findNimbleFile(depDirName, false)
    let packageInfo = getInstalledPackageMin(
      depDirName, nimbleFilePath).toFullInfo(options)
    return packageInfo

proc processLockedDependencies(pkgInfo: PackageInfo, options: Options):
    HashSet[PackageInfo] =
  # Returns a hash set with `PackageInfo` of all packages from the lock file of
  # the package `pkgInfo` by getting the info for develop mode dependencies from
  # their local file system directories and other packages from the Nimble
  # cache. If a package with required checksum is missing from the local cache
  # installs it by downloading it from its repository.

  let developModeDeps = getDevelopDependencies(pkgInfo, options)
  for name, dep in pkgInfo.lockedDeps:
    let depPkg =
      if developModeDeps.hasKey(name):
        developModeDeps[name][]
      else:
        getLockedDep(pkgInfo, name, dep, options)

    result.incl depPkg

proc getDownloadInfo*(pv: PkgTuple, options: Options,
                      doPrompt: bool): (DownloadMethod, string,
                                        Table[string, string]) =
  if pv.name.isURL:
    let (url, metadata) = getUrlData(pv.name)
    return (checkUrlType(url), url, metadata)
  else:
    var pkg = initPackage()
    if getPackage(pv.name, options, pkg):
      let (url, metadata) = getUrlData(pkg.url)
      return (pkg.downloadMethod, url, metadata)
    else:
      # If package is not found give the user a chance to refresh
      # package.json
      if doPrompt and
          options.prompt(pv.name & " not found in any local packages.json, " &
                         "check internet for updated packages?"):
        refresh(options)

        # Once we've refreshed, try again, but don't prompt if not found
        # (as we've already refreshed and a failure means it really
        # isn't there)
        return getDownloadInfo(pv, options, false)
      else:
        raise nimbleError(pkgNotFoundMsg(pv))

proc install(packages: seq[PkgTuple], options: Options,
             doPrompt, first, fromLockFile: bool): PackageDependenciesInfo =
  ## ``first``
  ##   True if this is the first level of the indirect recursion.
  ## ``fromLockFile``
  ##   True if we are installing dependencies from the lock file.

  if packages == @[]:
    let currentDir = getCurrentDir()
    if currentDir.developFileExists:
      displayWarning(
        "Installing a package which currently has develop mode dependencies." &
        "\nThey will be ignored and installed as normal packages.")
    result = installFromDir(currentDir, newVRAny(), options, "", first,
                            fromLockFile)
  else:
    # Install each package.
    for pv in packages:
      let (meth, url, metadata) = getDownloadInfo(pv, options, doPrompt)
      let subdir = metadata.getOrDefault("subdir")
      let (downloadDir, downloadVersion) =
          downloadPkg(url, pv.ver, meth, subdir, options, downloadPath = "",
                      vcsRevision = notSetSha1Hash)
      try:
        result = installFromDir(downloadDir, pv.ver, options, url,
                                first, fromLockFile)
      except BuildFailed as error:
        # The package failed to build.
        # Check if we tried building a tagged version of the package.
        let headVer = getHeadName(meth)
        if pv.ver.kind != verSpecial and downloadVersion != headVer and
           not fromLockFile:
          # If we tried building a tagged version of the package and this is not
          # fixed in the lock file version then ask the user whether they want
          # to try building #head.
          let promptResult = doPrompt and
              options.prompt(("Build failed for '$1@$2', would you" &
                  " like to try installing '$1@#head' (latest unstable)?") %
                  [pv.name, $downloadVersion])
          if promptResult:
            let toInstall = @[(pv.name, headVer.toVersionRange())]
            result =  install(toInstall, options, doPrompt, first,
                              fromLockFile = false)
          else:
            raise buildFailed(
              "Aborting installation due to build failure.", details = error)
        else:
          raise

proc getDependenciesPaths(pkgInfo: PackageInfo, options: Options):
    HashSet[string] =
  let deps = pkgInfo.processAllDependencies(options)
  return deps.map(dep => dep.getRealDir())

proc build(options: Options) =
  let dir = getCurrentDir()
  let pkgInfo = getPkgInfo(dir, options)
  nimScriptHint(pkgInfo)
  let paths = pkgInfo.getDependenciesPaths(options)
  var args = options.getCompilationFlags()
  buildFromDir(pkgInfo, paths, args, options)

proc execBackend(pkgInfo: PackageInfo, options: Options) =
  let
    bin = options.getCompilationBinary(pkgInfo).get("")
    binDotNim = bin.addFileExt("nim")

  if bin == "":
    raise nimbleError("You need to specify a file.")

  if not (fileExists(bin) or fileExists(binDotNim)):
    raise nimbleError(
      "Specified file, " & bin & " or " & binDotNim & ", does not exist.")

  let pkgInfo = getPkgInfo(getCurrentDir(), options)
  nimScriptHint(pkgInfo)
  let deps = pkgInfo.processAllDependencies(options)

  if not execHook(options, options.action.typ, true):
    raise nimbleError("Pre-hook prevented further execution.")

  var args = @["-d:NimblePkgVersion=" & $pkgInfo.version]
  for dep in deps:
    args.add("--path:" & dep.getRealDir().quoteShell)
  if options.verbosity >= HighPriority:
    # Hide Nim hints by default
    args.add("--hints:off")
  if options.verbosity == SilentPriority:
    # Hide Nim warnings
    args.add("--warnings:off")

  for option in options.getCompilationFlags():
    args.add(option.quoteShell)

  let backend =
    if options.action.backend.len > 0:
      options.action.backend
    else:
      pkgInfo.backend

  if options.action.typ == actionCompile:
    display("Compiling", "$1 (from package $2) using $3 backend" %
            [bin, pkgInfo.name, backend], priority = HighPriority)
  else:
    display("Generating", ("documentation for $1 (from package $2) using $3 " &
            "backend") % [bin, pkgInfo.name, backend], priority = HighPriority)

  doCmd(getNimBin(options).quoteShell & " $# --noNimblePath $# $#" %
        [backend, join(args, " "), bin.quoteShell])

  display("Success:", "Execution finished", Success, HighPriority)

  # Run the post hook for action if it exists
  discard execHook(options, options.action.typ, false)

proc search(options: Options) =
  ## Searches for matches in ``options.action.search``.
  ##
  ## Searches are done in a case insensitive way making all strings lower case.
  assert options.action.typ == actionSearch
  if options.action.search == @[]:
    raise nimbleError("Please specify a search string.")
  if needsRefresh(options):
    raise nimbleError("Please run nimble refresh.")
  let pkgList = getPackageList(options)
  var found = false
  template onFound {.dirty.} =
    echoPackage(pkg)
    if pkg.alias.len == 0 and options.queryVersions:
      echoPackageVersions(pkg)
    echo(" ")
    found = true
    break forPkg

  for pkg in pkgList:
    block forPkg:
      for word in options.action.search:
        # Search by name.
        if word.toLower() in pkg.name.toLower():
          onFound()
        # Search by tag.
        for tag in pkg.tags:
          if word.toLower() in tag.toLower():
            onFound()

  if not found:
    display("Error", "No package found.", Error, HighPriority)

proc list(options: Options) =
  if needsRefresh(options):
    raise nimbleError("Please run nimble refresh.")
  let pkgList = getPackageList(options)
  for pkg in pkgList:
    echoPackage(pkg)
    if pkg.alias.len == 0 and options.queryVersions:
      echoPackageVersions(pkg)
    echo(" ")

proc listInstalled(options: Options) =
  var h: OrderedTable[string, seq[Version]]
  let pkgs = getInstalledPkgsMin(options.getPkgsDir(), options)
  for pkg in pkgs:
    let
      pName = pkg.name
      pVer = pkg.specialVersion
    if not h.hasKey(pName): h[pName] = @[]
    var s = h[pName]
    add(s, pVer)
    h[pName] = s

  h.sort(proc (a, b: (string, seq[Version])): int = cmpIgnoreCase(a[0], b[0]))
  for k in keys(h):
    echo k & "  [" & h[k].join(", ") & "]"

type VersionAndPath = tuple[version: Version, path: string]

proc listPaths(options: Options) =
  ## Loops over the specified packages displaying their installed paths.
  ##
  ## If there are several packages installed, all of them will be displayed.
  ## If any package name is not found, the proc displays a missing message and
  ## continues through the list, but at the end quits with a non zero exit
  ## error.
  ##
  ## On success the proc returns normally.

  cli.setSuppressMessages(true)
  assert options.action.typ == actionPath

  if options.action.packages.len == 0:
    raise nimbleError("A package name needs to be specified")

  var errors = 0
  let pkgs = getInstalledPkgsMin(options.getPkgsDir(), options)
  for name, version in options.action.packages.items:
    var installed: seq[VersionAndPath] = @[]
    # There may be several, list all available ones and sort by version.
    for pkg in pkgs:
      if name == pkg.name:
        installed.add((pkg.specialVersion, pkg.getRealDir))

    if installed.len > 0:
      sort(installed, cmp[VersionAndPath], Descending)
      # The output for this command is used by tools so we do not use display().
      for pkg in installed:
        echo pkg.path
    else:
      display("Warning:", "Package '$1' is not installed" % name, Warning,
              MediumPriority)
      errors += 1
  if errors > 0:
    raise nimbleError(
        "At least one of the specified packages was not found")

proc join(x: seq[PkgTuple]; y: string): string =
  if x.len == 0: return ""
  result = x[0][0] & " " & $x[0][1]
  for i in 1 ..< x.len:
    result.add y
    result.add x[i][0] & " " & $x[i][1]

proc getPackageByPattern(pattern: string, options: Options): PackageInfo =
  ## Search for a package file using multiple strategies.
  if pattern == "":
    # Not specified - using current directory
    result = getPkgInfo(os.getCurrentDir(), options)
  elif pattern.splitFile.ext == ".nimble" and pattern.fileExists:
    # project file specified
    result = getPkgInfoFromFile(pattern, options)
  elif pattern.dirExists:
    # project directory specified
    result = getPkgInfo(pattern, options)
  else:
    # Last resort - attempt to read as package identifier
    let packages = getInstalledPkgsMin(options.getPkgsDir(), options)
    let identTuple = parseRequires(pattern)
    var skeletonInfo = initPackageInfo()
    if not findPkg(packages, identTuple, skeletonInfo):
      raise nimbleError(
          "Specified package not found"
      )
    result = getPkgInfoFromFile(skeletonInfo.myPath, options)

proc dump(options: Options) =
  cli.setSuppressMessages(true)
  let p = getPackageByPattern(options.action.projName, options)
  var j: JsonNode
  var s: string
  let json = options.dumpMode == kdumpJson
  if json: j = newJObject()
  template fn(key, val) =
    if json:
      when val is seq[PkgTuple]:
        # jsonutils.toJson would work but is only available since 1.3.5, so we
        # do it manually.
        j[key] = newJArray()
        for (name, ver) in val:
          j[key].add %{
            "name": % name,
            # we serialize both: `ver` may be more convenient for tooling
            # (no parsing needed); while `str` is more familiar.
            "str": % $ver,
            "ver": %* ver,
          }
      else:
        j[key] = %*val
    else:
      if s.len > 0: s.add "\n"
      s.add key & ": "
      when val is string:
        s.add val.escape
      else:
        s.add val.join(", ").escape
  fn "name", p.name
  fn "version", $p.version
  fn "author", p.author
  fn "desc", p.description
  fn "license", p.license
  fn "skipDirs", p.skipDirs
  fn "skipFiles", p.skipFiles
  fn "skipExt", p.skipExt
  fn "installDirs", p.installDirs
  fn "installFiles", p.installFiles
  fn "installExt", p.installExt
  fn "requires", p.requires
  fn "bin", toSeq(p.bin.values)
  fn "binDir", p.binDir
  fn "srcDir", p.srcDir
  fn "backend", p.backend
  if json:
    s = j.pretty
  echo s

proc init(options: Options) =
  # Check whether the vcs is installed.
  let vcsBin = options.action.vcsOption
  if vcsBin != "" and findExe(vcsBin, true) == "":
    raise nimbleError("Please install git or mercurial first")

  # Determine the package name.
  let pkgName =
    if options.action.projName != "":
      options.action.projName
    else:
      os.getCurrentDir().splitPath.tail.toValidPackageName()

  # Validate the package name.
  validatePackageName(pkgName)

  # Determine the package root.
  let pkgRoot =
    if pkgName == os.getCurrentDir().splitPath.tail:
      os.getCurrentDir()
    else:
      os.getCurrentDir() / pkgName

  let nimbleFile = (pkgRoot / pkgName).changeFileExt("nimble")

  if fileExists(nimbleFile):
    let errMsg = "Nimble file already exists: $#" % nimbleFile
    raise nimbleError(errMsg)

  if options.forcePrompts != forcePromptYes:
    display(
      "Info:",
      "Package initialisation requires info which could not be inferred.\n" &
      "Default values are shown in square brackets, press\n" &
      "enter to use them.",
      priority = HighPriority
    )
  display("Using", "$# for new package name" % [pkgName.escape()],
    priority = HighPriority)

  # Determine author by running an external command
  proc getAuthorWithCmd(cmd: string): string =
    let (name, exitCode) = doCmdEx(cmd)
    if exitCode == QuitSuccess and name.len > 0:
      result = name.strip()
      display("Using", "$# for new package author" % [result],
        priority = HighPriority)

  # Determine package author via git/hg or asking
  proc getAuthor(): string =
    if findExe("git") != "":
      result = getAuthorWithCmd("git config --global user.name")
    elif findExe("hg") != "":
      result = getAuthorWithCmd("hg config ui.username")
    if result.len == 0:
      result = promptCustom(options, "Your name?", "Anonymous")
  let pkgAuthor = getAuthor()

  # Declare the src/ directory
  let pkgSrcDir = "src"
  display("Using", "$# for new package source directory" % [pkgSrcDir.escape()],
    priority = HighPriority)

  # Determine the type of package
  let pkgType = promptList(
    options,
    """Package type?
Library - provides functionality for other packages.
Binary  - produces an executable for the end-user.
Hybrid  - combination of library and binary

For more information see https://goo.gl/cm2RX5""",
    ["library", "binary", "hybrid"]
  )

  # Ask for package version.
  let pkgVersion = promptCustom(options, "Initial version of package?", "0.1.0")
  validateVersion(pkgVersion)

  # Ask for description
  let pkgDesc = promptCustom(options, "Package description?",
    "A new awesome nimble package")

  # Ask for license
  # License list is based on:
  # https://www.blackducksoftware.com/top-open-source-licenses
  var pkgLicense = options.promptList(
    """Package License?
This should ideally be a valid SPDX identifier. See https://spdx.org/licenses/.
""", [
    "MIT",
    "GPL-2.0",
    "Apache-2.0",
    "ISC",
    "GPL-3.0",
    "BSD-3-Clause",
    "LGPL-2.1",
    "LGPL-3.0",
    "EPL-2.0",
    "AGPL-3.0",
    # This is what npm calls "UNLICENSED" (which is too similar to "Unlicense")
    "Proprietary",
    "Other"
  ])

  if pkgLicense.toLower == "other":
    pkgLicense = promptCustom(options,
      """Package license?
Please specify a valid SPDX identifier.""",
      "MIT"
    )

  if pkgLicense in ["GPL-2.0", "GPL-3.0", "LGPL-2.1", "LGPL-3.0", "AGPL-3.0"]:
    let orLater = options.promptList(
      "\"Or any later version\" clause?", ["Yes", "No"])
    if orLater == "Yes":
      pkgLicense.add("-or-later")
    else:
      pkgLicense.add("-only")

  # Ask for Nim dependency
  let nimDepDef = getNimrodVersion(options)
  let pkgNimDep = promptCustom(options, "Lowest supported Nim version?",
    $nimDepDef)
  validateVersion(pkgNimDep)

  createPkgStructure(
    (
      pkgName,
      pkgVersion,
      pkgAuthor,
      pkgDesc,
      pkgLicense,
      pkgSrcDir,
      pkgNimDep,
      pkgType
    ),
    pkgRoot
  )

  # Create a git or hg repo in the new nimble project.
  if vcsBin != "":
    let cmd = fmt"cd {pkgRoot} && {vcsBin} init"
    let ret: tuple[output: string, exitCode: int] = execCmdEx(cmd)
    if ret.exitCode != 0: quit ret.output

    var ignoreFile = if vcsBin == "git": ".gitignore" else: ".hgignore"
    var fd = open(joinPath(pkgRoot, ignoreFile), fmWrite)
    fd.write(pkgName & "\n")
    fd.close()

  display("Success:", "Package $# created successfully" % [pkgName], Success,
    HighPriority)

proc removePackages(pkgs: HashSet[ReverseDependency], options: var Options) =
  for pkg in pkgs:
    let pkgInfo = pkg.toPkgInfo(options)
    case pkg.kind
    of rdkInstalled:
      pkgInfo.removePackage(options)
      display("Removed", $pkg, Success, HighPriority)
    of rdkDevelop:
      options.nimbleData.removeRevDep(pkgInfo)

proc collectNames(pkgs: HashSet[ReverseDependency],
                  includeDevelopRevDeps: bool): seq[string] =
  for pkg in pkgs:
    if pkg.kind != rdkDevelop or includeDevelopRevDeps:
      result.add $pkg

proc uninstall(options: var Options) =
  if options.action.packages.len == 0:
    raise nimbleError(
        "Please specify the package(s) to uninstall.")

  var pkgsToDelete: HashSet[ReverseDependency]
  # Do some verification.
  for pkgTup in options.action.packages:
    display("Looking", "for $1 ($2)" % [pkgTup.name, $pkgTup.ver],
            priority = HighPriority)
    let installedPkgs = getInstalledPkgsMin(options.getPkgsDir(), options)
    var pkgList = findAllPkgs(installedPkgs, pkgTup)
    if pkgList.len == 0:
      raise nimbleError("Package not found")

    display("Checking", "reverse dependencies", priority = HighPriority)
    for pkg in pkgList:
      # Check whether any packages depend on the ones the user is trying to
      # uninstall.
      if options.uninstallRevDeps:
        getAllRevDeps(options.nimbleData, pkg.toRevDep, pkgsToDelete)
      else:
        let revDeps = options.nimbleData.getRevDeps(pkg.toRevDep)
        if len(revDeps - pkgsToDelete) > 0:
          let pkgs = revDeps.collectNames(true)
          displayWarning(
            cannotUninstallPkgMsg(pkgTup.name, pkg.specialVersion, pkgs))
        else:
          pkgsToDelete.incl pkg.toRevDep

  if pkgsToDelete.len == 0:
    raise nimbleError("Failed uninstall - no packages to delete")

  if not options.prompt(pkgsToDelete.collectNames(false).promptRemovePkgsMsg):
    raise nimbleQuit()

  removePackages(pkgsToDelete, options)

proc listTasks(options: Options) =
  let nimbleFile = findNimbleFile(getCurrentDir(), true)
  nimscriptwrapper.listTasks(nimbleFile, options)

proc developFromDir(pkgInfo: PackageInfo, options: Options) =
  let dir = pkgInfo.getNimbleFileDir()

  if options.depsOnly:
    raise nimbleError("Cannot develop dependencies only.")

  cd dir: # Make sure `execHook` executes the correct .nimble file.
    if not execHook(options, actionDevelop, true):
      raise nimbleError("Pre-hook prevented further execution.")

  if pkgInfo.bin.len > 0:
    if "nim" in pkgInfo.skipExt:
      raise nimbleError("Cannot develop packages that are binaries only.")

    displayWarning(
      "This package's binaries will not be compiled for development.")

  if options.developLocaldeps:
    var optsCopy = options
    optsCopy.nimbleDir = dir / nimbledeps
    optsCopy.nimbleData = newNimbleDataNode()
    optsCopy.startDir = dir
    createDir(optsCopy.getPkgsDir())
    cd dir:
      discard processAllDependencies(pkgInfo, optsCopy)
  else:
    # Dependencies need to be processed before the creation of the pkg dir.
    discard processAllDependencies(pkgInfo, options)

  displaySuccess(pkgSetupInDevModeMsg(pkgInfo.name, dir))

  # Execute the post-develop hook.
  cd dir:
    discard execHook(options, actionDevelop, false)

proc installDevelopPackage(pkgTup: PkgTuple, options: Options): string =
  let (meth, url, metadata) = getDownloadInfo(pkgTup, options, true)
  let subdir = metadata.getOrDefault("subdir")

  let name =
    if isURL(pkgTup.name):
      if subdir.len == 0:
        parseUri(pkgTup.name).path.splitFile.name
      else:
        subdir.splitFile.name
    else:
      pkgTup.name

  let downloadDir =
    if options.action.path.isAbsolute:
      options.action.path / name
    else:
      getCurrentDir() / options.action.path / name

  if dirExists(downloadDir):
    let msg = "Cannot clone into '$1': directory exists." % downloadDir
    let hint = "Remove the directory, or run this command somewhere else."
    raise nimbleError(msg, hint)

  # Download the HEAD and make sure the full history is downloaded.
  let ver =
    if pkgTup.ver.kind == verAny:
      parseVersionRange("#head")
    else:
      pkgTup.ver

  var options = options
  options.forceFullClone = true
  discard downloadPkg(url, ver, meth, subdir, options, downloadDir,
                      vcsRevision = notSetSha1Hash)

  let pkgDir = downloadDir / subdir
  var pkgInfo = getPkgInfo(pkgDir, options)

  developFromDir(pkgInfo, options)

  return pkgInfo.getNimbleFileDir

proc updateSyncFile(dependentPkg: PackageInfo, options: Options)

proc updatePathsFile(pkgInfo: PackageInfo, options: Options) =
  let paths = pkgInfo.getDependenciesPaths(options)
  var pathsFileContent: string
  for path in paths:
    pathsFileContent &= &"--path:{path.escape}\n"
  var action = if fileExists(nimblePathsFileName): "updated" else: "generated"
  writeFile(nimblePathsFileName, pathsFileContent)
  displayInfo(&"\"{nimblePathsFileName}\" is {action}.")

proc develop(options: var Options) =
  let
    hasPackages = options.action.packages.len > 0
    hasPath = options.action.path.len > 0
    hasDevActions = options.action.devActions.len > 0

  if not hasPackages and hasPath:
    raise nimbleError(pathGivenButNoPkgsToDownloadMsg)

  var
    currentDirPkgInfo = initPackageInfo()
    hasError = false
    hasDevActionsAllowedOnlyInPkgDir = options.action.devActions.filterIt(
      it[0] != datNewFile).len > 0

  try:
    # Check whether the current directory is a package directory.
    currentDirPkgInfo = getPkgInfo(getCurrentDir(), options)
  except CatchableError as error:
    if hasDevActionsAllowedOnlyInPkgDir:
      raise nimbleError(developOptionsOutOfPkgDirectoryMsg, details = error)

  if currentDirPkgInfo.isLoaded and (not hasPackages) and (not hasDevActions):
    developFromDir(currentDirPkgInfo, options)

  # Install each package.
  for pkgTup in options.action.packages:
    try:
      let pkgPath = installDevelopPackage(pkgTup, options)
      if currentDirPkgInfo.isLoaded:
        options.action.devActions.add (datAdd, pkgPath.normalizedPath)
        hasDevActionsAllowedOnlyInPkgDir = true
    except CatchableError as error:
      hasError = true
      displayError(&"Cannot install package \"{pkgTup}\" for develop.")
      displayDetails(error)

  if hasDevActionsAllowedOnlyInPkgDir:
    hasError = not updateDevelopFile(currentDirPkgInfo, options) or hasError
  else:
    hasError = not executeDevActionsAllowedOutsidePkgDir(options) or hasError

  if hasDevActionsAllowedOnlyInPkgDir:
    updateSyncFile(currentDirPkgInfo, options)
    if fileExists(nimblePathsFileName):
      updatePathsFile(currentDirPkgInfo, options)

  if hasError:
    raise nimbleError(
      "There are some errors while executing the operation.",
      "See the log above for more details.")

proc test(options: Options) =
  ## Executes all tests starting with 't' in the ``tests`` directory.
  ## Subdirectories are not walked.
  var pkgInfo = getPkgInfo(getCurrentDir(), options)

  var
    files = toSeq(walkDir(getCurrentDir() / "tests"))
    tests, failures: int

  if files.len < 1:
    display("Warning:", "No tests found!", Warning, HighPriority)
    return

  if not execHook(options, actionCustom, true):
    raise nimbleError("Pre-hook prevented further execution.")

  files.sort((a, b) => cmp(a.path, b.path))

  for file in files:
    let (_, name, ext) = file.path.splitFile()
    if ext == ".nim" and name[0] == 't' and file.kind in {pcFile, pcLinkToFile}:
      var optsCopy = options
      optsCopy.action = Action(typ: actionCompile)
      optsCopy.action.file = file.path
      optsCopy.action.backend = pkgInfo.backend
      optsCopy.getCompilationFlags() = options.getCompilationFlags()
      # treat run flags as compile for default test task
      optsCopy.getCompilationFlags().add(options.action.custRunFlags)
      optsCopy.getCompilationFlags().add("-r")
      optsCopy.getCompilationFlags().add("--path:.")
      let
        binFileName = file.path.changeFileExt(ExeExt)
        existsBefore = fileExists(binFileName)

      if options.continueTestsOnFailure:
        inc tests
        try:
          execBackend(pkgInfo, optsCopy)
        except NimbleError:
          inc failures
      else:
        execBackend(pkgInfo, optsCopy)

      let
        existsAfter = fileExists(binFileName)
        canRemove = not existsBefore and existsAfter
      if canRemove:
        try:
          removeFile(binFileName)
        except OSError as exc:
          display("Warning:", "Failed to delete " & binFileName & ": " &
                  exc.msg, Warning, MediumPriority)

  if failures == 0:
    display("Success:", "All tests passed", Success, HighPriority)
  else:
    let error = "Only " & $(tests - failures) & "/" & $tests & " tests passed"
    display("Error:", error, Error, HighPriority)

  if not execHook(options, actionCustom, false):
    return

proc check(options: Options) =
  try:
    let pkgInfo = getPkgInfo(getCurrentDir(), options, true)
    validateDevelopFile(pkgInfo, options)
    displaySuccess(&"The package \"{pkgInfo.name}\" is valid.")
  except CatchableError as error:
    displayError(error)
    display("Failure:", validationFailedMsg, Error, HighPriority)
    raise nimbleQuit(QuitFailure)

proc updateSyncFile(dependentPkg: PackageInfo, options: Options) =
  # Updates the sync file with the current VCS revisions of develop mode
  # dependencies of the package `dependentPkg`.

  let developDeps = processDevelopDependencies(dependentPkg, options).toHashSet
  let syncFile = getSyncFile(dependentPkg)

  # Remove old data from the sync file
  syncFile.clear

  # Add all current develop packages' VCS revisions to the sync file.
  for dep in developDeps:
    syncFile.setDepVcsRevision(dep.name, dep.vcsRevision)

  syncFile.save

proc validateDevModeDepsWorkingCopiesBeforeLock(
    pkgInfo: PackageInfo, options: Options) =
  ## Validates that the develop mode dependencies states are suitable for
  ## locking. They must be under version control, their working copies must be
  ## in a clean state and their current VCS revision must be present on some of
  ## the configured remotes.

  var errors: ValidationErrors
  findValidationErrorsOfDevDepsWithLockFile(pkgInfo, options, errors)

  # Those validation errors are not errors in the context of generating a lock
  # file.
  const notAnErrorSet = {
    vekWorkingCopyNeedsSync,
    vekWorkingCopyNeedsLock,
    vekWorkingCopyNeedsMerge,
    }
  
  # Remove not errors from the errors set.
  for name, error in common.dup(errors):
    if error.kind in notAnErrorSet:
      errors.del name

  if errors.len > 0:
    raise validationErrors(errors)

proc mergeLockedDependencies*(pkgInfo: PackageInfo, newDeps: LockFileDeps,
                              options: Options): LockFileDeps =
  ## Updates the lock file data of already generated lock file with the data
  ## from a new lock operation.

  result = pkgInfo.lockedDeps
  let developDeps = pkgInfo.getDevelopDependencies(options)

  for name, dep in newDeps:
    if result.hasKey(name):
      # If the dependency is already present in the old lock file
      if developDeps.hasKey(name):
        # and it is a develop mode dependency update it with the newly locked
        # version,
        result[name] = dep
      else:
        # but if it is installed dependency just leave it at the current
        # version.
        discard
    else:
      # If the dependency is missing from the old develop file add it.
      result[name] = dep

  # Clean dependencies which are missing from the newly locked list.
  let deps = result
  for name, dep in deps:
    if not newDeps.hasKey(name):
      result.del name

proc displayLockOperationStart(dir: string): bool =
  ## Displays a proper log message for starting generating or updating the lock
  ## file of a package in directory `dir`.
  
  var doesLockFileExist = dir.lockFileExists
  let msg = if doesLockFileExist:
    updatingTheLockFileMsg
  else:
    generatingTheLockFileMsg
  displayInfo(msg)
  return doesLockFileExist

proc displayLockOperationFinish(didLockFileExist: bool) =
  ## Displays a proper log message for finished generation or update of a lock
  ## file.

  let msg = if didLockFileExist:
    lockFileIsUpdatedMsg
  else:
    lockFileIsGeneratedMsg
  displaySuccess(msg)

proc lock(options: Options) =
  ## Generates a lock file for the package in the current directory or updates 
  ## it if it already exists.

  let currentDir = getCurrentDir()
  let pkgInfo = getPkgInfo(currentDir, options)

  let doesLockFileExist = displayLockOperationStart(currentDir)
  validateDevModeDepsWorkingCopiesBeforeLock(pkgInfo, options)

  let dependencies = pkgInfo.processFreeDependencies(options).map(
    pkg => pkg.toFullInfo(options))
  var dependencyGraph = buildDependencyGraph(dependencies.toSeq, options)

  if currentDir.lockFileExists:
    # If we already have a lock file, merge its data with the newly generated
    # one.
    #
    # IMPORTANT TODO:
    # To do this properly, an SMT solver is needed, but anyway, it seems that
    # currently Nimble does not check properly for `require` clauses
    # satisfaction between all packages, but just greedily picks the best
    # matching version of dependencies for the currently processed package.

    dependencyGraph = mergeLockedDependencies(pkgInfo, dependencyGraph, options)

  let (topologicalOrder, _) = topologicalSort(dependencyGraph)
  writeLockFile(dependencyGraph, topologicalOrder)
  updateSyncFile(pkgInfo, options)
  displayLockOperationFinish(doesLockFileExist)

proc syncWorkingCopy(name: string, path: Path, dependentPkg: PackageInfo,
                     options: Options) =
  ## Syncs a working copy of a develop mode dependency of package `dependentPkg`
  ## with name `name` at path `path` with the revision from the lock file of
  ## `dependentPkg`.

  displayInfo(&"Syncing working copy of package \"{name}\" at \"{path}\"...")

  let lockedDeps = dependentPkg.lockedDeps
  assert lockedDeps.hasKey(name),
         &"Package \"{name}\" must be present in the lock file."

  let vcsRevision = lockedDeps[name].vcsRevision
  assert vcsRevision != path.getVcsRevision,
        "If here the working copy VCS revision must be different from the " &
        "revision written in the lock file."

  try:
    if not isVcsRevisionPresentOnSomeBranch(path, vcsRevision):
      # If the searched revision is not present on some local branch retrieve
      # changes sets from the remote branch corresponding to the local one.
      let (remote, branch) = getCorrespondingRemoteAndBranch(path)
      retrieveRemoteChangeSets(path, remote, branch)

    if not isVcsRevisionPresentOnSomeBranch(path, vcsRevision):
      # If the revision is still not found retrieve all remote change sets.
      retrieveRemoteChangeSets(path)

    let
      currentBranch = getCurrentBranch(path)
      localBranches = getBranchesOnWhichVcsRevisionIsPresent(
        path, vcsRevision, btLocal)
      remoteTrackingBranches = getBranchesOnWhichVcsRevisionIsPresent(
        path, vcsRevision, btRemoteTracking)
      allBranches = localBranches + remoteTrackingBranches

    var targetBranch = 
      if allBranches.len == 0:
        # Te revision is not found on any branch.
        ""
      elif localBranches.len == 1:
        # If the revision is present on only one local branch switch to it.
        localBranches.toSeq[0]
      elif localBranches.contains(currentBranch):
        # If the current branch is among the local branches on which the
        # revision is found we have to stay to it.
        currentBranch
      elif remoteTrackingBranches.len == 1:
        # If the revision is found on only one remote tracking branch we have to
        # fast forward merge it to a corresponding local branch and to switch to
        # it.
        remoteTrackingBranches.toSeq[0]
      elif (let (hasBranch, branchName) = hasCorrespondingRemoteBranch(
              path, remoteTrackingBranches); hasBranch):
        # If the current branch has corresponding remote tracking branch on
        # which the revision is found we have to get the name of the remote
        # tracking branch in order to try to fast forward merge it to the local
        # branch.
        branchName
      else:
        # If the revision is found on several branches, but nighter of them is
        # the current one or a remote tracking branch corresponding to the
        # current one then give the user a choice to which branch to switch.
        options.promptList(
          &"The revision \"{vcsRevision}\" is found on multiple branches.\n" &
          "Choose a branch to switch to:",
          allBranches.toSeq.toOpenArray(0, allBranches.len - 1))

    if path.getVcsType == vcsTypeGit and
       remoteTrackingBranches.contains(targetBranch):
      # If the target branch is a remote tracking branch get all local branches
      # which track it.
      let localBranches = getLocalBranchesTrackingRemoteBranch(
        path, targetBranch)
      let localBranch =
        if localBranches.len == 0:
          # There is no local branch tracking the remote branch and we have to
          # get a name for a new branch.
          getLocalBranchName(path, targetBranch)
        elif localBranches.len == 1:
          # There is only one local branch tracking the remote branch.
          localBranches[0]
        else:
          # If there are multiple local branches which track the remote branch
          # then give the user a choice to which to try to fast forward merge
          # the remote branch.
          options.promptList("Choose local branch where to try to fast " &
                             &"forward merge \"{targetBranch}\":",
            localBranches.toOpenArray(0, localBranches.len - 1))
      fastForwardMerge(path, targetBranch, localBranch)
      targetBranch = localBranch

    if targetBranch != "":
      if targetBranch != currentBranch:
        switchBranch(path, targetBranch)
      if path.getVcsRevision != vcsRevision:
        setCurrentBranchToVcsRevision(path, vcsRevision)
    else:
      # If the revision is not found on any branch try to set the package
      # working copy to it in detached state. If the revision is completely
      # missing the operation will fail with exception.
      setWorkingCopyToVcsRevision(path, vcsRevision)

    displayInfo(pkgWorkingCopyIsSyncedMsg(name, $path))
  except CatchableError as error:
    displayError(&"Working copy of package \"{name}\" at path \"{path}\" " &
                  "cannot be synced.")
    displayDetails(error.msg)

proc sync(options: Options) =
  # Syncs working copies of the develop mode dependencies of the current
  # directory package with the revision data from the lock file.

  let currentDir = getCurrentDir()
  let pkgInfo = getPkgInfo(currentDir, options)

  if not pkgInfo.areLockedDepsLoaded:
    raise nimbleError("Cannot execute `sync` when lock file is missing.")

  if not options.action.listOnly:
    # On `sync` we also want to update Nimble cache with the dependencies'
    # versions from the lock file.
    discard processLockedDependencies(pkgInfo, options)
    if fileExists(nimblePathsFileName):
      updatePathsFile(pkgInfo, options)

  var errors: ValidationErrors
  findValidationErrorsOfDevDepsWithLockFile(pkgInfo, options, errors)

  for name, error in common.dup(errors):
    if error.kind == vekWorkingCopyNeedsSync:
      if not options.action.listOnly:
        syncWorkingCopy(name, error.path, pkgInfo, options)
      else:
        displayInfo(pkgWorkingCopyNeedsSyncingMsg(name, $error.path))
      # Remove sync errors because we are doing sync.
      errors.del name

  updateSyncFile(pkgInfo, options)

  if errors.len > 0:
    raise validationErrors(errors)

proc append(existingContent: var string; newContent: string) =
  ## Appends `newContent` to the `existingContent` on a new line by inserting it
  ## if the new line doesn't already exist.
  if existingContent.len > 0 and existingContent[^1] != '\n':
    existingContent &= "\n"
  existingContent &= newContent

proc setupNimbleConfig(options: Options) =
  ## Creates `nimble.paths` file containing file system paths to the
  ## dependencies. Includes it in `config.nims` file to make them available
  ## for the compiler.
  const
    configFileVersion = "0.1.0"
    configFileHeader = &"# begin Nimble config (version {configFileVersion})\n"
    configFileContent = fmt"""
when fileExists("{nimblePathsFileName}"):
  include "{nimblePathsFileName}"
# end Nimble config
"""

  let
    currentDir = getCurrentDir()
    pkgInfo = getPkgInfo(currentDir, options)

  updatePathsFile(pkgInfo, options)

  var
    writeFile = false
    fileContent: string

  proc appendNimbleConfigFileHeaderAndContent =
    fileContent.append(configFileHeader)
    fileContent.append(configFileContent)

  if fileExists(nimbleConfigFileName):
    fileContent = readFile(nimbleConfigFileName)
    if not fileContent.contains(configFileHeader):
      appendNimbleConfigFileHeaderAndContent()
      writeFile = true
  else:
    appendNimbleConfigFileHeaderAndContent()
    writeFile = true

  if writeFile:
    writeFile(nimbleConfigFileName, fileContent)
    displayInfo(&"\"{nimbleConfigFileName}\" is set up.")
  else:
    displayInfo(&"\"{nimbleConfigFileName}\" is already set up.")

proc setupVcsIgnoreFile =
  ## Adds the names of some files which should not be committed to the VCS
  ## ignore file.
  let
    currentDir = getCurrentDir()
    vcsIgnoreFileName = case currentDir.getVcsType
      of vcsTypeGit: gitIgnoreFileName
      of vcsTypeHg: hgIgnoreFileName
      of vcsTypeNone: ""

  if vcsIgnoreFileName.len == 0:
    return

  var
    writeFile = false
    fileContent: string

  if fileExists(vcsIgnoreFileName):
    fileContent = readFile(vcsIgnoreFileName)
    if not fileContent.contains(developFileName):
      fileContent.append(developFileName)
      writeFile = true
    if not fileContent.contains(nimblePathsFileName):
      fileContent.append(nimblePathsFileName)
      writeFile = true
  else:
    fileContent.append(developFileName)
    fileContent.append(nimblePathsFileName)
    writeFile = true

  if writeFile:
    writeFile(vcsIgnoreFileName, fileContent & "\n")

proc setup(options: Options) =
  setupNimbleConfig(options)
  setupVcsIgnoreFile()

proc run(options: Options) =
  # Verify parameters.
  var pkgInfo = getPkgInfo(getCurrentDir(), options)

  let binary = options.getCompilationBinary(pkgInfo).get("")
  if binary.len == 0:
    raise nimbleError("Please specify a binary to run")

  if binary notin pkgInfo.bin:
    raise nimbleError(
      "Binary '$#' is not defined in '$#' package." % [binary, pkgInfo.name]
    )

  # Build the binary.
  build(options)

  let binaryPath = pkgInfo.getOutputDir(binary)
  let cmd = quoteShellCommand(binaryPath & options.action.runFlags)
  displayDebug("Executing", cmd)

  let exitCode = cmd.execCmd
  raise nimbleQuit(exitCode)

proc doAction(options: var Options) =
  if options.showHelp:
    writeHelp()
  if options.showVersion:
    writeVersion()

  if options.action.typ in {actionTasks, actionRun, actionBuild, actionCompile}:
    # Implicitly disable package validation for these commands.
    options.disableValidation = true

  case options.action.typ
  of actionRefresh:
    refresh(options)
  of actionInstall:
    let (_, pkgInfo) = install(options.action.packages, options,
                               doPrompt = true,
                               first = true,
                               fromLockFile = false)
    if options.action.packages.len == 0:
      nimScriptHint(pkgInfo)
    if pkgInfo.foreignDeps.len > 0:
      display("Hint:", "This package requires some external dependencies.",
              Warning, HighPriority)
      display("Hint:", "To install them you may be able to run:",
              Warning, HighPriority)
      for i in 0..<pkgInfo.foreignDeps.len:
        display("Hint:", "  " & pkgInfo.foreignDeps[i], Warning, HighPriority)
  of actionUninstall:
    uninstall(options)
  of actionSearch:
    search(options)
  of actionList:
    if options.queryInstalled: listInstalled(options)
    else: list(options)
  of actionPath:
    listPaths(options)
  of actionBuild:
    build(options)
  of actionRun:
    run(options)
  of actionCompile, actionDoc:
    var pkgInfo = getPkgInfo(getCurrentDir(), options)
    execBackend(pkgInfo, options)
  of actionInit:
    init(options)
  of actionPublish:
    var pkgInfo = getPkgInfo(getCurrentDir(), options)
    publish(pkgInfo, options)
  of actionDump:
    dump(options)
  of actionTasks:
    listTasks(options)
  of actionDevelop:
    develop(options)
  of actionCheck:
    check(options)
  of actionLock:
    lock(options)
  of actionSync:
    sync(options)
  of actionSetup:
    setup(options)
  of actionNil:
    assert false
  of actionCustom:
    let
      command = options.action.command.normalize
      nimbleFile = findNimbleFile(getCurrentDir(), true)
      pkgInfo = getPkgInfoFromFile(nimbleFile, options)

    if command in pkgInfo.nimbleTasks:
      # If valid task defined in nimscript, run it
      var execResult: ExecutionResult[bool]
      if execCustom(nimbleFile, options, execResult):
        if execResult.hasTaskRequestedCommand():
          var options = execResult.getOptionsForCommand(options)
          doAction(options)
    elif command == "test":
      # If there is no task defined for the `test` task, we run the pre-defined
      # fallback logic.
        test(options)
    else:
      raise nimbleError(msg = "Could not find task $1 in $2" %
                              [options.action.command, nimbleFile],
                        hint = "Run `nimble --help` and/or `nimble tasks` for" &
                               " a list of possible commands.")

when isMainModule:
  var exitCode = QuitSuccess

  var opt: Options
  try:
    opt = parseCmdLine()
    opt.setNimBin
    opt.setNimbleDir
    opt.loadNimbleData
    opt.doAction()
  except NimbleQuit as quit:
    exitCode = quit.exitCode
  except CatchableError as error:
    exitCode = QuitFailure
    displayTip()
    displayError(error)
  finally:
    try:
      let folder = getNimbleTempDir()
      if opt.shouldRemoveTmp(folder):
        removeDir(folder)
    except CatchableError as error:
      displayWarning("Couldn't remove Nimble's temp dir")
      displayDetails(error)

    try:
      saveNimbleData(opt)
    except CatchableError as error:
      exitCode = QuitFailure
      displayError(&"Couldn't save \"{nimbleDataFileName}\".")
      displayDetails(error)

  quit(exitCode)
