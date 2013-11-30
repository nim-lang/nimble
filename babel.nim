# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import httpclient, parseopt, os, strutils, osproc, pegs, tables, parseutils

import packageinfo, version, common, tools, download, algorithm

type
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

var forcePrompts = DontForcePrompt

const
  help = """
Usage: babel COMMAND [opts]

Commands:
  install      [pkgname, ...] Installs a list of packages.
  build                       Builds a package.
  update       [url]          Updates package list. A package list URL can be optionally specified.
  search       pkg/tag        Searches for a specified package. Search is performed by tag and by name.
  list                        Lists all packages.
  path         [pkgname, ...] Shows absolute path to the installed packages.

Options:
  -h, -help                   Print this help message.
  -v, -version                Print version information.
  -y, -accept                 Accept all interactive prompts.
  -n, -reject                 Reject all interactive prompts.
"""
  babelVersion = "0.1.0"
  defaultPackageURL = "https://github.com/nimrod-code/packages/raw/master/packages.json"

proc writeHelp() =
  echo(help)
  quit(QuitSuccess)

proc writeVersion() =
  echo("babel v$# compiled at $# $#" % [babelVersion, compileDate, compileTime])
  quit(QuitSuccess)

proc parseCmdLine(): TAction =
  result.typ = ActionNil
  for kind, key, val in getOpt():
    case kind
    of cmdArgument:
      if result.typ == ActionNil:
        case key
        of "install":
          result.typ = ActionInstall
          result.optionalName = @[]
        of "build":
          result.typ = ActionBuild
        of "update":
          result.typ = ActionUpdate
          result.optionalURL = ""
        of "search":
          result.typ = ActionSearch
          result.search = @[]
        of "list":
          result.typ = ActionList
        of "path":
          result.typ = ActionPath
          result.optionalName = @[]
        else: writeHelp()
      else:
        case result.typ
        of ActionNil:
          assert false
        of ActionInstall, ActionPath:
          result.optionalName.add(key)
        of ActionUpdate:
          result.optionalURL = key
        of ActionSearch:
          result.search.add(key)
        of ActionList, ActionBuild:
          writeHelp()
    of cmdLongOption, cmdShortOption:
      case key
      of "help", "h": writeHelp()
      of "version", "v": writeVersion()
      of "accept", "y": forcePrompts = ForcePromptYes
      of "reject", "n": forcePrompts = ForcePromptNo
    of cmdEnd: assert(false) # cannot happen
  if result.typ == ActionNil:
    writeHelp()

proc prompt(question: string): bool =
  ## Asks an interactive question and returns the result.
  ##
  ## The proc will return immediately without asking the user if the global
  ## forcePrompts has a value different than DontForcePrompt.
  case forcePrompts
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
let nimVer = getNimrodVersion()
var didUpdatePackages = false

proc update(url: string = defaultPackageURL) =
  ## Downloads the package list from the specified URL.
  ##
  ## If the download is successful, the global didUpdatePackages is set to
  ## true. Otherwise an exception is raised on error.
  echo("Downloading package list from " & url)
  downloadFile(url, babelDir / "packages.json")
  didUpdatePackages = true
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

proc install(packages: seq[String], verRange: PVersionRange): string {.discardable.}
proc processDeps(pkginfo: TPackageInfo): seq[string] =
  ## Verifies and installs dependencies.
  ##
  ## Returns the list of paths to pass to the compiler during build phase.
  result = @[]
  let pkglist = getInstalledPkgs(pkgsDir)
  for dep in pkginfo.requires:
    if dep.name == "nimrod":
      if not withinRange(nimVer, dep.ver):
        quit("Unsatisfied dependency: " & dep.name & " (" & $dep.ver & ")")
    else:
      echo("Looking for ", dep.name, " (", $dep.ver, ")...")
      var pkg: TPackageInfo
      if not findPkg(pkglist, dep, pkg):
        echo("None found, installing...")
        let dest = install(@[dep.name], dep.ver)
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

proc installFromDir(dir: string, latest: bool): string =
  ## Returns where package has been installed to.
  ## The return value of this function is used by
  ## ``processDeps`` to gather a list of paths to pass to the nimrod compiler.
  var pkgInfo = getPkgInfo(dir)
  let realDir = pkgInfo.getRealDir()
  
  let pkgDestDir = pkgsDir / (pkgInfo.name &
                   (if latest: "" else: '-' & pkgInfo.version))
  if existsDir(pkgDestDir):
    if not prompt(pkgInfo.name & " already exists. Overwrite?"):
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
  let paths = processDeps(pkginfo)
  
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
      when defined(unix):
        if existsFile(binDir / bin): removeFile(binDir / bin)
        echo("Creating symlink: ", pkgDestDir / bin, " -> ", binDir / bin)
        doCmd("ln -s \"" & pkgDestDir / bin & "\" " & binDir / bin)
      elif defined(windows):
        let dest = binDir / bin.changeFileExt("bat")
        echo("Creating stub: ", pkgDestDir / bin, " -> ", dest)
        writeFile(dest, "\"" & pkgDestDir / bin & "\" %*\n")
      else:
        {.error: "Sorry, your platform is not supported.".}
  else:
    copyFilesRec(realDir, realDir, pkgDestDir, pkgInfo)
  result = pkgDestDir

  echo(pkgInfo.name & " installed successfully.")

proc downloadPkg(pkg: TPackage, verRange: PVersionRange): string =
  let downloadDir = (getTempDir() / "babel" / pkg.name)
  if not existsDir(getTempDir() / "babel"): createDir(getTempDir() / "babel")
  echo("Downloading ", pkg.name, " into ", downloadDir, "...")
  doDownload(pkg, downloadDir, verRange)
    
  result = downloadDir

proc install(packages: seq[String], verRange: PVersionRange): string =
  if packages == @[]:
    result = installFromDir(getCurrentDir(), false)
  else:
    if not existsFile(babelDir / "packages.json"):
      if prompt("Local packages.json not found, download it from internet?"):
          update()
          install(packages, verRange)
      else:
        quit("Please run babel update.", QuitFailure)
    for p in packages:
      var pkg: TPackage
      if getPackage(p, babelDir / "packages.json", pkg):
        let downloadDir = downloadPkg(pkg, verRange)
        result = installFromDir(downloadDir, false)
      else:
        if didUpdatePackages == false and prompt(p & " not found in local packages.json, check internet for updated packages?"):
          update()
          install(@[p], verRange)
        else:
            raise newException(EBabel, "Package not found.")

proc build =
  var pkgInfo = getPkgInfo(getCurrentDir())
  let paths = processDeps(pkginfo)
  buildFromDir(pkgInfo, paths)

proc search(action: TAction) =
  assert action.typ == ActionSearch
  if action.search == @[]:
    quit("Please specify a search string.", QuitFailure)
  if not existsFile(babelDir / "packages.json"):
    quit("Please run babel update.", QuitFailure)
  let pkgList = getPackageList(babelDir / "packages.json")
  var notFound = true
  for pkg in pkgList:
    for word in action.search:
      if word in pkg.tags:
        echoPackage(pkg)
        echo(" ")
        notFound = false
        break
  if notFound:
    # Search by name.
    for pkg in pkgList:
      for word in action.search:
        if word in pkg.name:
          echoPackage(pkg)
          echo(" ")
          notFound = false

  if notFound:
    echo("No package found.")

proc list =
  if not existsFile(babelDir / "packages.json"):
    quit("Please run babel update.", QuitFailure)
  let pkgList = getPackageList(babelDir / "packages.json")
  for pkg in pkgList:
    echoPackage(pkg)
    echo(" ")

type VersionAndPath = tuple[version: TVersion, path: string]

proc listPaths(packages: seq[String]) =
  ## Loops over installing packages displaying their installed paths.
  ##
  ## If there are several pacakges installed, only the last one (the version
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
      echo "FAILURE: Package '" & name & "' not installed"
      errors += 1
  if errors > 0:
    quit("FAILURE: At least one specified package was not found", QuitFailure)

proc doAction(action: TAction) =
  case action.typ
  of ActionUpdate:
    if action.optionalURL != "":
      update(action.optionalURL)
    else:
      update()
  of ActionInstall:
    # TODO: Allow user to specify version.
    install(action.optionalName, PVersionRange(kind: verAny))
  of ActionSearch:
    search(action)
  of ActionList:
    list()
  of ActionPath:
    listPaths(action.optionalName)
  of ActionBuild:
    build()
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
