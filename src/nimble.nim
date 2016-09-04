# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import httpclient, parseopt, os, strutils, osproc, pegs, tables, parseutils,
       strtabs, json, algorithm, sets, uri

from sequtils import toSeq

import nimblepkg/packageinfo, nimblepkg/version, nimblepkg/tools,
       nimblepkg/download, nimblepkg/config, nimblepkg/nimbletypes,
       nimblepkg/publish, nimblepkg/options, nimblepkg/packageparser

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

const
  nimbleVersion = "0.7.4"

proc writeVersion() =
  echo("nimble v$# compiled at $# $#" %
      [nimbleVersion, CompileDate, CompileTime])
  quit(QuitSuccess)

proc promptCustom(question, default: string): string =
  if default == "":
    stdout.write(question, ": ")
    let user = stdin.readLine()
    if user.len == 0: return promptCustom(question, default)
    else: return user
  else:
    stdout.write(question, " [", default, "]: ")
    let user = stdin.readLine()
    if user == "": return default
    else: return user

proc update(options: Options) =
  ## Downloads the package list from the specified URL.
  ##
  ## If the download is not successful, an exception is raised.
  let parameter =
    if options.action.typ == actionRefresh:
      options.action.optionalURL
    else:
      ""

  proc downloadList(list: PackageList, options: Options) =
    echo("Downloading \"", list.name, "\" package list")
    for i in 0 .. <list.urls.len:
      let url = list.urls[i]
      echo("Trying ", url, "...")
      let tempPath = options.getNimbleDir() / "packages_temp.json"

      # Grab the proxy
      let proxy = getProxy(options)
      if not proxy.isNil:
        var maskedUrl = proxy.url
        if maskedUrl.password.len > 0: maskedUrl.password = "***"
        echo("Using proxy ", maskedUrl)

      try:
        downloadFile(url, tempPath, proxy = getProxy(options))
      except:
        if i == <list.urls.len:
          raise
        echo("Could not download: ", getCurrentExceptionMsg())
        continue
      if not validatePackagesList(tempPath):
        echo("Downloaded packages.json file is invalid, discarding.")
        continue
      copyFile(tempPath,
          options.getNimbleDir() / "packages_$1.json" % list.name.toLower())
      echo("Done.")
      break

  if parameter.isUrl:
    downloadList(PackageList(name: "commandline", urls: @[parameter]), options)
  else:
    # Try each package list in config
    for name, list in options.config.packageLists:
      downloadList(list, options)

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
          quit(QuitSuccess)
      createDir(dest / file.splitFile.dir)
      result.incl copyFileD(src, dest / file)

    for dir in pkgInfo.installDirs:
      # TODO: Allow skipping files inside dirs?
      let src = origDir / dir
      if not src.existsDir():
        if options.prompt("Missing directory " & src & ". Continue?"):
          continue
        else:
          quit(QuitSuccess)
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
  let revDep = %{ "name": %pkg.name, "version": %pkg.version}
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
                  revDep["version"].str == pkg.version):
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
  let pkglist = getInstalledPkgs(options.getPkgsDir(), options)
  var reverseDeps: seq[tuple[name, version: string]] = @[]
  for dep in pkginfo.requires:
    if dep.name == "nimrod" or dep.name == "nim":
      let nimVer = getNimrodVersion()
      if not withinRange(nimVer, dep.ver):
        quit("Unsatisfied dependency: " & dep.name & " (" & $dep.ver & ")")
    else:
      echo("Looking for ", dep.name, " (", $dep.ver, ")...")
      var pkg: PackageInfo
      if not findPkg(pkglist, dep, pkg):
        echo("None found, installing...")
        let (paths, installedPkg) = install(@[(dep.name, dep.ver)], options)
        result.add(paths)

        pkg = installedPkg # For addRevDep
      else:
        echo("Dependency already satisfied.")
        result.add(pkg.mypath.splitFile.dir)
        # Process the dependencies of this dependency.
        result.add(processDeps(pkg, options))
      reverseDeps.add((pkg.name, pkg.version))

  # Check if two packages of the same name (but different version) are listed
  # in the path.
  var pkgsInPath: StringTableRef = newStringTable(modeCaseSensitive)
  for p in result:
    let (name, version) = getNameVersion(p)
    if pkgsInPath.hasKey(name) and pkgsInPath[name] != version:
      raise newException(NimbleError,
        "Cannot satisfy the dependency on $1 $2 and $1 $3" %
          [name, version, pkgsInPath[name]])
    pkgsInPath[name] = version

  # We add the reverse deps to the JSON file here because we don't want
  # them added if the above errorenous condition occurs
  # (unsatisfiable dependendencies).
  # N.B. NimbleData is saved in installFromDir.
  for i in reverseDeps:
    addRevDep(options, i, pkginfo)

proc buildFromDir(pkgInfo: PackageInfo, paths: seq[string], forRelease: bool) =
  ## Builds a package as specified by ``pkgInfo``.
  if pkgInfo.bin.len == 0:
    raise newException(NimbleError,
        "Nothing to build. Did you specify a module to build using the" &
        " `bin` key in your .nimble file?")
  let realDir = pkgInfo.getRealDir()
  let releaseOpt = if forRelease: "-d:release" else: ""
  var args = ""
  for path in paths: args.add("--path:\"" & path & "\" ")
  for bin in pkgInfo.bin:
    let outputOpt = "-o:\"" & pkgInfo.getOutputDir(bin) & "\""
    echo("Building ", pkginfo.name, "/", bin, " using ", pkgInfo.backend,
         " backend...")
    try:
      doCmd(getNimBin() & " $# $# --noBabelPath $# $# \"$#\"" %
            [pkgInfo.backend, releaseOpt, args, outputOpt,
             realDir / bin.changeFileExt("nim")])
    except NimbleError:
      raise newException(BuildFailed, "Build failed for package: " &
                         pkgInfo.name)

proc saveNimbleMeta(pkgDestDir, url: string, filesInstalled: HashSet[string]) =
  var nimblemeta = %{"url": %url}
  nimblemeta["files"] = newJArray()
  for file in filesInstalled:
    nimblemeta["files"].add(%changeRoot(pkgDestDir, "", file))
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
      echo("WARNING: Cannot completely remove " & dir &
           ". Files not installed by nimble are present.")
  except OSError, JsonParsingError:
    echo("Error: Unable to read nimblemeta.json: ", getCurrentExceptionMsg())
    if not options.prompt("Would you like to COMPLETELY remove ALL files " &
                          "in " & dir & "?"):
      quit(QuitSuccess)
    removeDir(dir)

proc installFromDir(dir: string, latest: bool, options: Options,
                    url: string): tuple[paths: seq[string], pkg: PackageInfo] =
  ## Returns where package has been installed to, together with paths
  ## to the packages this package depends on.
  ## The return value of this function is used by
  ## ``processDeps`` to gather a list of paths to pass to the nim compiler.
  var pkgInfo = getPkgInfo(dir, options)
  let realDir = pkgInfo.getRealDir()
  let binDir = options.getBinDir()
  let pkgsDir = options.getPkgsDir()
  var deps_options = options
  deps_options.depsOnly = false

  # Dependencies need to be processed before the creation of the pkg dir.
  result.paths = processDeps(pkginfo, deps_options)

  if options.depsOnly:
    result.pkg = pkgInfo
    return result

  echo("Installing ", pkginfo.name, "-", pkginfo.version)

  # Build before removing an existing package (if one exists). This way
  # if the build fails then the old package will still be installed.
  if pkgInfo.bin.len > 0: buildFromDir(pkgInfo, result.paths, true)

  let versionStr = (if latest: "" else: '-' & pkgInfo.version)
  let pkgDestDir = pkgsDir / (pkgInfo.name & versionStr)
  if existsDir(pkgDestDir) and existsFile(pkgDestDir / "nimblemeta.json"):
    if not options.prompt(pkgInfo.name & versionStr &
          " already exists. Overwrite?"):
      quit(QuitSuccess)
    removePkgDir(pkgDestDir, options)
    # Remove any symlinked binaries
    for bin in pkgInfo.bin:
      # TODO: Check that this binary belongs to the package being installed.
      when defined(windows):
        removeFile(binDir / bin.changeFileExt("cmd"))
        removeFile(binDir / bin.changeFileExt(""))
        # TODO: Remove this later.
        # Remove .bat file too from previous installs.
        removeFile(binDir / bin.changeFileExt("bat"))
      else:
        removeFile(binDir / bin)

  ## Will contain a list of files which have been installed.
  var filesInstalled: HashSet[string]

  createDir(pkgDestDir)
  if pkgInfo.bin.len > 0:
    createDir(binDir)
    # Copy all binaries and files that are not skipped
    filesInstalled = copyFilesRec(realDir, realDir, pkgDestDir, options,
                                  pkgInfo)
    # Set file permissions to +x for all binaries built,
    # and symlink them on *nix OS' to $nimbleDir/bin/
    for bin in pkgInfo.bin:
      if not existsFile(pkgDestDir / bin):
        filesInstalled.incl copyFileD(pkgInfo.getOutputDir(bin),
            pkgDestDir / bin)

      let currentPerms = getFilePermissions(pkgDestDir / bin)
      setFilePermissions(pkgDestDir / bin, currentPerms + {fpUserExec})
      let cleanBin = bin.extractFilename
      when defined(unix):
        # TODO: Verify that we are removing an old bin of this package, not
        # some other package's binary!
        if existsFile(binDir / cleanBin): removeFile(binDir / cleanBin)
        echo("Creating symlink: ", pkgDestDir / bin, " -> ", binDir / cleanBin)
        createSymlink(pkgDestDir / bin, binDir / cleanBin)
      elif defined(windows):
        # There is a bug on XP, described here:
        # http://stackoverflow.com/questions/2182568/batch-script-is-not-executed-if-chcp-was-called
        # But this workaround brokes code page on newer systems, so we need to detect OS version
        var osver = OSVERSIONINFO()
        osver.dwOSVersionInfoSize = cast[DWORD](sizeof(OSVERSIONINFO))
        if GetVersionExA(osver) == WINBOOL(0):
          raise newException(NimbleError,
            "Can't detect OS version: GetVersionExA call failed")
        let fixChcp = osver.dwMajorVersion <= 5

        let dest = binDir / cleanBin.changeFileExt("cmd")
        echo("Creating stub: ", pkgDestDir / bin, " -> ", dest)
        var contents = "@"
        if options.config.chcp:
          if fixChcp:
            contents.add "chcp 65001 > nul && "
          else: contents.add "chcp 65001 > nul\n@"
        contents.add "\"" & pkgDestDir / bin & "\" %*\n"
        writeFile(dest, contents)
        # For bash on Windows (Cygwin/Git bash).
        let bashDest = dest.changeFileExt("")
        echo("Creating Cygwin stub: ", pkgDestDir / bin, " -> ", bashDest)
        writeFile(bashDest, "\"$(cygpath '" & pkgDestDir / bin & "')\" \"$@\"\l")
      else:
        {.error: "Sorry, your platform is not supported.".}
  else:
    filesInstalled = copyFilesRec(realDir, realDir, pkgDestDir, options,
                                  pkgInfo)

  # Save a nimblemeta.json file.
  saveNimbleMeta(pkgDestDir, url, filesInstalled)

  # Save the nimble data (which might now contain reverse deps added in
  # processDeps).
  saveNimbleData(options)

  # Return the paths to the dependencies of this package.
  result.paths.add pkgDestDir
  result.pkg = pkgInfo

  echo(pkgInfo.name & " installed successfully.")

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
                 options: Options): (string, VersionRange) =
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

  echo("Downloading ", modUrl, " into ", downloadDir, " using ",
      downMethod, "...")
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
      # If package is not found give the user a chance to update
      # package.json
      if doPrompt and
          options.prompt(pv.name & " not found in any local packages.json, " &
                         "check internet for updated packages?"):
        update(options)

        # Once we've updated, try again, but don't prompt if not found
        # (as we've already updated and a failure means it really
        # isn't there)
        return getDownloadInfo(pv, options, false)
      else:
        raise newException(NimbleError, "Package not found.")

proc install(packages: seq[PkgTuple],
             options: Options,
             doPrompt = true): tuple[paths: seq[string], pkg: PackageInfo] =
  if packages == @[]:
    result = installFromDir(getCurrentDir(), false, options, "")
  else:
    # If packages.json is not present ask the user if they want to download it.
    if needsRefresh(options):
      if doPrompt and
          options.prompt("No local packages.json found, download it from " &
              "internet?"):
        update(options)
      else:
        quit("Please run nimble refresh.", QuitFailure)

    # Install each package.
    for pv in packages:
      let (meth, url) = getDownloadInfo(pv, options, doPrompt)
      let (downloadDir, downloadVersion) =
          downloadPkg(url, pv.ver, meth, options)
      try:
        result = installFromDir(downloadDir, false, options, url)
      except BuildFailed:
        # The package failed to build.
        # Check if we tried building a tagged version of the package.
        let headVer = parseVersionRange("#" & getHeadName(meth))
        if pv.ver.kind != verSpecial and downloadVersion != headVer:
          # If we tried building a tagged version of the package then
          # ask the user whether they want to try building #head.
          let promptResult = doPrompt and
              options.prompt(("Build failed for '$1@$2', would you" &
                  " like to try installing '$1@#head' (latest unstable)?") %
                  [pv.name, $downloadVersion])
          if promptResult:

            result = install(@[(pv.name, headVer)], options, doPrompt)
          else:
            raise newException(BuildFailed,
              "Aborting installation due to build failure")
        else:
          raise

proc build(options: Options) =
  var pkgInfo = getPkgInfo(getCurrentDir(), options)
  nimScriptHint(pkgInfo)
  let paths = processDeps(pkginfo, options)
  buildFromDir(pkgInfo, paths, false)

proc compile(options: Options) =
  var pkgInfo = getPkgInfo(getCurrentDir(), options)
  nimScriptHint(pkgInfo)
  let paths = processDeps(pkginfo, options)
  let realDir = pkgInfo.getRealDir()

  var args = ""
  for path in paths: args.add("--path:\"" & path & "\" ")
  for option in options.action.compileOptions:
    args.add(option & " ")

  let bin = options.action.file
  let backend =
    if options.action.backend.len > 0:
      options.action.backend
    else:
      pkgInfo.backend

  if bin == "":
    raise newException(NimbleError, "You need to specify a file to compile.")

  echo("Compiling ", bin, " (", pkgInfo.name, ") using ", backend,
       " backend...")
  doCmd(getNimBin() & " $# --noBabelPath $# \"$#\"" %
        [backend, args, bin])

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
  template onFound: stmt =
    echoPackage(pkg)
    if options.queryVersions:
      echoPackageVersions(pkg)
    echo(" ")
    found = true
    break

  for pkg in pkgList:
    for word in options.action.search:
      # Search by name.
      if word.toLower() in pkg.name.toLower():
        onFound()
      # Search by tag.
      for tag in pkg.tags:
        if word.toLower() in tag.toLower():
          onFound()

  if not found:
    echo("No package found.")

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
      pVer = x.pkginfo.version
    if not h.hasKey(pName): h[pName] = @[]
    var s = h[pName]
    add(s, pVer)
    h[pName] = s

  h.sort(proc (a, b: (string, seq[string])): int = cmpIgnoreCase(a[0], b[0]))
  for k in keys(h):
    echo k & "  [" & h[k].join(", ") & "]"

type VersionAndPath = tuple[version: Version, path: string]

proc listPaths(options: Options) =
  ## Loops over installing packages displaying their installed paths.
  ##
  ## If there are several packages installed, only the last one (the version
  ## listed in the packages.json) will be displayed. If any package name is not
  ## found, the proc displays a missing message and continues through the list,
  ## but at the end quits with a non zero exit error.
  ##
  ## On success the proc returns normally.
  assert options.action.typ == actionPath
  assert(not options.action.packages.isNil)
  var errors = 0
  for name, version in options.action.packages.items:
    var installed: seq[VersionAndPath] = @[]
    # There may be several, list all available ones and sort by version.
    for kind, path in walkDir(options.getPkgsDir):
      if kind != pcDir or not path.startsWith(options.getPkgsDir / name):
        continue

      let
        nimScriptFile = path / name.addFileExt("nims")
        babelFile = path / name.addFileExt("babel")
        nimbleFile = path / name.addFileExt("nimble")
        hasSpec = nimScriptFile.existsFile or
                  nimbleFile.existsFile or babelFile.existsFile
      if hasSpec:
        var pkgInfo = getPkgInfo(path, options)
        var v: VersionAndPath
        v.version = newVersion(pkgInfo.version)
        v.path = options.getPkgsDir / (pkgInfo.name & '-' & pkgInfo.version)
        installed.add(v)
      else:
        echo "Warning: No .nimble file found for ", path

    if installed.len > 0:
      sort(installed, system.cmp[VersionAndPath], Descending)
      echo installed[0].path
    else:
      echo "Warning: Package '" & name & "' not installed"
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

proc dump(options: Options) =
  let proj = addFileExt(options.action.projName, "nimble")
  let p = if fileExists(proj): readPackageInfo(proj, options)
          else: getPkgInfo(os.getCurrentDir(), options)
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

  echo("In order to initialise a new Nimble package, I will need to ask you\n" &
       "some questions. Default values are shown in square brackets, press\n" &
       "enter to use them.")

  # Ask for package name.
  if options.action.projName != "":
    let pkgName = options.action.projName
    nimbleFile = pkgName.changeFileExt("nimble")
  else:
    var pkgName = os.getCurrentDir().splitPath.tail.toValidPackageName()
    pkgName = promptCustom("Enter package name", pkgName)
    nimbleFile = pkgName.changeFileExt("nimble")

  validatePackageName(nimbleFile.changeFileExt(""))

  if existsFile(os.getCurrentDir() / nimbleFile):
    raise newException(NimbleError, "Nimble file already exists.")

  # Ask for package version.
  let pkgVersion = promptCustom("Enter initial version of package", "0.1.0")
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
  let pkgAuthor = promptCustom("Enter your name", defaultAuthor)

  # Ask for description
  let pkgDesc = promptCustom("Enter package description", "")

  # Ask for license
  # TODO: Provide selection of licenses, or select random default license.
  let pkgLicense = promptCustom("Enter package license", "MIT")

  # Ask for Nim dependency
  let nimDepDef = getNimrodVersion()
  let pkgNimDep = promptCustom("Enter lowest supported Nim version", $nimDepDef)
  validateVersion(pkgNimDep)

  # Now generate the .nimble file.
  if existsFile(os.getCurrentDir() / nimbleFile):
    raise newException(NimbleError,
        "Looks like a Nimble file has already been created.")

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

proc uninstall(options: Options) =
  if options.action.packages.len == 0:
    raise newException(NimbleError,
        "Please specify the package(s) to uninstall.")

  var pkgsToDelete: seq[PackageInfo] = @[]
  # Do some verification.
  for pkgTup in options.action.packages:
    echo("Looking for ", pkgTup.name, " (", $pkgTup.ver, ")...")
    let installedPkgs = getInstalledPkgs(options.getPkgsDir(), options)
    var pkgList = findAllPkgs(installedPkgs, pkgTup)
    if pkgList.len == 0:
      raise newException(NimbleError, "Package not found")

    echo("Checking reverse dependencies...")
    var errors: seq[string] = @[]
    for pkg in pkgList:
      # Check whether any packages depend on the ones the user is trying to
      # uninstall.
      let thisPkgsDep = options.nimbleData["reverseDeps"]{pkg.name}{pkg.version}
      if not thisPkgsDep.isNil:
        var reason = ""
        if thisPkgsDep.len == 1:
          reason = thisPkgsDep[0]["name"].str &
              " (" & thisPkgsDep[0]["version"].str & ") depends on it"
        else:
          for i in 0 .. <thisPkgsDep.len:
            reason.add thisPkgsDep[i]["name"].str &
                " (" & thisPkgsDep[i]["version"].str & ")"
            if i != <thisPkgsDep.len:
              reason.add ", "
          reason.add " depend on it"
        errors.add("Cannot uninstall " & pkgTup.name & " (" & pkg.version &
                   ")" & " because " & reason)
      else:
        pkgsToDelete.add pkg

    if pkgsToDelete.len == 0:
      raise newException(NimbleError, "\n  " & errors.join("\n  "))

  var pkgNames = ""
  for i in 0 .. <pkgsToDelete.len:
    if i != 0: pkgNames.add ", "
    let pkg = pkgsToDelete[i]
    pkgNames.add pkg.name & " (" & pkg.version & ")"

  # Let's confirm that the user wants these packages removed.
  if not options.prompt("The following packages will be removed:\n  " &
      pkgNames & "\nDo you wish to continue?"):
    quit(QuitSuccess)

  for pkg in pkgsToDelete:
    # If we reach this point then the package can be safely removed.

    # removeRevDep needs the package dependency info, so we can't just pass
    # a minimal pkg info.
    let pkgFull = readPackageInfo(pkg.mypath, options, false)
    removeRevDep(options, pkgFull)
    removePkgDir(options.getPkgsDir / (pkg.name & '-' & pkg.version), options)
    echo("Removed ", pkg.name, " (", $pkg.version, ")")

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
  let pkgInfo = readPackageInfo(nimbleFile, options)
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
  if not existsDir(options.getNimbleDir()):
    createDir(options.getNimbleDir())
  if not existsDir(options.getPkgsDir):
    createDir(options.getPkgsDir)

  if not execHook(options, true):
    echo("Pre-hook prevented further execution.")
    return
  case options.action.typ
  of actionRefresh:
    update(options)
  of actionInstall:
    let (_, pkgInfo) = install(options.action.packages, options)
    if options.action.packages.len == 0:
      nimScriptHint(pkgInfo)
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
  of actionCompile:
    compile(options)
  of actionInit:
    init(options)
  of actionPublish:
    var pkgInfo = getPkgInfo(getCurrentDir(), options)
    publish(pkgInfo)
  of actionDump:
    dump(options)
  of actionTasks:
    listTasks(options)
  of actionVersion:
    writeVersion()
  of actionNil:
    assert false
  of actionCustom:
    # Custom command. Attempt to call a NimScript task.
    let nimbleFile = findNimbleFile(getCurrentDir(), true)
    if not nimbleFile.isNimScript(options):
      writeHelp()

    let execResult = execTask(nimbleFile, options.action.command, options)
    if not execResult.success:
      echo("FAILURE: Could not find task ", options.action.command, " in ",
           nimbleFile)
      writeHelp()
    if execResult.command.normalize == "nop":
      echo("WARNING: Using `setCommand 'nop'` is not necessary.")
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
      for flag, val in execResult.flags:
        parseFlag(flag, val, newOptions)
      doAction(newOptions)

  if options.action.typ != actionCustom:
    discard execHook(options, false)

when isMainModule:
  when defined(release):
    try:
      parseCmdLine().doAction()
    except NimbleError:
      quit("FAILURE: " & getCurrentExceptionMsg())
    finally:
      removeDir(getNimbleTempDir())
  else:
    parseCmdLine().doAction()
