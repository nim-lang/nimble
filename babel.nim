# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import httpclient, parseopt, os, strutils, osproc, pegs, tables, parseutils

import packageinfo, version, common, tools, download, algorithm

type
  TOptions = object
    forcePrompts: TForcePrompt
    queryVersions: bool
    action: TAction

  TActionType = enum
    ActionNil, ActionUpdate, ActionInstall, ActionSearch, ActionList,
    ActionBuild, ActionPath

  TAction = object
    case typ: TActionType
    of ActionNil, ActionList, ActionBuild: nil
    of ActionUpdate:
      optionalURL: string # Overrides default package list.
    of ActionInstall, ActionPath:
      optionalName: seq[string] # \
      # When this is @[], installs package from current dir.
    of ActionSearch:
      search: seq[string] # Search string.

  TForcePrompt = enum
    DontForcePrompt, ForcePromptYes, ForcePromptNo

const
  help = """
Usage: babel COMMAND [opts]

Commands:
  install      [pkgname, ...]     Installs a list of packages.
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
  babelVersion = "0.1.0"
  defaultPackageURL = "https://github.com/nimrod-code/packages/raw/master/packages.json"

proc writeHelp() =
  echo(help)
  quit(QuitSuccess)

proc writeVersion() =
  echo("babel v$# compiled at $# $#" % [babelVersion, compileDate, compileTime])
  quit(QuitSuccess)

proc parseCmdLine(): TOptions =
  result.action.typ = ActionNil
  for kind, key, val in getOpt():
    case kind
    of cmdArgument:
      if result.action.typ == ActionNil:
        case key
        of "install":
          result.action.typ = ActionInstall
          result.action.optionalName = @[]
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
        of "path":
          result.action.typ = ActionPath
          result.action.optionalName = @[]
        else: writeHelp()
      else:
        case result.action.typ
        of ActionNil:
          assert false
        of ActionInstall, ActionPath:
          result.action.optionalName.add(key)
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

let babelDir = getHomeDir() / ".babel"
let pkgsDir = babelDir / "pkgs"
let binDir = babelDir / "bin"

proc update(url: string = defaultPackageURL) =
  ## Downloads the package list from the specified URL.
  ##
  ## If the download is successful, the global didUpdatePackages is set to
  ## true. Otherwise an exception is raised on error.
  echo("Downloading package list from " & url)
  downloadFile(url, babelDir / "packages.json")
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

proc copyWithExt(origDir, currentDir, dest: string, pkgInfo: TPackageInfo) =
  for kind, path in walkDir(currentDir):
    if kind == pcDir:
      copyWithExt(origDir, path, dest, pkgInfo)
    else:
      for iExt in pkgInfo.installExt:
        if path.splitFile.ext == ('.' & iExt):
          createDir(changeRoot(origDir, dest, path).splitFile.dir)
          copyFileD(path, changeRoot(origDir, dest, path))

proc copyFilesRec(origDir, currentDir, dest: string, pkgInfo: TPackageInfo) =
  ## Copies all the required files, skips files specified in the .babel file
  ## (TPackageInfo).
  let whitelistMode =
          pkgInfo.installDirs.len != 0 or
          pkgInfo.installFiles.len != 0 or
          pkgInfo.installExt.len != 0
  if whitelistMode:
    for file in pkgInfo.installFiles:
      createDir(dest / file.splitFile.dir)
      copyFileD(origDir / file, dest / file)

    for dir in pkgInfo.installDirs:
      # TODO: Allow skipping files inside dirs?
      copyDirD(origDir / dir, dest / dir)

    copyWithExt(origDir, currentDir, dest, pkgInfo)
  else:
    for kind, file in walkDir(currentDir):
      if kind == pcDir:
        let skip = pkgInfo.checkInstallDir(origDir, file)
        
        if skip: continue
        # Create the dir.
        createDir(changeRoot(origDir, dest, file))
        
        copyFilesRec(origDir, file, dest, pkgInfo)
      else:
        let skip = pkgInfo.checkInstallFile(origDir, file)

        if skip: continue

        copyFileD(file, changeRoot(origDir, dest, file)) 

  copyFileD(pkgInfo.mypath,
            changeRoot(pkgInfo.mypath.splitFile.dir, dest, pkgInfo.mypath))

proc install(packages: seq[tuple[name: string, verRange: PVersionRange]],
             options: TOptions, doPrompt = true): string {.discardable.}
proc processDeps(pkginfo: TPackageInfo, options: TOptions): seq[string] =
  ## Verifies and installs dependencies.
  ##
  ## Returns the list of paths to pass to the compiler during build phase.
  result = @[]
  let pkglist = getInstalledPkgs(pkgsDir)
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
        let dest = install(@[(dep.name, dep.ver)], options)
        result.add(dest)
      else:
        echo("Dependency already satisfied.")
        result.add(pkg.mypath.splitFile.dir)

proc buildFromDir(pkgInfo: TPackageInfo, paths: seq[string]) =
  ## Builds a package as specified by ``pkgInfo``.
  let realDir = pkgInfo.getRealDir()
  var args = ""
  for path in paths: args.add("--path:\"" & path & "\" ")
  for bin in pkgInfo.bin:
    echo("Building ", pkginfo.name, "/", bin, " using ", pkgInfo.backend,
         " backend...")
    doCmd("nimrod $# -d:release $# \"$#\"" %
          [pkgInfo.backend, args, realDir / bin.changeFileExt("nim")])

proc installFromDir(dir: string, latest: bool, options: TOptions): string =
  ## Returns where package has been installed to.
  ## The return value of this function is used by
  ## ``processDeps`` to gather a list of paths to pass to the nimrod compiler.
  var pkgInfo = getPkgInfo(dir)
  let realDir = pkgInfo.getRealDir()
  
  let pkgDestDir = pkgsDir / (pkgInfo.name &
                   (if latest: "" else: '-' & pkgInfo.version))
  if existsDir(pkgDestDir):
    if not options.prompt(pkgInfo.name & " already exists. Overwrite?"):
      quit(QuitSuccess)
    removeDir(pkgDestDir)
    # Remove any symlinked binaries
    for bin in pkgInfo.bin:
      # TODO: Check that this binary belongs to the package being installed.
      when defined(windows):
        removeFile(binDir / bin.changeFileExt("bat"))
      else:
        removeFile(binDir / bin)
  
  echo("Installing ", pkginfo.name, "-", pkginfo.version)
  
  # Dependencies need to be processed before the creation of the pkg dir.
  let paths = processDeps(pkginfo, options)
  
  if pkgInfo.bin.len > 0: buildFromDir(pkgInfo, paths)
  
  createDir(pkgDestDir)
  if pkgInfo.bin.len > 0:
    createDir(binDir)
    # Copy all binaries and files that are not skipped
    copyFilesRec(realDir, realDir, pkgDestDir, pkgInfo)
    # Set file permissions to +x for all binaries built,
    # and symlink them on *nix OS' to $babelDir/bin/
    for bin in pkgInfo.bin:
      if not existsFile(pkgDestDir / bin):
        copyFileD(realDir / bin, pkgDestDir / bin)
      
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
    copyFilesRec(realDir, realDir, pkgDestDir, pkgInfo)
  result = pkgDestDir

  echo(pkgInfo.name & " installed successfully.")

proc downloadPkg(url: string, verRange: PVersionRange,
                 downMethod: TDownloadMethod): string =
  let downloadDir = (getTempDir() / "babel" / getDownloadDirName(url, verRange))
  if not existsDir(getTempDir() / "babel"): createDir(getTempDir() / "babel")
  echo("Downloading ", url, " into ", downloadDir, " using ", downMethod, "...")
  doDownload(url, downloadDir, verRange, downMethod)
  result = downloadDir

proc downloadPkg(pkg: TPackage, verRange: PVersionRange): string =
  let downloadDir = (getTempDir() / "babel" / getDownloadDirName(pkg, verRange))
  if not existsDir(getTempDir() / "babel"): createDir(getTempDir() / "babel")
  let downMethod = pkg.downloadMethod.getDownloadMethod()
  echo("Downloading ", pkg.name, " into ", downloadDir, " using ", downMethod, "...")
  doDownload(pkg.url, downloadDir, verRange, downMethod)
  result = downloadDir

proc install(packages: seq[tuple[name: string, verRange: PVersionRange]],
             options: TOptions, doPrompt = true): string =
  if packages == @[]:
    result = installFromDir(getCurrentDir(), false, options)
  else:
    # If packages.json is not present ask the user if they want to download it.
    if not existsFile(babelDir / "packages.json"):
      if doPrompt and
          options.prompt("Local packages.json not found, download it from internet?"):
        update()
        install(packages, options, false)
      else:
        quit("Please run babel update.", QuitFailure)
    
    # Install each package.
    for pv in packages:
      if pv.name.startsWith(peg" @'://' "):
        let meth = checkUrlType(pv.name)
        let downloadDir = downloadPkg(pv.name, pv.verRange, meth)
        result = installFromDir(downloadDir, false, options)
      else:
        var pkg: TPackage
        if getPackage(pv.name, babelDir / "packages.json", pkg):
          let downloadDir = downloadPkg(pkg, pv.verRange)
          result = installFromDir(downloadDir, false, options)
        else:
          # If package is not found give the user a chance to update package.json
          if doPrompt and
              options.prompt(pv.name & " not found in local packages.json, check internet for updated packages?"):
            update()
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
  if not existsFile(babelDir / "packages.json"):
    raise newException(EBabel, "Please run babel update.")
  let pkgList = getPackageList(babelDir / "packages.json")
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
  if not existsFile(babelDir / "packages.json"):
    raise newException(EBabel, "Please run babel update.")
  let pkgList = getPackageList(babelDir / "packages.json")
  for pkg in pkgList:
    echoPackage(pkg)
    if options.queryVersions:
      echoPackageVersions(pkg)
    echo(" ")

type VersionAndPath = tuple[version: TVersion, path: string]

proc listPaths(packages: seq[String]) =
  ## Loops over installing packages displaying their installed paths.
  ##
  ## If there are several packages installed, only the last one (the version
  ## listed in the packages.json) will be displayed. If any package name is not
  ## found, the proc displays a missing message and continues through the list,
  ## but at the end quits with a non zero exit error.
  ##
  ## On success the proc returns normally.
  var errors = 0
  for name in packages:
    var installed: seq[VersionAndPath] = @[]
    # There may be several, list all available ones and sort by version.
    for file in walkFiles(pkgsDir / name & "-*" / name & ".babel"):
      var pkgInfo = getPkgInfo(splitFile(file).dir)
      var v: VersionAndPath
      v.version = newVersion(pkgInfo.version)
      v.path = pkgsDir / (pkgInfo.name & '-' & pkgInfo.version)
      installed.add(v)

    if installed.len > 0:
      sort(installed, system.cmp[VersionAndPath], Descending)
      echo installed[0].path
    else:
      echo "Warning: Package '" & name & "' not installed"
      errors += 1
  if errors > 0:
    raise newException(EBabel, "At least one of the specified packages was not found")

proc doAction(options: TOptions) =
  case options.action.typ
  of ActionUpdate:
    if options.action.optionalURL != "":
      update(options.action.optionalURL)
    else:
      update()
  of ActionInstall:
    var installList: seq[tuple[name: string, verRange: PVersionRange]] = @[]
    for name in options.action.optionalName:
      if '#' in name:
        let i = find(name, '#')
        installList.add((name[0 .. i-1], name[i .. -1].parseVersionRange()))
      else:
        installList.add((name, PVersionRange(kind: verAny)))
      
    install(installList, options)
  of ActionSearch:
    search(options)
  of ActionList:
    list(options)
  of ActionPath:
    listPaths(options.action.optionalName)
  of ActionBuild:
    build(options)
  of ActionNil:
    assert false

when isMainModule:
  if not existsDir(babelDir):
    createDir(babelDir)
  if not existsDir(pkgsDir):
    createDir(pkgsDir)
  
  when defined(release):
    try:
      parseCmdLine().doAction()
    except EBabel:
      quit("FAILURE: " & getCurrentExceptionMsg())
  else:
    parseCmdLine().doAction()
