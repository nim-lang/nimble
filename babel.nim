import httpclient, parseopt, os, strutils, osproc

import packageinfo

type
  TActionType = enum
    ActionNil, ActionUpdate, ActionInstall, ActionSearch

  TAction = object
    case typ: TActionType
    of ActionNil: nil
    of ActionUpdate:
      optionalURL: string # Overrides default package list.
    of ActionInstall:
      optionalName: seq[string] # When this is @[], installs package from current dir.
    of ActionSearch:
      search: seq[string] # Search string.
      byTag: bool

const
  help = """
Usage: babel COMMAND [opts]

Commands:
  install        Installs a list of packages.
  update         Updates package list. A package list URL can be optionally specificed.
  search         Searches for a specified package.

Search:
  --tags         Searches by tags, otherwise by name.
"""
  babelVersion = "0.1.0"
  defaultPackageURL = "https://github.com/nimrod-code/packages/raw/master/packages.json"

proc writeHelp() =
  echo(help)
  quit(QuitSuccess)

proc writeVersion() =
  echo(babelVersion)
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
        of "update":
          result.typ = ActionUpdate
          result.optionalURL = ""
        of "search":
          result.typ = ActionSearch
          result.search = @[]
          result.byTag = false
        else: writeHelp()
      else:
        case result.typ
        of ActionNil:
          assert false
        of ActionInstall:
          result.optionalName.add(key)
        of ActionUpdate:
          result.optionalURL = key
        of ActionSearch:
          result.search.add(key)
    of cmdLongOption, cmdShortOption:
      case key
      of "help", "h": writeHelp()
      of "version", "v": writeVersion()
      of "tags", "t":
        case result.typ
        of ActionSearch: result.byTag = true
        else: writeHelp()
    of cmdEnd: assert(false) # cannot happen
  if result.typ == ActionNil:
    writeHelp()

proc prompt(question: string): bool =
  echo(question & " [y/N]")
  let yn = stdin.readLine()
  case yn.normalize
  of "y", "yes":
    return true
  of "n", "no":
    return false
  else:
    return false

proc update(url: string = defaultPackageURL) =
  echo("Downloading package list from " & url)
  downloadFile(url, getHomeDir() / ".babel" / "packages.json")
  echo("Done.")

proc findBabelFile(dir: string): string =
  result = ""
  for kind, path in walkDir(dir):
    if kind == pcFile and path.splitFile.ext == ".babel":
      if result != "": quit("Only one .babel file should be present in " & dir)
      result = path

proc copyFileD(fro, to: string) =
  echo(fro, " -> ", to)
  copyFile(fro, to)

proc getBabelDir: string = return getHomeDir() / ".babel"

proc getLibsDir: string = return getBabelDir() / "libs"

proc samePaths(p1, p2: string): bool =
  ## Normalizes path (by adding a trailing slash) and compares.
  let cp1 = if not p1.endsWith("/"): p1 & "/" else: p1
  let cp2 = if not p2.endsWith("/"): p2 & "/" else: p2
  return cmpPaths(cp1, cp2) == 0

proc changeRoot(origRoot, newRoot, path: string): string =
  ## origRoot: /home/dom/
  ## newRoot:  /home/test/
  ## path:     /home/dom/bar/blah/2/foo.txt
  ## Return value -> /home/test/bar/blah/2/foo.txt
  if path.startsWith(origRoot):
    return newRoot / path[origRoot.len .. -1]
  else:
    raise newException(EInvalidValue,
      "Cannot change root of path: Path does not begin with original root.")

proc copyFilesRec(origDir, currentDir, dest: string, pkgInfo: TPackageInfo) =
  for kind, file in walkDir(currentDir):
    if kind == pcDir:
      var skip = false
      for ignoreDir in pkgInfo.skipDirs:
        if samePaths(file, origDir / ignoreDir):
          skip = true
          break
      let thisDir = splitPath(file).tail 
      assert thisDir != ""
      if thisDir[0] == '.': skip = true
      if thisDir == "nimcache": skip = true
      
      if skip: continue
      # Create the dir.
      createDir(changeRoot(origDir, dest, file))
      
      copyFilesRec(origDir, file, dest, pkgInfo)
    else:
      var skip = false
      if file.splitFile().name[0] == '.': skip = true
      if file.splitFile().ext == "": skip = true
      for ignoreFile in pkgInfo.skipFiles:
        if samePaths(file, origDir / ignoreFile):
          skip = true
          break
      
      if not skip:
        copyFileD(file, changeRoot(origDir, dest, file)) 
      
proc installFromDir(dir: string, latest: bool) =
  let babelFile = findBabelFile(dir)
  if babelFile == "":
    quit("Specified directory does not contain a .babel file.", QuitFailure)
  var pkgInfo = readPackageInfo(babelFile)
  
  let pkgDestDir = getLibsDir() / (pkgInfo.name &
                   (if latest: "" else: '-' & pkgInfo.version))
  if not existsDir(pkgDestDir):
    createDir(pkgDestDir)
  else: 
    if not prompt("Package already exists. Overwrite?"):
      quit(QuitSuccess)
    removeDir(pkgDestDir)
    createDir(pkgDestDir)
  
  copyFilesRec(dir, dir, pkgDestDir, pkgInfo)
  echo(pkgInfo.name & " installed successfully.")

proc doCmd(cmd: string) =
  let exitCode = execCmd(cmd)
  if exitCode != QuitSuccess:
    quit("Execution failed with exit code " & $exitCode, QuitFailure)

proc getDVCSTag(pkg: TPackage): string =
  result = pkg.dvcsTag
  if result == "":
    result = pkg.version

proc install(packages: seq[String]) =
  if packages == @[]:
    installFromDir(getCurrentDir(), false)
  else:
    if not existsFile(getBabelDir() / "packages.json"):
      quit("Please run babel update.", QuitFailure)
    for p in packages:
      var pkg: TPackage
      if getPackage(p, getBabelDir() / "packages.json", pkg):
        let downloadDir = (getTempDir() / "babel" / pkg.name)
        let dvcsTag = getDVCSTag(pkg)
        case pkg.downloadMethod
        of "git":
          echo("Executing git...")
          removeDir(downloadDir)
          doCmd("git clone " & pkg.url & " " & downloadDir)
          if dvcsTag != "":
            doCmd("cd \"" & downloadDir & "\" && git checkout " & dvcsTag)
        else: quit("Unknown download method: " & pkg.downloadMethod, QuitFailure)
        
        installFromDir(downloadDir, dvcsTag == "")
      else:
        quit("Package not found.", QuitFailure)

proc search(action: TAction) =
  assert action.typ == ActionSearch
  if action.search == @[]:
    quit("Please specify a search string.", QuitFailure)
  let pkgList = getPackageList(getBabelDir() / "packages.json")
  var notFound = true
  if action.byTag:
    for pkg in pkgList:
      for word in action.search:
        if word in pkg.tags:
          echoPackage(pkg)
          echo(" ")
          notFound = false
          break
  else:
    for pkg in pkgList:
      if pkg.name in action.search:
        echoPackage(pkg)
        echo(" ")
        notFound = false

  if notFound:
    echo("No package found.")

proc doAction(action: TAction) =
  case action.typ
  of ActionUpdate:
    if action.optionalURL != "":
      update(action.optionalURL)
    else:
      update()
  of ActionInstall:
    install(action.optionalName)
  of ActionSearch:
    search(action)
  of ActionNil:
    assert false

when isMainModule:
  if not existsDir(getHomeDir() / ".babel"):
    createDir(getHomeDir() / ".babel")
  if not existsDir(getHomeDir() / ".babel" / "libs"):
    createDir(getHomeDir() / ".babel" / "libs")
  
  parseCmdLine().doAction()
  
  
  
  
  