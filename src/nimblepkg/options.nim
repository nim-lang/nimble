# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import json, strutils, os, parseopt, strtabs, uri, tables, terminal
import sequtils, sugar
import std/options as std_opt
from httpclient import Proxy, newProxy

import config, version, common, cli

type
  Options* = object
    forcePrompts*: ForcePrompt
    depsOnly*: bool
    uninstallRevDeps*: bool
    queryVersions*: bool
    queryInstalled*: bool
    nimbleDir*: string
    verbosity*: cli.Priority
    action*: Action
    config*: Config
    nimbleData*: JsonNode ## Nimbledata.json
    pkgInfoCache*: TableRef[string, PackageInfo]
    showHelp*: bool
    showVersion*: bool
    noColor*: bool
    disableValidation*: bool
    continueTestsOnFailure*: bool
    ## Whether packages' repos should always be downloaded with their history.
    forceFullClone*: bool
    # Temporary storage of flags that have not been captured by any specific Action.
    unknownFlags*: seq[(CmdLineKind, string, string)]

  ActionType* = enum
    actionNil, actionRefresh, actionInit, actionDump, actionPublish,
    actionInstall, actionSearch,
    actionList, actionBuild, actionPath, actionUninstall, actionCompile,
    actionDoc, actionCustom, actionTasks, actionDevelop, actionCheck,
    actionRun

  Action* = object
    case typ*: ActionType
    of actionNil, actionList, actionPublish, actionTasks, actionCheck: nil
    of actionRefresh:
      optionalURL*: string # Overrides default package list.
    of actionInstall, actionPath, actionUninstall, actionDevelop:
      packages*: seq[PkgTuple] # Optional only for actionInstall
                               # and actionDevelop.
      passNimFlags*: seq[string]
    of actionSearch:
      search*: seq[string] # Search string.
    of actionInit, actionDump:
      projName*: string
      vcsOption*: string
    of actionCompile, actionDoc, actionBuild:
      file*: string
      backend*: string
      compileOptions: seq[string]
    of actionRun:
      runFile: Option[string]
      compileFlags: seq[string]
      runFlags*: seq[string]
    of actionCustom:
      command*: string
      arguments*: seq[string]
      flags*: StringTableRef

const
  help* = """
Usage: nimble COMMAND [opts]

Commands:
  install      [pkgname, ...]     Installs a list of packages.
               [-d, --depsOnly]   Install only dependencies.
               [-p, --passNim]    Forward specified flag to compiler.
  develop      [pkgname, ...]     Clones a list of packages for development.
                                  Symlinks the cloned packages or any package
                                  in the current working directory.
  check                           Verifies the validity of a package in the
                                  current working directory.
  init         [pkgname]          Initializes a new Nimble project in the
                                  current directory or if a name is provided a
                                  new directory of the same name.
               --git
               --hg               Create a git or hg repo in the new nimble project.
  publish                         Publishes a package on nim-lang/packages.
                                  The current working directory needs to be the
                                  toplevel directory of the Nimble package.
  uninstall    [pkgname, ...]     Uninstalls a list of packages.
               [-i, --inclDeps]   Uninstall package and dependent package(s).
  build        [opts, ...] [bin]  Builds a package.
  run          [opts, ...] [bin]  Builds and runs a package.
                                  Binary needs to be specified after any
                                  compilation options if there are several
                                  binaries defined, any flags after the binary
                                  or -- arg are passed to the binary when it is run.
  c, cc, js    [opts, ...] f.nim  Builds a file inside a package. Passes options
                                  to the Nim compiler.
  test                            Compiles and executes tests
               [-c, --continue]   Don't stop execution on a failed test.
  doc, doc2    [opts, ...] f.nim  Builds documentation for a file inside a
                                  package. Passes options to the Nim compiler.
  refresh      [url]              Refreshes the package list. A package list URL
                                  can be optionally specified.
  search       pkg/tag            Searches for a specified package. Search is
                                  performed by tag and by name.
               [--ver]            Query remote server for package version.
  list                            Lists all packages.
               [--ver]            Query remote server for package version.
               [-i, --installed]  Lists all installed packages.
  tasks                           Lists the tasks specified in the Nimble
                                  package's Nimble file.
  path         pkgname ...        Shows absolute path to the installed packages
                                  specified.
  dump         [pkgname]          Outputs Nimble package information for
                                  external tools. The argument can be a
                                  .nimble file, a project directory or
                                  the name of an installed package.


Options:
  -h, --help                      Print this help message.
  -v, --version                   Print version information.
  -y, --accept                    Accept all interactive prompts.
  -n, --reject                    Reject all interactive prompts.
      --ver                       Query remote server for package version
                                  information when searching or listing packages
      --nimbleDir:dirname         Set the Nimble directory.
      --verbose                   Show all non-debug output.
      --debug                     Show all output including debug messages.
      --noColor                   Don't colorise output.

For more information read the Github readme:
  https://github.com/nim-lang/nimble#readme
"""

const noHookActions* = {actionCheck}

proc writeHelp*(quit=true) =
  echo(help)
  if quit:
    raise NimbleQuit(msg: "")

proc writeVersion*() =
  echo("nimble v$# compiled at $# $#" %
      [nimbleVersion, CompileDate, CompileTime])
  const execResult = gorgeEx("git rev-parse HEAD")
  when execResult[0].len > 0 and execResult[1] == QuitSuccess:
    echo "git hash: ", execResult[0]
  else:
    {.warning: "Couldn't determine GIT hash: " & execResult[0].}
    echo "git hash: couldn't determine git hash"
  raise NimbleQuit(msg: "")

proc parseActionType*(action: string): ActionType =
  case action.normalize()
  of "install":
    result = actionInstall
  of "path":
    result = actionPath
  of "build":
    result = actionBuild
  of "run":
    result = actionRun
  of "c", "compile", "js", "cpp", "cc":
    result = actionCompile
  of "doc", "doc2":
    result = actionDoc
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
  of "develop":
    result = actionDevelop
  of "check":
    result = actionCheck
  else:
    result = actionCustom

proc initAction*(options: var Options, key: string) =
  ## Intialises `options.actions` fields based on `options.actions.typ` and
  ## `key`.
  let keyNorm = key.normalize()
  case options.action.typ
  of actionInstall, actionPath, actionDevelop, actionUninstall:
    options.action.packages = @[]
    options.action.passNimFlags = @[]
  of actionCompile, actionDoc, actionBuild:
    options.action.compileOptions = @[]
    options.action.file = ""
    if keyNorm == "c" or keyNorm == "compile": options.action.backend = ""
    else: options.action.backend = keyNorm
  of actionInit:
    options.action.projName = ""
    options.action.vcsOption = ""
  of actionDump:
    options.action.projName = ""
    options.action.vcsOption = ""
    options.forcePrompts = forcePromptYes
  of actionRefresh:
    options.action.optionalURL = ""
  of actionSearch:
    options.action.search = @[]
  of actionCustom:
    options.action.command = key
    options.action.arguments = @[]
    options.action.flags = newStringTable()
  of actionPublish, actionList, actionTasks, actionCheck, actionRun,
     actionNil: discard

proc prompt*(options: Options, question: string): bool =
  ## Asks an interactive question and returns the result.
  ##
  ## The proc will return immediately without asking the user if the global
  ## forcePrompts has a value different than dontForcePrompt.
  return prompt(options.forcePrompts, question)

proc promptCustom*(options: Options, question, default: string): string =
  ## Asks an interactive question and returns the result.
  ##
  ## The proc will return "default" without asking the user if the global
  ## forcePrompts is forcePromptYes.
  return promptCustom(options.forcePrompts, question, default)

proc promptList*(options: Options, question: string, args: openarray[string]): string =
  ## Asks an interactive question and returns the result.
  ##
  ## The proc will return one of the provided args. If not prompting the first
  ## options is selected.
  return promptList(options.forcePrompts, question, args)

proc getNimbleDir*(options: Options): string =
  result = options.config.nimbleDir
  if options.nimbleDir.len != 0:
    # --nimbleDir:<dir> takes priority...
    result = options.nimbleDir
  else:
    # ...followed by the environment variable.
    let env = getEnv("NIMBLE_DIR")
    if env.len != 0:
      display("Warning:", "Using the environment variable: NIMBLE_DIR='" &
                        env & "'", Warning)
      result = env

  return expandTilde(result)

proc getPkgsDir*(options: Options): string =
  options.getNimbleDir() / "pkgs"

proc getBinDir*(options: Options): string =
  options.getNimbleDir() / "bin"

proc parseCommand*(key: string, result: var Options) =
  result.action = Action(typ: parseActionType(key))
  initAction(result, key)

proc setRunOptions(result: var Options, key, val: string, isArg: bool) =
  if result.action.runFile.isNone() and (isArg or val == "--"):
    result.action.runFile = some(key)
  else:
    result.action.runFlags.add(val)

proc parseArgument*(key: string, result: var Options) =
  case result.action.typ
  of actionNil:
    assert false
  of actionInstall, actionPath, actionDevelop, actionUninstall:
    # Parse pkg@verRange
    if '@' in key:
      let i = find(key, '@')
      let (pkgName, pkgVer) = (key[0 .. i-1], key[i+1 .. key.len-1])
      if pkgVer.len == 0:
        raise newException(NimbleError, "Version range expected after '@'.")
      result.action.packages.add((pkgName, pkgVer.parseVersionRange()))
    else:
      result.action.packages.add((key, VersionRange(kind: verAny)))
  of actionRefresh:
    result.action.optionalURL = key
  of actionSearch:
    result.action.search.add(key)
  of actionInit, actionDump:
    if result.action.projName != "":
      raise newException(
        NimbleError, "Can only perform this action on one package at a time."
      )
    result.action.projName = key
  of actionCompile, actionDoc:
    result.action.file = key
  of actionList, actionPublish:
    result.showHelp = true
  of actionBuild:
    result.action.file = key
  of actionRun:
    result.setRunOptions(key, key, true)
  of actionCustom:
    result.action.arguments.add(key)
  else:
    discard

proc getFlagString(kind: CmdLineKind, flag, val: string): string =
  let prefix =
    case kind
    of cmdShortOption: "-"
    of cmdLongOption: "--"
    else: ""
  if val == "":
    return prefix & flag
  else:
    return prefix & flag & ":" & val

proc parseFlag*(flag, val: string, result: var Options, kind = cmdLongOption) =

  let f = flag.normalize()

  # Global flags.
  var isGlobalFlag = true
  case f
  of "help", "h": result.showHelp = true
  of "version", "v": result.showVersion = true
  of "accept", "y": result.forcePrompts = forcePromptYes
  of "reject", "n": result.forcePrompts = forcePromptNo
  of "nimbledir": result.nimbleDir = val
  of "verbose": result.verbosity = LowPriority
  of "debug": result.verbosity = DebugPriority
  of "nocolor": result.noColor = true
  of "disablevalidation": result.disableValidation = true
  else: isGlobalFlag = false

  var wasFlagHandled = true
  # Action-specific flags.
  case result.action.typ
  of actionSearch, actionList:
    case f
    of "installed", "i":
      result.queryInstalled = true
    of "ver":
      result.queryVersions = true
    else:
      wasFlagHandled = false
  of actionInstall:
    case f
    of "depsonly", "d":
      result.depsOnly = true
    of "passnim", "p":
      result.action.passNimFlags.add(val)
    else:
      wasFlagHandled = false
  of actionInit:
    case f
    of "git", "hg":
      result.action.vcsOption = f
    else:
      wasFlagHandled = false
  of actionUninstall:
    case f
    of "incldeps", "i":
      result.uninstallRevDeps = true
    else:
      wasFlagHandled = false
  of actionCompile, actionDoc, actionBuild:
    if not isGlobalFlag:
      result.action.compileOptions.add(getFlagString(kind, flag, val))
  of actionRun:
    result.showHelp = false
    result.setRunOptions(flag, getFlagString(kind, flag, val), false)
  of actionCustom:
    if result.action.command.normalize == "test":
      if f == "continue" or f == "c":
        result.continueTestsOnFailure = true
    result.action.flags[flag] = val
  else:
    wasFlagHandled = false

  if not wasFlagHandled and not isGlobalFlag:
    result.unknownFlags.add((kind, flag, val))

proc initOptions*(): Options =
  # Exported for choosenim
  Options(
    action: Action(typ: actionNil),
    pkgInfoCache: newTable[string, PackageInfo](),
    verbosity: HighPriority,
    noColor: not isatty(stdout)
  )

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

proc handleUnknownFlags(options: var Options) =
  if options.action.typ == actionRun:
    # ActionRun uses flags that come before the command as compilation flags
    # and flags that come after as run flags.
    options.action.compileFlags =
      map(options.unknownFlags, x => getFlagString(x[0], x[1], x[2]))
    options.unknownFlags = @[]
  else:
    # For everything else, handle the flags that came before the command
    # normally.
    let unknownFlags = options.unknownFlags
    options.unknownFlags = @[]
    for flag in unknownFlags:
      parseFlag(flag[1], flag[2], options, flag[0])

  # Any unhandled flags?
  if options.unknownFlags.len > 0:
    let flag = options.unknownFlags[0]
    raise newException(
      NimbleError,
      "Unknown option: " & getFlagString(flag[0], flag[1], flag[2])
    )

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
        parseFlag(key, val, result, kind)
    of cmdEnd: assert(false) # cannot happen

  handleUnknownFlags(result)

  # Set verbosity level.
  setVerbosity(result.verbosity)

  # Set whether color should be shown.
  setShowColor(not result.noColor)

  # Parse config.
  result.config = parseConfig()

  # Parse other things, for example the nimbledata.json file.
  parseMisc(result)

  if result.action.typ == actionNil and not result.showVersion:
    result.showHelp = true

  if result.action.typ != actionNil and result.showVersion:
    # We've got another command that should be handled. For example:
    # nimble run foobar -v
    result.showVersion = false

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
      elif existsEnv("HTTP_PROXY"):
        url = getEnv("HTTP_PROXY")
      elif existsEnv("HTTPS_PROXY"):
        url = getEnv("HTTPS_PROXY")
    except ValueError:
      display("Warning:", "Unable to parse proxy from environment: " &
          getCurrentExceptionMsg(), Warning, HighPriority)

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

proc briefClone*(options: Options): Options =
  ## Clones the few important fields and creates a new Options object.
  var newOptions = initOptions()
  newOptions.config = options.config
  newOptions.nimbleData = options.nimbleData
  newOptions.nimbleDir = options.nimbleDir
  newOptions.forcePrompts = options.forcePrompts
  newOptions.pkgInfoCache = options.pkgInfoCache
  return newOptions

proc shouldRemoveTmp*(options: Options, file: string): bool =
  result = true
  if options.verbosity <= DebugPriority:
    let msg = "Not removing temporary path because of debug verbosity: " & file
    display("Warning:", msg, Warning, MediumPriority)
    return false

proc getCompilationFlags*(options: var Options): var seq[string] =
  case options.action.typ
  of actionBuild, actionDoc, actionCompile:
    return options.action.compileOptions
  of actionRun:
    return options.action.compileFlags
  else:
    assert false

proc getCompilationFlags*(options: Options): seq[string] =
  var opt = options
  return opt.getCompilationFlags()

proc getCompilationBinary*(options: Options, pkgInfo: PackageInfo): Option[string] =
  case options.action.typ
  of actionBuild, actionDoc, actionCompile:
    let file = options.action.file.changeFileExt("")
    if file.len > 0:
      return some(file)
  of actionRun:
    let optRunFile = options.action.runFile
    let runFile =
      if optRunFile.get("").len > 0:
        optRunFile.get()
      elif pkgInfo.bin.len == 1:
        pkgInfo.bin[0]
      else:
        ""

    if runFile.len > 0:
      return some(runFile.changeFileExt(ExeExt))
  else:
    discard
