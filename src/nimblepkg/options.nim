# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import json, strutils, os, parseopt, strtabs, uri, tables
from httpclient import Proxy, newProxy

import config, version, tools, common, cli

type
  Options* = object
    forcePrompts*: ForcePrompt
    depsOnly*: bool
    queryVersions*: bool
    queryInstalled*: bool
    nimbleDir*: string
    verbosity*: cli.Priority
    action*: Action
    config*: Config
    nimbleData*: JsonNode ## Nimbledata.json
    pkgInfoCache*: TableRef[string, PackageInfo]

  ActionType* = enum
    actionNil, actionRefresh, actionInit, actionDump, actionPublish,
    actionInstall, actionSearch,
    actionList, actionBuild, actionPath, actionUninstall, actionCompile,
    actionCustom, actionTasks

  Action* = object
    case typ*: ActionType
    of actionNil, actionList, actionBuild, actionPublish, actionTasks: nil
    of actionRefresh:
      optionalURL*: string # Overrides default package list.
    of actionInstall, actionPath, actionUninstall:
      packages*: seq[PkgTuple] # Optional only for actionInstall.
    of actionSearch:
      search*: seq[string] # Search string.
    of actionInit, actionDump:
      projName*: string
    of actionCompile:
      file*: string
      backend*: string
      compileOptions*: seq[string]
    of actionCustom:
      command*: string
      arguments*: seq[string]
      flags*: StringTableRef

  ForcePrompt* = enum
    dontForcePrompt, forcePromptYes, forcePromptNo


const
  help* = """
Usage: nimble COMMAND [opts]

Commands:
  install      [pkgname, ...]     Installs a list of packages.
  init         [pkgname]          Initializes a new Nimble project.
  publish                         Publishes a package on nim-lang/packages.
                                  The current working directory needs to be the
                                  toplevel directory of the Nimble package.
  uninstall    [pkgname, ...]     Uninstalls a list of packages.
  build                           Builds a package.
  c, cc, js    [opts, ...] f.nim  Builds a file inside a package. Passes options
                                  to the Nim compiler.
  refresh      [url]              Refreshes the package list. A package list URL
                                  can be optionally specified.
  search       [--ver] pkg/tag    Searches for a specified package. Search is
                                  performed by tag and by name.
  list         [--ver]            Lists all packages.
               [-i, --installed]  Lists all installed packages.
  tasks                           Lists the tasks specified in the Nimble
                                  package's Nimble file.
  path         pkgname ...        Shows absolute path to the installed packages
                                  specified.
  dump         [pkgname]          Outputs Nimble package information for
                                  external tools.

Options:
  -h, --help                      Print this help message.
  -v, --version                   Print version information.
  -y, --accept                    Accept all interactive prompts.
  -n, --reject                    Reject all interactive prompts.
      --ver                       Query remote server for package version
                                  information when searching or listing packages
      --nimbleDir dirname         Set the Nimble directory.
  -d  --depsOnly                  Install only dependencies.
      --verbose                   Show all output.

For more information read the Github readme:
  https://github.com/nim-lang/nimble#readme
"""

proc writeHelp*() =
  echo(help)
  quit(QuitSuccess)

proc writeVersion() =
  echo("nimble v$# compiled at $# $#" %
      [nimbleVersion, CompileDate, CompileTime])
  quit(QuitSuccess)

proc parseActionType*(action: string): ActionType =
  case action.normalize()
  of "install", "path":
    case action.normalize()
    of "install":
      result = actionInstall
    of "path":
      result = actionPath
    else:
      discard
  of "build":
    result = actionBuild
  of "c", "compile", "js", "cpp", "cc":
    result = actionCompile
  of "init":
    result = actionInit
  of "dump":
    result = actionDump
  of "update", "refresh":
    result = actionRefresh
  of "search":
    result = actionSearch
  of "list":
    result = actionList
  of "uninstall", "remove", "delete", "del", "rm":
    result = actionUninstall
  of "publish":
    result = actionPublish
  of "tasks":
    result = actionTasks
  else:
    result = actionCustom

proc initAction*(options: var Options, key: string) =
  ## Intialises `options.actions` fields based on `options.actions.typ` and
  ## `key`.
  let keyNorm = key.normalize()
  case options.action.typ
  of actionInstall, actionPath:
    options.action.packages = @[]
  of actionCompile:
    options.action.compileOptions = @[]
    options.action.file = ""
    if keyNorm == "c" or keyNorm == "compile": options.action.backend = ""
    else: options.action.backend = keyNorm
  of actionInit:
    options.action.projName = ""
  of actionDump:
    options.action.projName = ""
  of actionRefresh:
    options.action.optionalURL = ""
  of actionSearch:
    options.action.search = @[]
  of actionUninstall:
    options.action.packages = @[]
  of actionCustom:
    options.action.command = key
    options.action.arguments = @[]
    options.action.flags = newStringTable()
  of actionBuild, actionPublish, actionList, actionTasks,
     actionNil: discard

proc prompt*(options: Options, question: string): bool =
  ## Asks an interactive question and returns the result.
  ##
  ## The proc will return immediately without asking the user if the global
  ## forcePrompts has a value different than dontForcePrompt.
  case options.forcePrompts
  of forcePromptYes:
    echo(question & " -> [forced yes]")
    return true
  of forcePromptNo:
    echo(question & " -> [forced no]")
    return false
  of dontForcePrompt:
    echo(question & " [y/N]")
    let yn = stdin.readLine()
    case yn.normalize
    of "y", "yes":
      return true
    of "n", "no":
      return false
    else:
      return false

proc renameBabelToNimble(options: Options) {.deprecated.} =
  let babelDir = getHomeDir() / ".babel"
  let nimbleDir = getHomeDir() / ".nimble"
  if dirExists(babelDir):
    if options.prompt("Found deprecated babel package directory, would you " &
        "like to rename it to nimble?"):
      copyDir(babelDir, nimbleDir)
      copyFile(babelDir / "babeldata.json", nimbleDir / "nimbledata.json")

      removeDir(babelDir)
      removeFile(nimbleDir / "babeldata.json")

proc getNimbleDir*(options: Options): string =
  result =
    if options.nimbleDir.len == 0:
      options.config.nimbleDir
    else:
      options.nimbleDir

  return expandTilde(result)

proc getPkgsDir*(options: Options): string =
  options.getNimbleDir() / "pkgs"

proc getBinDir*(options: Options): string =
  options.getNimbleDir() / "bin"

proc parseCommand*(key: string, result: var Options) =
  result.action.typ = parseActionType(key)
  initAction(result, key)

proc parseArgument*(key: string, result: var Options) =
  case result.action.typ
  of actionNil:
    assert false
  of actionInstall, actionPath, actionUninstall:
    # Parse pkg@verRange
    if '@' in key:
      let i = find(key, '@')
      let pkgTup = (key[0 .. i-1],
        key[i+1 .. key.len-1].parseVersionRange())
      result.action.packages.add(pkgTup)
    else:
      result.action.packages.add((key, VersionRange(kind: verAny)))
  of actionRefresh:
    result.action.optionalURL = key
  of actionSearch:
    result.action.search.add(key)
  of actionInit, actionDump:
    if result.action.projName != "":
      raise newException(NimbleError,
          "Can only initialize one package at a time.")
    result.action.projName = key
  of actionCompile:
    result.action.file = key
  of actionList, actionBuild, actionPublish:
    writeHelp()
  of actionCustom:
    result.action.arguments.add(key)
  else:
    discard

proc parseFlag*(flag, val: string, result: var Options) =
  case result.action.typ
  of actionCompile:
    if val == "":
      result.action.compileOptions.add("--" & flag)
    else:
      result.action.compileOptions.add("--" & flag & ":" & val)
  of actionCustom:
    result.action.flags[flag] = val
  else:
    # TODO: These should not be global.
    case flag.normalize()
    of "help", "h": writeHelp()
    of "version", "v": writeVersion()
    of "accept", "y": result.forcePrompts = forcePromptYes
    of "reject", "n": result.forcePrompts = forcePromptNo
    of "ver": result.queryVersions = true
    of "nimbledir": result.nimbleDir = val
    of "installed", "i": result.queryInstalled = true
    of "depsonly", "d": result.depsOnly = true
    of "verbose": result.verbosity = LowPriority
    else:
      raise newException(NimbleError, "Unknown option: --" & flag)

proc initOptions*(): Options =
  result.action.typ = actionNil
  result.pkgInfoCache = newTable[string, PackageInfo]()
  result.nimbleDir = ""
  result.verbosity = HighPriority

proc parseMisc(options: var Options) =
  # Load nimbledata.json
  let nimbledataFilename = options.getNimbleDir() / "nimbledata.json"

  if fileExists(nimbledataFilename):
    try:
      options.nimbleData = parseFile(nimbledataFilename)
    except:
      raise newException(NimbleError, "Couldn't parse nimbledata.json file " &
          "located at " & nimbledataFilename)
  else:
    options.nimbleData = %{"reverseDeps": newJObject()}

proc parseCmdLine*(): Options =
  result = initOptions()

  # Parse command line params first. A simple `--version` shouldn't require
  # a config to be parsed.
  for kind, key, val in getOpt():
    case kind
    of cmdArgument:
      if result.action.typ == actionNil:
        parseCommand(key, result)
      else:
        parseArgument(key, result)
    of cmdLongOption, cmdShortOption:
      parseFlag(key, val, result)
    of cmdEnd: assert(false) # cannot happen

  # Set verbosity level.
  setVerbosity(result.verbosity)

  # Parse config.
  result.config = parseConfig()

  # Parse other things, for example the nimbledata.json file.
  parseMisc(result)

  if result.action.typ == actionNil:
    writeHelp()

proc getProxy*(options: Options): Proxy =
  ## Returns ``nil`` if no proxy is specified.
  var url = ""
  if ($options.config.httpProxy).len > 0:
    url = $options.config.httpProxy
  else:
    try:
      if existsEnv("http_proxy"):
        url = getEnv("http_proxy")
      elif existsEnv("https_proxy"):
        url = getEnv("https_proxy")
    except ValueError:
      echo("WARNING: Unable to parse proxy from environment: ",
          getCurrentExceptionMsg())

  if url.len > 0:
    var parsed = parseUri(url)
    if parsed.scheme.len == 0 or parsed.hostname.len == 0:
      parsed = parseUri("http://" & url)
    let auth =
      if parsed.username.len > 0: parsed.username & ":" & parsed.password
      else: ""
    return newProxy($parsed, auth)
  else:
    return nil
