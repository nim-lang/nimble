# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import httpclient, parseopt, os, strutils, osproc, pegs, tables, parseutils,
       strtabs, json, algorithm, sets

from sequtils import toSeq

import babelpkg/packageinfo, babelpkg/version, babelpkg/tools, babelpkg/download,
       babelpkg/config

when not defined(windows):
  from posix import getpid

type
  TOptions = object
    forcePrompts: TForcePrompt
    queryVersions: bool
    action: TAction
    config: TConfig
    babelData: PJsonNode ## Babeldata.json

  TActionType = enum
    ActionNil, ActionUpdate, ActionInstall, ActionSearch, ActionList,
    ActionBuild, ActionPath, ActionUninstall

  TAction = object
    case typ: TActionType
    of ActionNil, ActionList, ActionBuild: nil
    of ActionUpdate:
      optionalURL: string # Overrides default package list.
    of ActionInstall, ActionPath, ActionUninstall:
      optionalName: seq[string] # \
      # When this is @[], installs package from current dir.
      packages: seq[TPkgTuple] # Optional only for ActionInstall.
    of ActionSearch:
      search: seq[string] # Search string.

  TForcePrompt = enum
    DontForcePrompt, ForcePromptYes, ForcePromptNo

const
  help = """
Usage: babel COMMAND [opts]

Commands:
  install      [pkgname, ...]     Installs a list of packages.
  uninstall    [pkgname, ...]     Uninstalls a list of packages.
  build                           Builds a package.
  update       [url]              Updates package list. A package list URL can 
                                  be optionally specified.
  search       [--ver] pkg/tag    Searches for a specified package. Search is 
                                  performed by tag and by name.
  list         [--ver]            Lists all packages.
  path         pkgname ...        Shows absolute path to the installed packages 
                                  specified.

Options:
  -h, --help                      Print this help message.
  -v, --version                   Print version information.
  -y, --accept                    Accept all interactive prompts.
  -n, --reject                    Reject all interactive prompts.
      --ver                       Query remote server for package version 
                                  information when searching or listing packages
"""
  babelVersion = "0.2.0"
  defaultPackageURL = "https://github.com/nimrod-code/packages/raw/master/packages.json"

proc writeHelp() =
  echo(help)
  quit(QuitSuccess)

proc writeVersion() =
  echo("babel v$# compiled at $# $#" % [babelVersion, compileDate, compileTime])
  quit(QuitSuccess)

proc getBabelDir(options: TOptions): string =
  options.config.babelDir

proc getPkgsDir(options: TOptions): string =
  options.config.babelDir / "pkgs"

proc getBinDir(options: TOptions): string =
  options.config.babelDir / "bin"

proc parseCmdLine(): TOptions =
  result.action.typ = ActionNil
  result.config = parseConfig()
  for kind, key, val in getOpt():
    case kind
    of cmdArgument:
      if result.action.typ == ActionNil:
        case key
        of "install", "path":
          case key
          of "install":
            result.action.typ = ActionInstall
          of "path":
            result.action.typ = ActionPath
          result.action.optionalName = @[]
          result.action.packages = @[]
        of "build":
          result.action.typ = ActionBuild
        of "update":
          result.action.typ = ActionUpdate
          result.action.optionalURL = ""
        of "search":
          result.action.typ = ActionSearch
          result.action.search = @[]
        of "list":
          result.action.typ = ActionList
        of "uninstall", "remove", "delete", "del", "rm":
          result.action.typ = ActionUninstall
          result.action.packages = @[]
          result.action.optionalName = @[]
        else: writeHelp()
      else:
        case result.action.typ
        of ActionNil:
          assert false
        of ActionInstall, ActionPath, ActionUninstall:
          result.action.optionalName.add(key)

          # Parse pkg@verRange
          if '@' in key:
            let i = find(key, '@')
            let pkgTup = (key[0 .. i-1], key[i+1 .. -1].parseVersionRange())
            result.action.packages.add(pkgTup)
          else:
            result.action.packages.add((key, PVersionRange(kind: verAny)))
        of ActionUpdate:
          result.action.optionalURL = key
        of ActionSearch:
          result.action.search.add(key)
        of ActionList, ActionBuild:
          writeHelp()
    of cmdLongOption, cmdShortOption:
      case key
      of "help", "h": writeHelp()
      of "version", "v": writeVersion()
      of "accept", "y": result.forcePrompts = ForcePromptYes
      of "reject", "n": result.forcePrompts = ForcePromptNo
      of "ver": result.queryVersions = true
    of cmdEnd: assert(false) # cannot happen
  if result.action.typ == ActionNil:
    writeHelp()

  # Load babeldata.json
  let babeldataFilename = result.getBabelDir() / "babeldata.json"
  if fileExists(babeldataFilename):
    result.babelData = parseFile(babeldataFilename)
  else:
    result.babelData = %{"reverseDeps": newJObject()}

proc prompt(options: TOptions, question: string): bool =
  ## Asks an interactive question and returns the result.
  ##
  ## The proc will return immediately without asking the user if the global
  ## forcePrompts has a value different than DontForcePrompt.
  case options.forcePrompts
  of ForcePromptYes:
    echo(question & " -> [forced yes]")
    return true
  of ForcePromptNo:
    echo(question & " -> [forced no]")
    return false
  of DontForcePrompt:
    echo(question & " [y/N]")
    let yn = stdin.readLine()
    case yn.normalize
    of "y", "yes":
      return true
    of "n", "no":
      return false
    else:
      return false

proc update(options: TOptions) =
  ## Downloads the package list from the specified URL.
  ##
  ## If the download is successful, the global didUpdatePackages is set to
  ## true. Otherwise an exception is raised on error.
  let url =
    if options.action.typ == ActionUpdate and options.action.optionalURL != "":
      options.action.optionalURL
    else:
      defaultPackageURL
  echo("Downloading package list from " & url)
  downloadFile(url, options.getBabelDir() / "packages.json")
  echo("Done.")

proc checkInstallFile(pkgInfo: TPackageInfo,
                      origDir, file: string): bool =
  ## Checks whether ``file`` should be installed.
  ## ``True`` means file should be skipped.

  for ignoreFile in pkgInfo.skipFiles:
    if ignoreFile.endswith("babel"):
      raise newException(EBabel, ignoreFile & " must be installed.")
    if samePaths(file, origDir / ignoreFile):
      result = true
      break

  for ignoreExt in pkgInfo.skipExt:
    if file.splitFile.ext == ('.' & ignoreExt):
      result = true
      break

  if file.splitFile().name[0] == '.': result = true

proc checkInstallDir(pkgInfo: TPackageInfo,
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
                 pkgInfo: TPackageInfo): seq[string] =
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
                  options: TOptions, pkgInfo: TPackageInfo): TSet[string] =
  ## Copies all the required files, skips files specified in the .babel file
  ## (TPackageInfo).
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

proc addRevDep(options: TOptions, dep: tuple[name, version: string],
               pkg: TPackageInfo) =
  let depNameVer = dep.name & '-' & dep.version
  if not options.babelData["reverseDeps"].hasKey(dep.name):
    options.babelData["reverseDeps"][dep.name] = newJObject()
  if not options.babelData["reverseDeps"][dep.name].hasKey(dep.version):
    options.babelData["reverseDeps"][dep.name][dep.version] = newJArray()
  let revDep = %{ "name": %pkg.name, "version": %pkg.version}
  let thisDep = options.babelData["reverseDeps"][dep.name][dep.version]
  if revDep notin thisDep:
    thisDep.add revDep

  writeFile(options.getBabelDir() / "babeldata.json", pretty(options.babelData))

proc removeRevDep(options: TOptions, pkg: TPackageInfo) =
  ## Removes ``pkg`` from the reverse dependencies of every package.
  for depTup in pkg.requires:
    let thisDep = options.babelData["reverseDeps"][depTup.name]
    if thisDep.isNil: continue
    for ver, val in thisDep:
      if ver.newVersion in depTup.ver:
        var newVal = newJArray()
        for revDep in val:
          if not (revDep["name"].str == pkg.name and
                  revDep["version"].str == pkg.version):
            newVal.add revDep
        options.babelData["reverseDeps"][depTup.name][ver] = newVal

  writeFile(options.getBabelDir() / "babeldata.json", pretty(options.babelData))

proc install(packages: seq[tuple[name: string, verRange: PVersionRange]],
             options: TOptions, doPrompt = true): seq[string] {.discardable.}
proc processDeps(pkginfo: TPackageInfo, options: TOptions): seq[string] =
  ## Verifies and installs dependencies.
  ##
  ## Returns the list of paths to pass to the compiler during build phase.
  result = @[]
  let pkglist = getInstalledPkgs(options.getPkgsDir())
  for dep in pkginfo.requires:
    if dep.name == "nimrod":
      let nimVer = getNimrodVersion()
      if not withinRange(nimVer, dep.ver):
        quit("Unsatisfied dependency: " & dep.name & " (" & $dep.ver & ")")
    else:
      echo("Looking for ", dep.name, " (", $dep.ver, ")...")
      var pkg: TPackageInfo
      if not findPkg(pkglist, dep, pkg):
        echo("None found, installing...")
        let paths = install(@[(dep.name, dep.ver)], options)
        result.add(paths)

        # Look up the pkg info again, for addRevDep.
        doAssert findPkg(pkgList, dep, pkg)
      else:
        echo("Dependency already satisfied.")
        result.add(pkg.mypath.splitFile.dir)
        # Process the dependencies of this dependency.
        result.add(processDeps(pkg, options))
      addRevDep(options, (pkg.name, pkg.version), pkginfo)
  
  # Check if two packages of the same name (but different version) are listed
  # in the path.
  var pkgsInPath: PStringTable = newStringTable(modeCaseSensitive)
  for p in result:
    let (name, version) = getNameVersion(p)
    if pkgsInPath.hasKey(name) and pkgsInPath[name] != version:
      raise newException(EBabel,
        "Cannot satisfy the dependency on $1 $2 and $1 $3" %
          [name, version, pkgsInPath[name]])
    pkgsInPath[name] = version

proc buildFromDir(pkgInfo: TPackageInfo, paths: seq[string]) =
  ## Builds a package as specified by ``pkgInfo``.
  let realDir = pkgInfo.getRealDir()
  var args = ""
  for path in paths: args.add("--path:\"" & path & "\" ")
  for bin in pkgInfo.bin:
    echo("Building ", pkginfo.name, "/", bin, " using ", pkgInfo.backend,
         " backend...")
    doCmd("nimrod $# -d:release --noBabelPath $# \"$#\"" %
          [pkgInfo.backend, args, realDir / bin.changeFileExt("nim")])

proc saveBabelMeta(pkgDestDir, url: string, filesInstalled: TSet[string]) =
  var babelmeta = %{"url": %url}
  babelmeta["files"] = newJArray()
  for file in filesInstalled:
    babelmeta["files"].add(%changeRoot(pkgDestDir, "", file))
  writeFile(pkgDestDir / "babelmeta.json", $babelmeta)

proc removePkgDir(dir: string, options: TOptions) =
  ## Removes files belonging to the package in ``dir``.
  try:
    var babelmeta = parseFile(dir / "babelmeta.json")
    if not babelmeta.hasKey("files"):
      raise newException(EJsonParsingError,
                         "Meta data does not contain required info.")
    for file in babelmeta["files"]:
      removeFile(dir / file.str)

    removeFile(dir / "babelmeta.json")

    # If there are no files left in the directory, remove the directory.
    if toSeq(walkDirRec(dir)).len == 0:
      removeDir(dir)
    else:
      echo("WARNING: Cannot completely remove " & dir &
           ". Files not installed by babel are present.")
  except EOS, EJsonParsingError:
    echo("Error: Unable to read babelmeta.json: ", getCurrentExceptionMsg())
    if not options.prompt("Would you like to COMPLETELY remove ALL files " &
                          "in " & dir & "?"):
      quit(QuitSuccess)
    removeDir(dir)

proc installFromDir(dir: string, latest: bool, options: TOptions,
                    url: string): seq[string] =
  ## Returns where package has been installed to, together with paths
  ## to the packages this package depends on.
  ## The return value of this function is used by
  ## ``processDeps`` to gather a list of paths to pass to the nimrod compiler.
  var pkgInfo = getPkgInfo(dir)
  let realDir = pkgInfo.getRealDir()
  let binDir = options.getBinDir()
  let pkgsDir = options.getPkgsDir()
  # Dependencies need to be processed before the creation of the pkg dir.
  let paths = processDeps(pkginfo, options)

  echo("Installing ", pkginfo.name, "-", pkginfo.version)

  # Build before removing an existing package (if one exists). This way
  # if the build fails then the old package will still be installed.
  if pkgInfo.bin.len > 0: buildFromDir(pkgInfo, paths)

  let versionStr = (if latest: "" else: '-' & pkgInfo.version)
  let pkgDestDir = pkgsDir / (pkgInfo.name & versionStr)
  if existsDir(pkgDestDir) and existsFile(pkgDestDir / "babelmeta.json"):
    if not options.prompt(pkgInfo.name & versionStr & " already exists. Overwrite?"):
      quit(QuitSuccess)
    removePkgDir(pkgDestDir, options)
    # Remove any symlinked binaries
    for bin in pkgInfo.bin:
      # TODO: Check that this binary belongs to the package being installed.
      when defined(windows):
        removeFile(binDir / bin.changeFileExt("bat"))
      else:
        removeFile(binDir / bin)

  ## Will contain a list of files which have been installed.
  var filesInstalled: TSet[string]
  
  createDir(pkgDestDir)
  if pkgInfo.bin.len > 0:
    createDir(binDir)
    # Copy all binaries and files that are not skipped
    filesInstalled = copyFilesRec(realDir, realDir, pkgDestDir, options,
                                  pkgInfo)
    # Set file permissions to +x for all binaries built,
    # and symlink them on *nix OS' to $babelDir/bin/
    for bin in pkgInfo.bin:
      if not existsFile(pkgDestDir / bin):
        filesInstalled.incl copyFileD(realDir / bin, pkgDestDir / bin)
      
      let currentPerms = getFilePermissions(pkgDestDir / bin)
      setFilePermissions(pkgDestDir / bin, currentPerms + {fpUserExec})
      let cleanBin = bin.extractFilename
      when defined(unix):
        # TODO: Verify that we are removing an old bin of this package, not
        # some other package's binary!
        if existsFile(binDir / bin): removeFile(binDir / cleanBin)
        echo("Creating symlink: ", pkgDestDir / bin, " -> ", binDir / cleanBin)
        doCmd("ln -s \"" & pkgDestDir / bin & "\" " & binDir / cleanBin)
      elif defined(windows):
        let dest = binDir / cleanBin.changeFileExt("bat")
        echo("Creating stub: ", pkgDestDir / bin, " -> ", dest)
        writeFile(dest, "\"" & pkgDestDir / bin & "\" %*\n")
      else:
        {.error: "Sorry, your platform is not supported.".}
  else:
    filesInstalled = copyFilesRec(realDir, realDir, pkgDestDir, options,
                                  pkgInfo)
  
  # Save a babelmeta.json file.
  saveBabelMeta(pkgDestDir, url, filesInstalled)
  
  result = paths # Return the paths to the dependencies of this package.
  result.add pkgDestDir

  echo(pkgInfo.name & " installed successfully.")

proc getBabelTempDir(): string =
  ## Returns a path to a temporary directory.
  ##
  ## The returned path will be the same for the duration of the process but
  ## different for different runs of it. You have to make sure to create it
  ## first. In release builds the directory will be removed when babel finishes
  ## its work.
  result = getTempDir() / "babel_"
  when defined(windows):
    proc GetCurrentProcessId(): int32 {.stdcall, dynlib: "kernel32",
                                        importc: "GetCurrentProcessId".}
    result.add($GetCurrentProcessId())
  else:
    result.add($getpid())

proc downloadPkg(url: string, verRange: PVersionRange,
                 downMethod: TDownloadMethod): string =
  let downloadDir = (getBabelTempDir() / getDownloadDirName(url, verRange))
  echo("Downloading ", url, " into ", downloadDir, " using ", downMethod, "...")
  doDownload(url, downloadDir, verRange, downMethod)
  result = downloadDir

proc downloadPkg(pkg: TPackage, verRange: PVersionRange): string =
  let downloadDir = (getBabelTempDir() / getDownloadDirName(pkg, verRange))
  let downMethod = pkg.downloadMethod.getDownloadMethod()
  echo("Downloading ", pkg.name, " into ", downloadDir, " using ", downMethod, "...")
  doDownload(pkg.url, downloadDir, verRange, downMethod)
  result = downloadDir

proc install(packages: seq[tuple[name: string, verRange: PVersionRange]],
             options: TOptions, doPrompt = true): seq[string] =
  if packages == @[]:
    result = installFromDir(getCurrentDir(), false, options, "")
  else:
    # If packages.json is not present ask the user if they want to download it.
    if not existsFile(options.getBabelDir / "packages.json"):
      if doPrompt and
          options.prompt("Local packages.json not found, download it from internet?"):
        update(options)
        install(packages, options, false)
      else:
        quit("Please run babel update.", QuitFailure)
    
    # Install each package.
    for pv in packages:
      if pv.name.startsWith(peg" @'://' "):
        let meth = checkUrlType(pv.name)
        let downloadDir = downloadPkg(pv.name, pv.verRange, meth)
        result = installFromDir(downloadDir, false, options, pv.name)
      else:
        var pkg: TPackage
        if getPackage(pv.name, options.getBabelDir() / "packages.json", pkg):
          let downloadDir = downloadPkg(pkg, pv.verRange)
          result = installFromDir(downloadDir, false, options, pkg.url)
        else:
          # If package is not found give the user a chance to update package.json
          if doPrompt and
              options.prompt(pv.name & " not found in local packages.json, " &
                             "check internet for updated packages?"):
            update(options)
            install(@[pv], options, false)
          else:
            raise newException(EBabel, "Package not found.")

proc build(options: TOptions) =
  var pkgInfo = getPkgInfo(getCurrentDir())
  let paths = processDeps(pkginfo, options)
  buildFromDir(pkgInfo, paths)

proc search(options: TOptions) =
  ## Searches for matches in ``options.action.search``.
  ##
  ## Searches are done in a case insensitive way making all strings lower case.
  assert options.action.typ == ActionSearch
  if options.action.search == @[]:
    raise newException(EBabel, "Please specify a search string.")
  if not existsFile(options.getBabelDir() / "packages.json"):
    raise newException(EBabel, "Please run babel update.")
  let pkgList = getPackageList(options.getBabelDir() / "packages.json")
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

proc list(options: TOptions) =
  if not existsFile(options.getBabelDir() / "packages.json"):
    raise newException(EBabel, "Please run babel update.")
  let pkgList = getPackageList(options.getBabelDir() / "packages.json")
  for pkg in pkgList:
    echoPackage(pkg)
    if options.queryVersions:
      echoPackageVersions(pkg)
    echo(" ")

type VersionAndPath = tuple[version: TVersion, path: string]

proc listPaths(options: TOptions) =
  ## Loops over installing packages displaying their installed paths.
  ##
  ## If there are several packages installed, only the last one (the version
  ## listed in the packages.json) will be displayed. If any package name is not
  ## found, the proc displays a missing message and continues through the list,
  ## but at the end quits with a non zero exit error.
  ##
  ## On success the proc returns normally.
  var errors = 0
  for name in options.action.optionalName:
    var installed: seq[VersionAndPath] = @[]
    # There may be several, list all available ones and sort by version.
    for kind, path in walkDir(options.getPkgsDir):
      if kind != pcDir or not path.startsWith(options.getPkgsDir / name):
        continue

      let babelFile = path / name.addFileExt("babel")
      if existsFile(babelFile):
        var pkgInfo = getPkgInfo(path)
        var v: VersionAndPath
        v.version = newVersion(pkgInfo.version)
        v.path = options.getPkgsDir / (pkgInfo.name & '-' & pkgInfo.version)
        installed.add(v)
      else:
        echo "Warning: No .babel file found for ", path

    if installed.len > 0:
      sort(installed, system.cmp[VersionAndPath], Descending)
      echo installed[0].path
    else:
      echo "Warning: Package '" & name & "' not installed"
      errors += 1
  if errors > 0:
    raise newException(EBabel, "At least one of the specified packages was not found")

proc uninstall(options: TOptions) =
  var pkgsToDelete: seq[TPackageInfo] = @[]
  # Do some verification.
  for pkgTup in options.action.packages:
    echo("Looking for ", pkgTup.name, " (", $pkgTup.ver, ")...")
    let pkgList = getInstalledPkgs(options.getPkgsDir())
    var pkg: TPackageInfo
    if not findPkg(pkglist, pkgTup, pkg):
      raise newException(EBabel, "Package not found")

    echo("Checking reverse dependencies...")
    # Check whether any packages depend on the one the user is trying to uninstall
    let thisDep = options.babelData["reverseDeps"][pkgTup.name]
    if not thisDep.isNil:
      for ver, val in thisDep.pairs:
        if ver.newVersion in pkgTup.ver and val.len != 0:
          assert val.kind == JArray
          var reason = ""
          if val.len == 1:
            reason = val[0]["name"].str & " (" & val[0]["version"].str &
                ") depends on it"
          else:
            for i in 0 .. <val.len:
              reason.add val[i]["name"].str & " (" & val[i]["version"].str & ")"
              if i != <val.len:
                reason.add ", "
            reason.add " depend on it"

          raise newException(EBabel, "Cannot uninstall " & pkgTup.name &
              " because " & reason)

    pkgsToDelete.add pkg

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
    removeRevDep(options, pkg)
    removePkgDir(options.getPkgsDir / (pkg.name & '-' & pkg.version), options)
    echo("Removed ", pkg.name, " (", $pkg.version, ")")

proc doAction(options: TOptions) =
  if not existsDir(options.getBabelDir()):
    createDir(options.getBabelDir())
  if not existsDir(options.getPkgsDir):
    createDir(options.getPkgsDir)

  case options.action.typ
  of ActionUpdate:
    update(options)
  of ActionInstall:
    var installList: seq[tuple[name: string, verRange: PVersionRange]] = @[]
    for name in options.action.optionalName:
      if '#' in name: # TODO: Change this to allow babel install pkg@>0.1
        let i = find(name, '#')
        installList.add((name[0 .. i-1], name[i .. -1].parseVersionRange()))
      else:
        installList.add((name, PVersionRange(kind: verAny)))
      
    install(installList, options)
  of ActionUninstall:
    uninstall(options)
  of ActionSearch:
    search(options)
  of ActionList:
    list(options)
  of ActionPath:
    listPaths(options)
  of ActionBuild:
    build(options)
  of ActionNil:
    assert false

when isMainModule:
  when defined(release):
    try:
      parseCmdLine().doAction()
    except EBabel:
      quit("FAILURE: " & getCurrentExceptionMsg())
    finally:
      removeDir(getBabelTempDir())
  else:
    parseCmdLine().doAction()
