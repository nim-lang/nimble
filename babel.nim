# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import httpclient, parseopt, os, strutils, osproc, pegs, tables, parseutils

import packageinfo, version

type
  TActionType = enum
    ActionNil, ActionUpdate, ActionInstall, ActionSearch, ActionList, ActionBuild

  TAction = object
    case typ: TActionType
    of ActionNil, ActionList, ActionBuild: nil
    of ActionUpdate:
      optionalURL: string # Overrides default package list.
    of ActionInstall:
      optionalName: seq[string] # When this is @[], installs package from current dir.
    of ActionSearch:
      search: seq[string] # Search string.
  
  EBabel = object of EBase

const
  help = """
Usage: babel COMMAND [opts]

Commands:
  install        Installs a list of packages.
  build          Builds a package.
  update         Updates package list. A package list URL can be optionally specificed.
  search         Searches for a specified package.
  list           Lists all packages.
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
        of ActionList, ActionBuild:
          writeHelp()
    of cmdLongOption, cmdShortOption:
      case key
      of "help", "h": writeHelp()
      of "version", "v": writeVersion()
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

proc getNimrodVersion: TVersion =
  let vOutput = execProcess("nimrod -v")
  var matches: array[0..MaxSubpatterns, string]
  if vOutput.find(peg"'Version'\s{(\d\.)+\d}", matches) == -1:
    quit("Couldn't find Nimrod version.", QuitFailure)
  newVersion(matches[0])

let babelDir = getHomeDir() / ".babel"
let libsDir = babelDir / "libs"
let binDir = babelDir / "bin"
let nimVer = getNimrodVersion()

proc update(url: string = defaultPackageURL) =
  echo("Downloading package list from " & url)
  downloadFile(url, babelDir / "packages.json")
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

proc doCmd(cmd: string) =
  let exitCode = execCmd(cmd)
  if exitCode != QuitSuccess:
    quit("Execution failed with exit code " & $exitCode, QuitFailure)

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
      for ignoreFile in pkgInfo.skipFiles:
        if ignoreFile.endswith("babel"):
          quit(ignoreFile & " must be installed.")
        if samePaths(file, origDir / ignoreFile):
          skip = true
          break
      
      if not skip:
        copyFileD(file, changeRoot(origDir, dest, file)) 

proc getPkgInfo(dir: string): TPackageInfo =
  let babelFile = findBabelFile(dir)
  if babelFile == "":
    quit("Specified directory does not contain a .babel file.", QuitFailure)
  result = readPackageInfo(babelFile)

# TODO: Move to packageinfo.nim

proc getInstalledPkgs(): seq[tuple[path: string, info: TPackageInfo]] =
  ## Gets a list of installed packages
  result = @[]
  for kind, path in walkDir(libsDir):
    if kind == pcDir:
      let babelFile = findBabelFile(path)
      if babelFile != "":
        result.add((path, readPackageInfo(babelFile)))
      else:
        # TODO: Abstract logging.
        echo("WARNING: No .babel file found for ", path)

proc findPkg(pkglist: seq[tuple[path: string, info: TPackageInfo]],
             dep: tuple[name: string, ver: PVersionRange],
             r: var tuple[path: string, info: TPackageInfo]): bool =
  for pkg in pkglist:
    if pkg.info.name != dep.name: continue
    if withinRange(newVersion(pkg.info.version), dep.ver):
      if not result or newVersion(r.info.version) < newVersion(pkg.info.version):
        r = pkg
        result = true

proc install(packages: seq[String], verRange: PVersionRange): string {.discardable.}
proc processDeps(pkginfo: TPackageInfo): seq[string] =
  ## Verifies and installs dependencies.
  ##
  ## Returns the list of paths to pass to the compiler during build phase.
  result = @[]
  let pkglist = getInstalledPkgs()
  for dep in pkginfo.requires:
    if dep.name == "nimrod":
      if not withinRange(nimVer, dep.ver):
        quit("Unsatisfied dependency: " & dep.name & " (" & $dep.ver & ")")
    else:
      echo("Looking for ", dep.name, " (", $dep.ver, ")...")
      var pkg: tuple[path: string, info: TPackageInfo]
      if not findPkg(pkglist, dep, pkg):
        let dest = install(@[dep.name], dep.ver)
        if dest != "":
          # only add if not a binary package
          result.add(dest)
      else:
        echo("Dependency already satisfied.")
        if pkg.info.bin.len == 0:
          result.add(pkg.path)

proc buildFromDir(dir: string, paths: seq[string]) =
  ## Builds a package which resides in ``dir``
  var pkgInfo = getPkgInfo(dir)
  var args = ""
  for path in paths: args.add("--path:" & path & " ")
  for bin in pkgInfo.bin:
    echo("Building ", pkginfo.name, "/", bin, "...")
    echo(args)
    doCmd("nimrod c -d:release " & args & dir / bin)

proc installFromDir(dir: string, latest: bool): string =
  ## Returns where package has been installed to. If package is a binary,
  ## ``""`` is returned.
  var pkgInfo = getPkgInfo(dir)
  let pkgDestDir = libsDir / (pkgInfo.name &
                   (if latest: "" else: '-' & pkgInfo.version))
  if existsDir(pkgDestDir):
    if not prompt("Package already exists. Overwrite?"):
      quit(QuitSuccess)
    removeDir(pkgDestDir)
  
  echo("Installing ", pkginfo.name, "-", pkginfo.version)
  
  # Dependencies need to be processed before the creation of the pkg dir.
  let paths = processDeps(pkginfo)
  
  createDir(pkgDestDir)
  if pkgInfo.bin.len > 0:
    buildFromDir(dir, paths)
    createDir(binDir)
    for bin in pkgInfo.bin:
      copyFileD(dir / bin, binDir / bin)
      let currentPerms = getFilePermissions(binDir / bin)
      setFilePermissions(binDir / bin, currentPerms + {fpUserExec})
    # Copy the .babel to lib/
    let babelFile = findBabelFile(dir)
    copyFileD(babelFile, changeRoot(dir, pkgDestDir, babelFile))
    result = ""
  else:
    copyFilesRec(dir, dir, pkgDestDir, pkgInfo)
    echo(pkgInfo.name & " installed successfully.")
    result = pkgDestDir

proc getDVCSTag(pkg: TPackage): string =
  result = pkg.dvcsTag
  if result == "":
    result = pkg.version

proc getTagsList(dir: string): seq[string] =
  let output = execProcess("cd \"" & dir & "\" && git tag")
  if output.len > 0:
    result = output.splitLines()
  else:
    result = @[]

proc getVersionList(dir: string): TTable[TVersion, string] =
  # Returns: TTable of version -> git tag name
  result = initTable[TVersion, string]()
  let tags = getTagsList(dir)
  for tag in tags:
    let i = skipUntil(tag, digits) # skip any chars before the version
    # TODO: Better checking, tags can have any names. Add warnings and such.
    result[newVersion(tag[i .. -1])] = tag

proc install(packages: seq[String], verRange: PVersionRange): string =
  if packages == @[]:
    result = installFromDir(getCurrentDir(), false)
  else:
    if not existsFile(babelDir / "packages.json"):
      quit("Please run babel update.", QuitFailure)
    for p in packages:
      var pkg: TPackage
      if getPackage(p, babelDir / "packages.json", pkg):
        let downloadDir = (getTempDir() / "babel" / pkg.name)
        #let dvcsTag = getDVCSTag(pkg)
        case pkg.downloadMethod
        of "git":
          echo("Executing git...")
          if existsDir(downloadDir / ".git"):
            doCmd("cd " & downloadDir & " && git pull")
          else:
            removeDir(downloadDir)
            doCmd("git clone --depth 1 " & pkg.url & " " & downloadDir)
          
          # TODO: Determine if version is a commit hash, if it is. Move the
          # git repo to ``babelDir/libs``, then babel can simply checkout
          # the correct hash instead of constantly cloning and copying.
          let versions = getVersionList(downloadDir)
          if versions.len > 0:
            let latest = findLatest(verRange, versions)
            
            if latest.tag != "":
              doCmd("cd \"" & downloadDir & "\" && git checkout " & latest.tag)
          elif verRange.kind != verAny:
            let pkginfo = getPkgInfo(downloadDir)
            if pkginfo.version.newVersion notin verRange:
              raise newException(EBabel,
                    "No versions of " & pkg.name &
                    " exist (this usually means that `git tag` returned nothing)." &
                    "Git HEAD also does not satisfy version range: " & $verRange)
            # We use GIT HEAD if it satisfies our ver range
            
        else: quit("Unknown download method: " & pkg.downloadMethod, QuitFailure)
        
        result = installFromDir(downloadDir, false)
      else:
        raise newException(EBabel, "Package not found.")

proc build =
  var pkgInfo = getPkgInfo(getCurrentDir())
  let paths = processDeps(pkginfo)
  buildFromDir(getCurrentDir(), paths)

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
    # Search by tag.
    for pkg in pkgList:
      if pkg.name in action.search:
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
  of ActionBuild:
    build()
  of ActionNil:
    assert false

when isMainModule:
  if not existsDir(babelDir):
    createDir(babelDir)
  if not existsDir(libsDir):
    createDir(libsDir)
  
  when defined(release):
    try:
      parseCmdLine().doAction()
    except EBabel:
      quit("FAILURE: " & getCurrentExceptionMsg())
  else:
    parseCmdLine().doAction()
  
  
  
  
