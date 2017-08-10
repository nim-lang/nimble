# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import system except TResult

import httpclient, parseopt, os, osproc, pegs, tables, parseutils,
       strtabs, json, algorithm, sets, uri

import strutils except toLower
from unicode import toLower
from sequtils import toSeq

import nimblepkg/packageinfo, nimblepkg/version, nimblepkg/tools,
       nimblepkg/download, nimblepkg/config, nimblepkg/common,
       nimblepkg/publish, nimblepkg/options, nimblepkg/packageparser,
       nimblepkg/cli

import nimblepkg/nimscriptsupport

when not defined(windows):
  from posix import getpid
else:
  # This is just for Win XP support.
  # TODO: Drop XP support?
  from winlean import WINBOOL, DWORD
  type
    OSVERSIONINFO* {.final, pure.} = object
      dwOSVersionInfoSize*: DWORD
      dwMajorVersion*: DWORD
      dwMinorVersion*: DWORD
      dwBuildNumber*: DWORD
      dwPlatformId*: DWORD
      szCSDVersion*: array[0..127, char]

  proc GetVersionExA*(VersionInformation: var OSVERSIONINFO): WINBOOL{.stdcall,
    dynlib: "kernel32", importc: "GetVersionExA".}

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
        raise newException(NimbleError, msg)

      fetchList(options.config.packageLists[parameter], options)
  else:
    # Try each package list in config
    for name, list in options.config.packageLists:
      fetchList(list, options)

proc checkInstallFile(pkgInfo: PackageInfo,
                      origDir, file: string): bool =
  ## Checks whether ``file`` should be installed.
  ## ``True`` means file should be skipped.

  for ignoreFile in pkgInfo.skipFiles:
    if ignoreFile.endswith("nimble"):
      raise newException(NimbleError, ignoreFile & " must be installed.")
    if samePaths(file, origDir / ignoreFile):
      result = true
      break

  for ignoreExt in pkgInfo.skipExt:
    if file.splitFile.ext == ('.' & ignoreExt):
      result = true
      break

  if file.splitFile().name[0] == '.': result = true

proc checkInstallDir(pkgInfo: PackageInfo,
                     origDir, dir: string): bool =
  ## Determines whether ``dir`` should be installed.
  ## ``True`` means dir should be skipped.
  for ignoreDir in pkgInfo.skipDirs:
    if samePaths(dir, origDir / ignoreDir):
      result = true
      break

  let thisDir = splitPath(dir).tail
  assert thisDir != ""
  if thisDir[0] == '.': result = true
  if thisDir == "nimcache": result = true

proc copyWithExt(origDir, currentDir, dest: string,
                 pkgInfo: PackageInfo): seq[string] =
  ## Returns the filenames of the files that have been copied
  ## (their destination).
  result = @[]
  for kind, path in walkDir(currentDir):
    if kind == pcDir:
      result.add copyWithExt(origDir, path, dest, pkgInfo)
    else:
      for iExt in pkgInfo.installExt:
        if path.splitFile.ext == ('.' & iExt):
          createDir(changeRoot(origDir, dest, path).splitFile.dir)
          result.add copyFileD(path, changeRoot(origDir, dest, path))

proc copyFilesRec(origDir, currentDir, dest: string,
                  options: Options, pkgInfo: PackageInfo): HashSet[string] =
  ## Copies all the required files, skips files specified in the .nimble file
  ## (PackageInfo).
  ## Returns a list of filepaths to files which have been installed.
  result = initSet[string]()
  let whitelistMode =
          pkgInfo.installDirs.len != 0 or
          pkgInfo.installFiles.len != 0 or
          pkgInfo.installExt.len != 0
  if whitelistMode:
    for file in pkgInfo.installFiles:
      let src = origDir / file
      if not src.existsFile():
        if options.prompt("Missing file " & src & ". Continue?"):
          continue
        else:
          raise NimbleQuit(msg: "")
      createDir(dest / file.splitFile.dir)
      result.incl copyFileD(src, dest / file)

    for dir in pkgInfo.installDirs:
      # TODO: Allow skipping files inside dirs?
      let src = origDir / dir
      if not src.existsDir():
        if options.prompt("Missing directory " & src & ". Continue?"):
          continue
        else:
          raise NimbleQuit(msg: "")
      result.incl copyDirD(origDir / dir, dest / dir)

    result.incl copyWithExt(origDir, currentDir, dest, pkgInfo)
  else:
    for kind, file in walkDir(currentDir):
      if kind == pcDir:
        let skip = pkgInfo.checkInstallDir(origDir, file)

        if skip: continue
        # Create the dir.
        createDir(changeRoot(origDir, dest, file))

        result.incl copyFilesRec(origDir, file, dest, options, pkgInfo)
      else:
        let skip = pkgInfo.checkInstallFile(origDir, file)

        if skip: continue

        result.incl copyFileD(file, changeRoot(origDir, dest, file))

  result.incl copyFileD(pkgInfo.mypath,
            changeRoot(pkgInfo.mypath.splitFile.dir, dest, pkgInfo.mypath))

proc saveNimbleData(options: Options) =
  # TODO: This file should probably be locked.
  writeFile(options.getNimbleDir() / "nimbledata.json",
          pretty(options.nimbleData))

proc addRevDep(options: Options, dep: tuple[name, version: string],
               pkg: PackageInfo) =
  # let depNameVer = dep.name & '-' & dep.version
  if not options.nimbleData["reverseDeps"].hasKey(dep.name):
    options.nimbleData["reverseDeps"][dep.name] = newJObject()
  if not options.nimbleData["reverseDeps"][dep.name].hasKey(dep.version):
    options.nimbleData["reverseDeps"][dep.name][dep.version] = newJArray()
  let revDep = %{ "name": %pkg.name, "version": %pkg.specialVersion}
  let thisDep = options.nimbleData["reverseDeps"][dep.name][dep.version]
  if revDep notin thisDep:
    thisDep.add revDep

proc removeRevDep(options: Options, pkg: PackageInfo) =
  ## Removes ``pkg`` from the reverse dependencies of every package.
  assert(not pkg.isMinimal)
  proc remove(options: Options, pkg: PackageInfo, depTup: PkgTuple,
              thisDep: JsonNode) =
    for ver, val in thisDep:
      if ver.newVersion in depTup.ver:
        var newVal = newJArray()
        for revDep in val:
          if not (revDep["name"].str == pkg.name and
                  revDep["version"].str == pkg.specialVersion):
            newVal.add revDep
        thisDep[ver] = newVal

  for depTup in pkg.requires:
    if depTup.name.isURL():
      # We sadly must go through everything in this case...
      for key, val in options.nimbleData["reverseDeps"]:
        options.remove(pkg, depTup, val)
    else:
      let thisDep = options.nimbleData{"reverseDeps", depTup.name}
      if thisDep.isNil: continue
      options.remove(pkg, depTup, thisDep)

  # Clean up empty objects/arrays
  var newData = newJObject()
  for key, val in options.nimbleData["reverseDeps"]:
    if val.len != 0:
      var newVal = newJObject()
      for ver, elem in val:
        if elem.len != 0:
          newVal[ver] = elem
      if newVal.len != 0:
        newData[key] = newVal
  options.nimbleData["reverseDeps"] = newData

  saveNimbleData(options)

proc install(packages: seq[PkgTuple],
             options: Options,
             doPrompt = true): tuple[paths: seq[string], pkg: PackageInfo]
proc processDeps(pkginfo: PackageInfo, options: Options): seq[string] =
  ## Verifies and installs dependencies.
  ##
  ## Returns the list of paths to pass to the compiler during build phase.
  result = @[]
  assert(not pkginfo.isMinimal, "processDeps needs pkginfo.requires")
  display("Verifying",
          "dependencies for $1@$2" % [pkginfo.name, pkginfo.specialVersion],
          priority = HighPriority)

  var pkgList = getInstalledPkgsMin(options.getPkgsDir(), options)
  var reverseDeps: seq[tuple[name, version: string]] = @[]
  for dep in pkginfo.requires:
    if dep.name == "nimrod" or dep.name == "nim":
      let nimVer = getNimrodVersion()
      if not withinRange(nimVer, dep.ver):
        let msg = "Unsatisfied dependency: " & dep.name & " (" & $dep.ver & ")"
        raise newException(NimbleError, msg)
    else:
      let resolvedDep = dep.resolveAlias(options)
      display("Checking", "for $1" % $resolvedDep, priority = MediumPriority)
      var pkg: PackageInfo
      var found = findPkg(pkgList, resolvedDep, pkg)
      # Check if the original name exists.
      if not found and resolvedDep.name != dep.name:
        display("Checking", "for $1" % $dep, priority = MediumPriority)
        found = findPkg(pkgList, dep, pkg)
        if found:
          display("Warning:", "Installed package $1 should be renamed to $2" %
                  [dep.name, resolvedDep.name], Warning, HighPriority)

      if not found:
        display("Installing", $resolvedDep, priority = HighPriority)
        let toInstall = @[(resolvedDep.name, resolvedDep.ver)]
        let (paths, installedPkg) = install(toInstall, options)
        result.add(paths)

        pkg = installedPkg # For addRevDep

        # This package has been installed so we add it to our pkgList.
        pkgList.add((pkg, readMetaData(pkg.getRealDir())))
      else:
        display("Info:", "Dependency on $1 already satisfied" % $dep,
                priority = HighPriority)
        result.add(pkg.mypath.splitFile.dir)
        # Process the dependencies of this dependency.
        result.add(processDeps(pkg.toFullInfo(options), options))
      reverseDeps.add((pkg.name, pkg.specialVersion))

  # Check if two packages of the same name (but different version) are listed
  # in the path.
  var pkgsInPath: StringTableRef = newStringTable(modeCaseSensitive)
  for p in result:
    let pkgInfo = getPkgInfo(p, options)
    if pkgsInPath.hasKey(pkgInfo.name) and
       pkgsInPath[pkgInfo.name] != pkgInfo.version:
      raise newException(NimbleError,
        "Cannot satisfy the dependency on $1 $2 and $1 $3" %
          [pkgInfo.name, pkgInfo.version, pkgsInPath[pkgInfo.name]])
    pkgsInPath[pkgInfo.name] = pkgInfo.version

  # We add the reverse deps to the JSON file here because we don't want
  # them added if the above errorenous condition occurs
  # (unsatisfiable dependendencies).
  # N.B. NimbleData is saved in installFromDir.
  for i in reverseDeps:
    addRevDep(options, i, pkginfo)

proc buildFromDir(pkgInfo: PackageInfo, paths: seq[string], args: var string) =
  ## Builds a package as specified by ``pkgInfo``.
  if pkgInfo.bin.len == 0:
    raise newException(NimbleError,
        "Nothing to build. Did you specify a module to build using the" &
        " `bin` key in your .nimble file?")
  let realDir = pkgInfo.getRealDir()
  for path in paths: args.add(" --path:\"" & path & "\" ")
  for bin in pkgInfo.bin:
    let outputOpt = "-o:\"" & pkgInfo.getOutputDir(bin) & "\""
    display("Building", "$1/$2 using $3 backend" %
            [pkginfo.name, bin, pkgInfo.backend], priority = HighPriority)

    let outputDir = pkgInfo.getOutputDir("")
    if not existsDir(outputDir):
      createDir(outputDir)

    try:
      doCmd("\"" & getNimBin() & "\" $# --noBabelPath $# $# \"$#\"" %
            [pkgInfo.backend, args, outputOpt,
             realDir / bin.changeFileExt("nim")])
    except NimbleError:
      let currentExc = (ref NimbleError)(getCurrentException())
      let exc = newException(BuildFailed, "Build failed for package: " &
                             pkgInfo.name)
      let (error, hint) = getOutputInfo(currentExc)
      exc.msg.add("\nDetails:\n" & error)
      exc.hint = hint
      raise exc

proc buildFromDir(pkgInfo: PackageInfo, paths: seq[string], forRelease: bool) =
  var args = if forRelease: "-d:release" else: ""
  buildFromDir(pkgInfo, paths, args)

proc saveNimbleMeta(pkgDestDir, url, vcsRevision: string,
                    filesInstalled, bins: HashSet[string]) =
  ## Saves the specified data into a ``nimblemeta.json`` file inside
  ## ``pkgDestDir``.
  ##
  ## filesInstalled - A list of absolute paths to files which have been
  ##                  installed.
  ## bins - A list of binary filenames which have been installed for this
  ##        package.
  var nimblemeta = %{"url": %url}
  if not vcsRevision.isNil:
    nimblemeta["vcsRevision"] = %vcsRevision
  let files = newJArray()
  nimblemeta["files"] = files
  for file in filesInstalled:
    files.add(%changeRoot(pkgDestDir, "", file))
  let binaries = newJArray()
  nimblemeta["binaries"] = binaries
  for bin in bins:
    binaries.add(%bin)
  writeFile(pkgDestDir / "nimblemeta.json", $nimblemeta)

proc removePkgDir(dir: string, options: Options) =
  ## Removes files belonging to the package in ``dir``.
  try:
    var nimblemeta = parseFile(dir / "nimblemeta.json")
    if not nimblemeta.hasKey("files"):
      raise newException(JsonParsingError,
                         "Meta data does not contain required info.")
    for file in nimblemeta["files"]:
      removeFile(dir / file.str)

    removeFile(dir / "nimblemeta.json")

    # If there are no files left in the directory, remove the directory.
    if toSeq(walkDirRec(dir)).len == 0:
      removeDir(dir)
    else:
      display("Warning:", ("Cannot completely remove $1. Files not installed " &
              "by nimble are present.") % dir, Warning, HighPriority)

    # Remove binaries.
    if nimblemeta.hasKey("binaries"):
      for binary in nimblemeta["binaries"]:
        removeFile(options.getBinDir() / binary.str)
    else:
      display("Warning:", ("Cannot completely remove $1. Binary symlinks may " &
                          "have been left over in $2.") %
                          [dir, options.getBinDir()])
  except OSError, JsonParsingError:
    display("Warning", "Unable to read nimblemeta.json: " &
            getCurrentExceptionMsg(), Warning, HighPriority)
    if not options.prompt("Would you like to COMPLETELY remove ALL files " &
                          "in " & dir & "?"):
      raise NimbleQuit(msg: "")
    removeDir(dir)

proc vcsRevisionInDir(dir: string): string =
  ## Returns current revision number of HEAD if dir is inside VCS, or nil in
  ## case of failure.
  var cmd = ""
  if dirExists(dir / ".git"):
    cmd = "git -C " & quoteShell(dir) & " rev-parse HEAD"
  elif dirExists(dir / ".hg"):
    cmd = "hg --cwd " & quoteShell(dir) & " id -i"

  if cmd.len > 0:
    try:
      let res = doCmdEx(cmd)
      if res.exitCode == 0:
        result = string(res.output).strip()
    except:
      discard

proc installFromDir(dir: string, requestedVer: VersionRange, options: Options,
                    url: string): tuple[paths: seq[string], pkg: PackageInfo] =
  ## Returns where package has been installed to, together with paths
  ## to the packages this package depends on.
  ## The return value of this function is used by
  ## ``processDeps`` to gather a list of paths to pass to the nim compiler.
  var pkgInfo = getPkgInfo(dir, options)
  let realDir = pkgInfo.getRealDir()
  let binDir = options.getBinDir()
  let pkgsDir = options.getPkgsDir()
  var depsOptions = options
  depsOptions.depsOnly = false

  # Overwrite the version if the requested version is "#head" or similar.
  if requestedVer.kind == verSpecial:
    pkgInfo.specialVersion = $requestedVer.spe

  # Dependencies need to be processed before the creation of the pkg dir.
  result.paths = processDeps(pkgInfo, depsOptions)

  if options.depsOnly:
    result.pkg = pkgInfo
    return result

  display("Installing", "$1@$2" % [pkginfo.name, pkginfo.specialVersion],
          priority = HighPriority)

  # Build before removing an existing package (if one exists). This way
  # if the build fails then the old package will still be installed.
  if pkgInfo.bin.len > 0: buildFromDir(pkgInfo, result.paths, true)

  let versionStr = '-' & pkgInfo.specialVersion

  let pkgDestDir = pkgsDir / (pkgInfo.name & versionStr)
  if existsDir(pkgDestDir) and existsFile(pkgDestDir / "nimblemeta.json"):
    if not options.prompt(pkgInfo.name & versionStr &
          " already exists. Overwrite?"):
      raise NimbleQuit(msg: "")
    removePkgDir(pkgDestDir, options)
    # Remove any symlinked binaries
    for bin in pkgInfo.bin:
      # TODO: Check that this binary belongs to the package being installed.
      when defined(windows):
        removeFile(binDir / bin.changeFileExt("cmd"))
        removeFile(binDir / bin.changeFileExt(""))
      else:
        removeFile(binDir / bin)


  createDir(pkgDestDir)
  # Copy this package's files based on the preferences specified in PkgInfo.
  var filesInstalled = initSet[string]()
  for file in getInstallFiles(realDir, pkgInfo, options):
    createDir(changeRoot(realDir, pkgDestDir, file.splitFile.dir))
    let dest = changeRoot(realDir, pkgDestDir, file)
    filesInstalled.incl copyFileD(file, dest)

  # Copy the .nimble file.
  let dest = changeRoot(pkgInfo.myPath.splitFile.dir, pkgDestDir,
                        pkgInfo.myPath)
  filesInstalled.incl copyFileD(pkgInfo.myPath, dest)

  var binariesInstalled = initSet[string]()
  if pkgInfo.bin.len > 0:
    # Make sure ~/.nimble/bin directory is created.
    createDir(binDir)
    # Set file permissions to +x for all binaries built,
    # and symlink them on *nix OS' to $nimbleDir/bin/
    for bin in pkgInfo.bin:
      if existsFile(pkgDestDir / bin):
        display("Warning:", ("Binary '$1' was already installed from source" &
                            " directory. Will be overwritten.") % bin, Warning,
                MediumPriority)

      # Copy the binary file.
      filesInstalled.incl copyFileD(pkgInfo.getOutputDir(bin),
                                    pkgDestDir / bin)

      let currentPerms = getFilePermissions(pkgDestDir / bin)
      setFilePermissions(pkgDestDir / bin, currentPerms + {fpUserExec})
      let cleanBin = bin.extractFilename
      when defined(unix):
        display("Creating", "symlink: $1 -> $2" %
                [pkgDestDir / bin, binDir / cleanBin], priority = MediumPriority)
        if existsFile(binDir / cleanBin):
          display("Warning:", "Symlink already exists in $1. Replacing." % binDir,
                  Warning, HighPriority)
          removeFile(binDir / cleanBin)
        createSymlink(pkgDestDir / bin, binDir / cleanBin)
        binariesInstalled.incl(cleanBin)
      elif defined(windows):
        # There is a bug on XP, described here:
        # http://stackoverflow.com/questions/2182568/batch-script-is-not-executed-if-chcp-was-called
        # But this workaround brakes code page on newer systems, so we need to detect OS version
        var osver = OSVERSIONINFO()
        osver.dwOSVersionInfoSize = cast[DWORD](sizeof(OSVERSIONINFO))
        if GetVersionExA(osver) == WINBOOL(0):
          raise newException(NimbleError,
            "Can't detect OS version: GetVersionExA call failed")
        let fixChcp = osver.dwMajorVersion <= 5

        # Create cmd.exe/powershell stub.
        let dest = binDir / cleanBin.changeFileExt("cmd")
        display("Creating", "stub: $1 -> $2" % [pkgDestDir / bin, dest],
                priority = MediumPriority)
        var contents = "@"
        if options.config.chcp:
          if fixChcp:
            contents.add "chcp 65001 > nul && "
          else: contents.add "chcp 65001 > nul\n@"
        contents.add "\"" & pkgDestDir / bin & "\" %*\n"
        writeFile(dest, contents)
        binariesInstalled.incl(dest.extractFilename)
        # For bash on Windows (Cygwin/Git bash).
        let bashDest = dest.changeFileExt("")
        display("Creating", "Cygwin stub: $1 -> $2" %
                [pkgDestDir / bin, bashDest], priority = MediumPriority)
        writeFile(bashDest, "\"" & pkgDestDir / bin & "\" \"$@\"\n")
        binariesInstalled.incl(bashDest.extractFilename)
      else:
        {.error: "Sorry, your platform is not supported.".}

  let vcsRevision = vcsRevisionInDir(realDir)

  # Save a nimblemeta.json file.
  saveNimbleMeta(pkgDestDir, url, vcsRevision, filesInstalled,
                 binariesInstalled)

  # Save the nimble data (which might now contain reverse deps added in
  # processDeps).
  saveNimbleData(options)

  # Return the paths to the dependencies of this package.
  result.paths.add pkgDestDir
  result.pkg = pkgInfo
  result.pkg.isInstalled = true
  result.pkg.myPath = dest

  display("Success:", pkgInfo.name & " installed successfully.",
          Success, HighPriority)

proc getNimbleTempDir(): string =
  ## Returns a path to a temporary directory.
  ##
  ## The returned path will be the same for the duration of the process but
  ## different for different runs of it. You have to make sure to create it
  ## first. In release builds the directory will be removed when nimble finishes
  ## its work.
  result = getTempDir() / "nimble_"
  when defined(windows):
    proc GetCurrentProcessId(): int32 {.stdcall, dynlib: "kernel32",
                                        importc: "GetCurrentProcessId".}
    result.add($GetCurrentProcessId())
  else:
    result.add($getpid())

proc downloadPkg(url: string, verRange: VersionRange,
                 downMethod: DownloadMethod,
                 options: Options): (string, Version) =
  ## Downloads the repository as specified by ``url`` and ``verRange`` using
  ## the download method specified.
  ##
  ## Returns the directory where it was downloaded and the concrete version
  ## which was downloaded.
  let downloadDir = (getNimbleTempDir() / getDownloadDirName(url, verRange))
  createDir(downloadDir)
  var modUrl =
    if url.startsWith("git://") and options.config.cloneUsingHttps:
      "https://" & url[6 .. ^1]
    else: url

  # Fixes issue #204
  # github + https + trailing url slash causes a
  # checkout/ls-remote to fail with Repository not found
  if modUrl.contains("github.com") and modUrl.endswith("/"):
    modUrl = modUrl[0 .. ^2]

  display("Downloading", "$1 using $2" % [modUrl, $downMethod],
          priority = HighPriority)
  result = (
    downloadDir,
    doDownload(modUrl, downloadDir, verRange, downMethod, options)
  )

proc getDownloadInfo*(pv: PkgTuple, options: Options,
                      doPrompt: bool): (DownloadMethod, string) =
  if pv.name.isURL:
    return (checkUrlType(pv.name), pv.name)
  else:
    var pkg: Package
    if getPackage(pv.name, options, pkg):
      return (pkg.downloadMethod.getDownloadMethod(), pkg.url)
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
        raise newException(NimbleError, "Package not found.")

proc install(packages: seq[PkgTuple],
             options: Options,
             doPrompt = true): tuple[paths: seq[string], pkg: PackageInfo] =
  if packages == @[]:
    result = installFromDir(getCurrentDir(), newVRAny(), options, "")
  else:
    # Install each package.
    for pv in packages:
      let (meth, url) = getDownloadInfo(pv, options, doPrompt)
      let (downloadDir, downloadVersion) =
          downloadPkg(url, pv.ver, meth, options)
      try:
        result = installFromDir(downloadDir, pv.ver, options, url)
      except BuildFailed:
        # The package failed to build.
        # Check if we tried building a tagged version of the package.
        let headVer = getHeadName(meth)
        if pv.ver.kind != verSpecial and downloadVersion != headVer:
          # If we tried building a tagged version of the package then
          # ask the user whether they want to try building #head.
          let promptResult = doPrompt and
              options.prompt(("Build failed for '$1@$2', would you" &
                  " like to try installing '$1@#head' (latest unstable)?") %
                  [pv.name, $downloadVersion])
          if promptResult:
            let toInstall = @[(pv.name, headVer.toVersionRange())]
            result = install(toInstall, options, doPrompt)
          else:
            raise newException(BuildFailed,
              "Aborting installation due to build failure")
        else:
          raise

proc build(options: Options) =
  var pkgInfo = getPkgInfo(getCurrentDir(), options)
  nimScriptHint(pkgInfo)
  let paths = processDeps(pkginfo, options)
  var args = join(options.action.compileOptions, " ")
  buildFromDir(pkgInfo, paths, args)

proc execBackend(options: Options) =
  let bin = options.action.file
  if bin == "":
    raise newException(NimbleError, "You need to specify a file.")

  if not fileExists(bin):
    raise newException(NimbleError, "Specified file does not exist.")

  var pkgInfo = getPkgInfo(getCurrentDir(), options)
  nimScriptHint(pkgInfo)
  let paths = processDeps(pkginfo, options)

  var args = ""
  for path in paths: args.add("--path:\"" & path & "\" ")
  for option in options.action.compileOptions:
    args.add(option & " ")

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
  doCmd("\"" & getNimBin() & "\" $# --noNimblePath $# \"$#\"" %
        [backend, args, bin], showOutput = true)
  display("Success:", "Execution finished", Success, HighPriority)

proc search(options: Options) =
  ## Searches for matches in ``options.action.search``.
  ##
  ## Searches are done in a case insensitive way making all strings lower case.
  assert options.action.typ == actionSearch
  if options.action.search == @[]:
    raise newException(NimbleError, "Please specify a search string.")
  if needsRefresh(options):
    raise newException(NimbleError, "Please run nimble refresh.")
  let pkgList = getPackageList(options)
  var found = false
  template onFound {.dirty.} =
    echoPackage(pkg)
    if options.queryVersions:
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
    raise newException(NimbleError, "Please run nimble refresh.")
  let pkgList = getPackageList(options)
  for pkg in pkgList:
    echoPackage(pkg)
    if options.queryVersions:
      echoPackageVersions(pkg)
    echo(" ")

proc listInstalled(options: Options) =
  var h = initOrderedTable[string, seq[string]]()
  let pkgs = getInstalledPkgs(options.getPkgsDir(), options)
  for x in pkgs.items():
    let
      pName = x.pkginfo.name
      pVer = x.pkginfo.specialVersion
    if not h.hasKey(pName): h[pName] = @[]
    var s = h[pName]
    add(s, pVer)
    h[pName] = s

  h.sort(proc (a, b: (string, seq[string])): int = cmpIgnoreCase(a[0], b[0]))
  for k in keys(h):
    echo k & "  [" & h[k].join(", ") & "]"

type VersionAndPath = tuple[version: Version, path: string]

proc listPaths(options: Options) =
  ## Loops over the specified packages displaying their installed paths.
  ##
  ## If there are several packages installed, only the last one (the version
  ## listed in the packages.json) will be displayed. If any package name is not
  ## found, the proc displays a missing message and continues through the list,
  ## but at the end quits with a non zero exit error.
  ##
  ## On success the proc returns normally.
  assert options.action.typ == actionPath
  assert(not options.action.packages.isNil)

  if options.action.packages.len == 0:
    raise newException(NimbleError, "A package name needs to be specified")

  var errors = 0
  for name, version in options.action.packages.items:
    var installed: seq[VersionAndPath] = @[]
    # There may be several, list all available ones and sort by version.
    for kind, path in walkDir(options.getPkgsDir):
      if kind != pcDir or not path.startsWith(options.getPkgsDir / name):
        continue

      let
        nimbleFile = path / name.addFileExt("nimble")
        hasSpec = nimbleFile.existsFile

      if hasSpec:
        var pkgInfo = getPkgInfo(path, options)
        var v: VersionAndPath
        v.version = newVersion(pkgInfo.specialVersion)
        v.path = options.getPkgsDir / (pkgInfo.name & '-' & pkgInfo.specialVersion)
        installed.add(v)
      else:
        display("Warning:", "No .nimble file found for " & path, Warning,
                MediumPriority)

    if installed.len > 0:
      sort(installed, cmp[VersionAndPath], Descending)
      # The output for this command is used by tools so we do not use display().
      echo installed[0].path
    else:
      display("Warning:", "Package '$1' is not installed" % name, Warning,
              MediumPriority)
      errors += 1
  if errors > 0:
    raise newException(NimbleError,
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
  elif pattern.splitFile.ext == ".nimble" and pattern.existsFile:
    # project file specified
    result = getPkgInfoFromFile(pattern, options)
  elif pattern.existsDir:
    # project directory specified
    result = getPkgInfo(pattern, options)
  else:
    # Last resort - attempt to read as package identifier
    let packages = getInstalledPkgsMin(options.getPkgsDir(), options)
    let identTuple = parseRequires(pattern)
    var skeletonInfo: PackageInfo
    if not findPkg(packages, identTuple, skeletonInfo):
      raise newException(NimbleError,
          "Specified package not found"
      )
    result = getPkgInfoFromFile(skeletonInfo.myPath, options)

proc dump(options: Options) =
  let p = getPackageByPattern(options.action.projName, options)
  echo "name: ", p.name.escape
  echo "version: ", p.version.escape
  echo "author: ", p.author.escape
  echo "desc: ", p.description.escape
  echo "license: ", p.license.escape
  echo "skipDirs: ", p.skipDirs.join(", ").escape
  echo "skipFiles: ", p.skipFiles.join(", ").escape
  echo "skipExt: ", p.skipExt.join(", ").escape
  echo "installDirs: ", p.installDirs.join(", ").escape
  echo "installFiles: ", p.installFiles.join(", ").escape
  echo "installExt: ", p.installExt.join(", ").escape
  echo "requires: ", p.requires.join(", ").escape
  echo "bin: ", p.bin.join(", ").escape
  echo "binDir: ", p.binDir.escape
  echo "srcDir: ", p.srcDir.escape
  echo "backend: ", p.backend.escape

proc init(options: Options) =
  var nimbleFile: string = ""

  display("Info:",
       "In order to initialise a new Nimble package, I will need to ask you\n" &
       "some questions. Default values are shown in square brackets, press\n" &
       "enter to use them.", priority = HighPriority)

  # Ask for package name.
  if options.action.projName != "":
    let pkgName = options.action.projName
    nimbleFile = pkgName.changeFileExt("nimble")
  else:
    var pkgName = os.getCurrentDir().splitPath.tail.toValidPackageName()
    pkgName = promptCustom("Package name?", pkgName)
    nimbleFile = pkgName.changeFileExt("nimble")

  validatePackageName(nimbleFile.changeFileExt(""))

  if existsFile(os.getCurrentDir() / nimbleFile):
    raise newException(NimbleError, "Nimble file already exists.")

  # Ask for package version.
  let pkgVersion = promptCustom("Initial version of package?", "0.1.0")
  validateVersion(pkgVersion)

  # Ask for package author
  var defaultAuthor = "Anonymous"
  if findExe("git") != "":
    let (name, exitCode) = doCmdEx("git config --global user.name")
    if exitCode == QuitSuccess and name.len > 0:
      defaultAuthor = name.strip()
  elif defaultAuthor == "Anonymous" and findExe("hg") != "":
    let (name, exitCode) = doCmdEx("hg config ui.username")
    if exitCode == QuitSuccess and name.len > 0:
      defaultAuthor = name.strip()
  let pkgAuthor = promptCustom("Your name?", defaultAuthor)

  # Ask for description
  let pkgDesc = promptCustom("Package description?", "")

  # Ask for license
  # TODO: Provide selection of licenses, or select random default license.
  let pkgLicense = promptCustom("Package license?", "MIT")

  # Ask for Nim dependency
  let nimDepDef = getNimrodVersion()
  let pkgNimDep = promptCustom("Lowest supported Nim version?", $nimDepDef)
  validateVersion(pkgNimDep)

  var outFile: File
  if open(f = outFile, filename = nimbleFile, mode = fmWrite):
    outFile.writeLine """# Package

version       = $#
author        = $#
description   = $#
license       = $#

# Dependencies

requires "nim >= $#"
""" % [pkgVersion.escape(), pkgAuthor.escape(), pkgDesc.escape(),
       pkgLicense.escape(), pkgNimDep]
    close(outFile)
  else:
    raise newException(NimbleError, "Unable to open file " & nimbleFile &
                       " for writing: " & osErrorMsg(osLastError()))

  display("Success:", "Nimble file created successfully", Success, HighPriority)

proc uninstall(options: Options) =
  if options.action.packages.len == 0:
    raise newException(NimbleError,
        "Please specify the package(s) to uninstall.")

  var pkgsToDelete: seq[PackageInfo] = @[]
  # Do some verification.
  for pkgTup in options.action.packages:
    display("Looking", "for $1 ($2)" % [pkgTup.name, $pkgTup.ver],
            priority = HighPriority)
    let installedPkgs = getInstalledPkgs(options.getPkgsDir(), options)
    var pkgList = findAllPkgs(installedPkgs, pkgTup)
    if pkgList.len == 0:
      raise newException(NimbleError, "Package not found")

    display("Checking", "reverse dependencies", priority = HighPriority)
    var errors: seq[string] = @[]
    for pkg in pkgList:
      # Check whether any packages depend on the ones the user is trying to
      # uninstall.
      let thisPkgsDep = options.nimbleData["reverseDeps"]{pkg.name}{pkg.specialVersion}
      if not thisPkgsDep.isNil:
        var reason = ""
        if thisPkgsDep.len == 1:
          reason = "$1 ($2) depends on it" % [thisPkgsDep[0]["name"].str,
                   thisPkgsDep[0]["version"].str]
        else:
          for i in 0 .. <thisPkgsDep.len:
            reason.add("$1 ($2)" % [thisPkgsDep[i]["name"].str,
                       thisPkgsDep[i]["version"].str])
            if i != <thisPkgsDep.len:
              reason.add ", "
          reason.add " depend on it"
        errors.add("Cannot uninstall $1 ($2) because $3" % [pkgTup.name,
                   pkg.specialVersion, reason])
      else:
        pkgsToDelete.add pkg

    if pkgsToDelete.len == 0:
      raise newException(NimbleError, "\n  " & errors.join("\n  "))

  var pkgNames = ""
  for i in 0 .. <pkgsToDelete.len:
    if i != 0: pkgNames.add ", "
    let pkg = pkgsToDelete[i]
    pkgNames.add("$1 ($2)" % [pkg.name, pkg.specialVersion])

  # Let's confirm that the user wants these packages removed.
  let msg = ("The following packages will be removed:\n  $1\n" &
            "Do you wish to continue?") % pkgNames
  if not options.prompt(msg):
    raise NimbleQuit(msg: "")

  for pkg in pkgsToDelete:
    # If we reach this point then the package can be safely removed.

    # removeRevDep needs the package dependency info, so we can't just pass
    # a minimal pkg info.
    removeRevDep(options, pkg.toFullInfo(options))
    removePkgDir(options.getPkgsDir / (pkg.name & '-' & pkg.specialVersion),
                 options)
    display("Removed", "$1 ($2)" % [pkg.name, $pkg.specialVersion], Success,
            HighPriority)

proc listTasks(options: Options) =
  let nimbleFile = findNimbleFile(getCurrentDir(), true)
  nimscriptsupport.listTasks(nimbleFile, options)

proc execHook(options: Options, before: bool): bool =
  ## Returns whether to continue.
  result = true
  var nimbleFile = ""
  try:
    nimbleFile = findNimbleFile(getCurrentDir(), true)
  except NimbleError: return true
  # PackageInfos are cached so we can read them as many times as we want.
  let pkgInfo = getPkgInfoFromFile(nimbleFile, options)
  let actionName =
    if options.action.typ == actionCustom: options.action.command
    else: ($options.action.typ)[6 .. ^1]
  let hookExists =
    if before: actionName.normalize in pkgInfo.preHooks
    else: actionName.normalize in pkgInfo.postHooks
  if pkgInfo.isNimScript and hookExists:
    let res = execHook(nimbleFile, actionName, before, options)
    if res.success:
      result = res.retVal

proc doAction(options: Options) =
  if options.showHelp:
    writeHelp()
  if options.showVersion:
    writeVersion()

  if not existsDir(options.getNimbleDir()):
    createDir(options.getNimbleDir())
  if not existsDir(options.getPkgsDir):
    createDir(options.getPkgsDir)

  if not execHook(options, true):
    display("Warning", "Pre-hook prevented further execution.", Warning,
            HighPriority)
    return
  case options.action.typ
  of actionRefresh:
    refresh(options)
  of actionInstall:
    let (_, pkgInfo) = install(options.action.packages, options)
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
  of actionCompile, actionDoc:
    execBackend(options)
  of actionInit:
    init(options)
  of actionPublish:
    var pkgInfo = getPkgInfo(getCurrentDir(), options)
    publish(pkgInfo, options)
  of actionDump:
    dump(options)
  of actionTasks:
    listTasks(options)
  of actionNil:
    assert false
  of actionCustom:
    # Custom command. Attempt to call a NimScript task.
    let nimbleFile = findNimbleFile(getCurrentDir(), true)
    if not nimbleFile.isNimScript(options):
      writeHelp()

    let execResult = execTask(nimbleFile, options.action.command, options)
    if not execResult.success:
      raiseNimbleError(msg = "Could not find task $1 in $2" %
                             [options.action.command, nimbleFile],
                       hint = "Run `nimble --help` and/or `nimble tasks` for" &
                              " a list of possible commands.")

    if execResult.command.normalize == "nop":
      display("Warning:", "Using `setCommand 'nop'` is not necessary.", Warning,
              HighPriority)
      return

    if not execHook(options, false):
      return

    if execResult.hasTaskRequestedCommand():
      var newOptions = initOptions()
      newOptions.config = options.config
      newOptions.nimbleData = options.nimbleData
      parseCommand(execResult.command, newOptions)
      for arg in execResult.arguments:
        parseArgument(arg, newOptions)
      for flag, vals in execResult.flags:
        for val in vals:
          parseFlag(flag, val, newOptions)
      doAction(newOptions)

  if options.action.typ != actionCustom:
    discard execHook(options, false)

when isMainModule:
  var error = ""
  var hint = ""

  try:
    parseCmdLine().doAction()
  except NimbleError:
    let currentExc = (ref NimbleError)(getCurrentException())
    (error, hint) = getOutputInfo(currentExc)
  except NimbleQuit:
    discard
  finally:
    removeDir(getNimbleTempDir())

  if error.len > 0:
    displayTip()
    display("Error:", error, Error, HighPriority)
    if hint.len > 0:
      display("Hint:", hint, Warning, HighPriority)
    quit(1)
