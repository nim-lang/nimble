# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import json, strutils, os, parseopt, uri, tables, terminal, osproc, strscans, strformat
import sequtils, sugar
import std/options as std_opt
from httpclient import Proxy, newProxy

import config, version, common, cli, packageinfotypes, displaymessages

const
  nimbledeps* = "nimbledeps"
  defaultLockFileName* = "nimble.lock"
  defaultDevelopPath* = "vendor"

type

  NimBin* = object
    path*: string
    version*: Version

  DumpMode* = enum kdumpIni, kdumpJson

  Options* = object
    forcePrompts*: ForcePrompt
    depsOnly*: bool
    uninstallRevDeps*: bool
    nimbleDir*: string
    verbosity*: cli.Priority
    action*: Action
    config*: Config
    nimbleData*: JsonNode ## Nimbledata.json
    pkgInfoCache*: TableRef[string, PackageInfo]
    showHelp*: bool
    lockFileName*: string
    useSystemNim*: bool
    showVersion*: bool
    offline*: bool
    noColor*: bool
    disableValidation*: bool
    continueTestsOnFailure*: bool
    ## Whether packages' repos should always be downloaded with their history.
    forceFullClone*: bool
    # Temporary storage of flags that have not been captured by any specific Action.
    unknownFlags*: seq[(CmdLineKind, string, string)]
    dumpMode*: DumpMode
    startDir*: string # Current directory on startup - is top level pkg dir for
                      # some commands, useful when processing deps
    nimBin*: Option[NimBin]
    localdeps*: bool # True if project local deps mode
    developLocaldeps*: bool # True if local deps + nimble develop pkg1 ...
    disableSslCertCheck*: bool
    disableLockFile*: bool
    enableTarballs*: bool # Enable downloading of packages as tarballs from GitHub.
    task*: string # Name of the task that is getting ran
    ## Whether to put in develop mode also the dependencies of the packages
    ## listed in the develop command.
    developFile*: string
    package*: string
      # For which package in the dependency tree the command should be executed.
      # If not provided by default it applies to the current directory package.
      # For now, it is used only by the run action and it is ignored by others.
    pkgCachePath*: string # Cache used to store package downloads
    useSatSolver*: bool
    extraRequires*: seq[PkgTuple] # extra requires parsed from the command line
    nimBinariesDir*: string # Directory where nim binaries are stored. Separated from nimbleDir as it can be changed by the user/tests
    disableNimBinaries*: bool # Whether to disable the use of nim binaries
    maxTaggedVersions*: int # Maximum number of tags to check for a package when discovering versions in a local repo
    useDeclarativeParser*: bool # Whether to use the declarative parser for parsing nimble files (only when solver is SAT). A new code path is used when declarative is on.
    features*: seq[string] # Features to be activated. Only used when using the declarative parser
    ignoreSubmodules*: bool # Whether to ignore submodules when cloning a repository
    satResult*: SatResult
    legacy*: bool # Whether to use the legacy code path.

  ActionType* = enum
    actionNil, actionRefresh, actionInit, actionDump, actionPublish, actionUpgrade
    actionInstall, actionSearch, actionList, actionBuild, actionPath,
    actionUninstall, actionCompile, actionDoc, actionCustom, actionTasks,
    actionDevelop, actionCheck, actionLock, actionRun, actionSync, actionSetup,
    actionClean, actionDeps, actionShellEnv, actionShell, actionAdd, actionManual

  DevelopActionType* = enum
    datAdd, datRemoveByPath, datRemoveByName, datInclude, datExclude

  DevelopAction* = tuple[actionType: DevelopActionType, argument: string]

  Action* = object
    case typ*: ActionType
    of actionNil, actionTasks, actionCheck,
       actionSetup, actionClean, actionManual:
      discard
    of actionSync:
      listOnly*: bool
    of actionRefresh:
      optionalURL*: string # Overrides default package list.
    of actionInstall, actionPath, actionUninstall, actionDevelop, actionUpgrade, actionLock, actionAdd:
      packages*: seq[PkgTuple] # Optional only for actionInstall,
                               # actionDevelop and actionAdd.
      passNimFlags*: seq[string]
      devActions*: seq[DevelopAction]
      path*: string
      noRebuild*: bool
      withDependencies*: bool
      global*: bool
    of actionSearch:
      search*: seq[string] # Search string.
      showSearchVersions*: bool
    of actionList:
      onlyNimBinaries*: bool
      onlyInstalled*: bool
      showListVersions*: bool
    of actionInit, actionDump:
      projName*: string
      vcsOption*: string
      collect*: bool
      solve*: bool
    of actionCompile, actionDoc, actionBuild:
      file*: string
      backend*: string
      additionalArguments*: seq[string]
      compileOptions: seq[string]
    of actionRun:
      runFile: Option[string]
      compileFlags: seq[string]
      runFlags*: seq[string]
    of actionCustom:
      command*: string
      arguments*: seq[string]
      custCompileFlags*: seq[string]
      custRunFlags*: seq[string]
    of actionDeps:
      format*: string
      depsAction*: string
    of actionPublish:
      publishAction*: string
    of actionShellEnv, actionShell:
      discard

const
  help* = """
Usage: nimble [nimbleopts] COMMAND [cmdopts]

Commands:
  install      [pkgname, ...]     Installs a list of packages.
               [-d, --depsOnly]   Only install dependencies. Leave out pkgname
                                  to install deps for a local nimble package.
               [-p, --passNim]    Forward specified flag to compiler.
               [--noRebuild ]     Don't rebuild binaries if they're up-to-date.
  develop      [pkgname, ...]     Clones a list of packages for development.
                                  Adds them to a develop file if specified or
                                  to `nimble.develop` if not specified and
                                  executed in package's directory.
         [--withDependencies]     Puts in develop mode also the dependencies
                                  of the packages in the list or of the current
                                  directory package if the list is empty.
         [-p, --path path]        Specifies the path whether the packages should
                                  be cloned.
         [-a, --add path]         Adds a package at given path to a specified
                                  develop file or to `nimble.develop` if not
                                  specified and executed in package's directory.
         [-r, --removePath path]  Removes a package at given path from a
                                  specified develop file or from `nimble.develop`
                                  if not specified and executed in package's
                                  directory.
         [-n, --removeName name]  Removes a package with a given name from
                                  a specified develop file or from `nimble.develop`
                                  if not specified and executed in package's
                                  directory.
         [-i, --include file]     Includes a develop file into a specified
                                  develop file or to `nimble.develop` if not
                                  specified and executed in package's directory.
         [-e, --exclude file]     Excludes a develop file from a specified
                                  develop file or from `nimble.develop` if not
                                  specified and executed in package's directory.
         [-g, --global]           Creates an old style link file in the special
                                  `links` directory. It is read by Nim to be
                                  able to use global develop mode packages.
                                  Nimble uses it as a global develop file if a
                                  local one does not exist.
  check                           Verifies the validity of a package in the
                                  current working directory.
  init         [pkgname]          Initializes a new Nimble project in the
                                  current directory or if a name is provided a
                                  new directory of the same name.
               [--git, --hg]      Creates a git/hg repo in the new nimble project.
  publish                         Publishes a package on nim-lang/packages.
                                  The current working directory needs to be the
                                  top level directory of the Nimble package.
  uninstall    [pkgname, ...]     Uninstalls a list of packages.
               [-i, --inclDeps]   Uninstalls package and dependent package(s).
  build        [opts, ...] [bin]  Builds a package. Passes options to the Nim
                                  compiler.
  clean                           Clean build artifacts.
  guide                           Open the Nimble User Guide in your preferred browser.
  add                             Adds packages to your project's dependencies.
  run          [opts, ...] [bin]  Builds and runs a package.
                                  Binary needs to be specified after any
                                  compilation options if there are several
                                  binaries defined. Any flags after the binary
                                  or -- arg are passed to the binary when it is run.
  c, cc, js    [opts, ...] f.nim  Builds a file inside a package. Passes options
                                  to the Nim compiler.
  test                            Compiles and executes tests.
               [-c, --continue]   Don't stop execution on a failed test.
               [opts, ...]        Passes options to the Nim compiler.
  doc, doc2    [opts, ...] f.nim  Builds documentation for a file inside a
                                  package. Passes options to the Nim compiler.
  refresh      [url]              Refreshes the package list. A package list URL
                                  can be optionally specified.
  search       pkg/tag            Searches for a specified package. Search is
                                  performed by tag and by name.
               [--ver, --version] Queries remote server for package version.
  list                            Lists all packages.
               [-i, --installed]  Lists all installed packages.
               [--ver, --version] Also display versions for packages.
               [-n, --nimbinaries]  Lists all installed packages.
  tasks                           Lists the tasks specified in the Nimble
                                  package's Nimble file.
  path         pkgname ...        Shows absolute path to the installed packages
                                  specified.
  dump         [pkgname]          Outputs Nimble package information for
                                  external tools. The argument can be a
                                  .nimble file, a project directory or
                                  the name of an installed package.
               [--ini, --json]    Selects the output format (the default is --ini). Only applicable to package information.
               [--collect]        Collects all the packages in the dependency tree of the given package and shows the result in the console.
               [--solve]          Solves the dependency tree of the given package and shows the result in the console.
  lock                            Generates or updates a package lock file.
  upgrade      [pkgname, ...]     Upgrades a list of packages in the lock file.
  deps                            Outputs dependencies for current package.
               [--tree]           Outputs dependency tree.
               [--inverted]       Outputs inverted (reversed) dependency tree.
               [--format type]    Specify the output format. Json is the only supported
                                  format. Only some commands support it.
  sync                            Synchronizes develop mode dependencies with
                                  the content of the lock file.
               [-l, --listOnly]   Only lists the packages which are not synced
                                  without actually performing the sync operation.
  setup                           Creates `nimble.paths` file containing file
                                  system paths to the dependencies. Also
                                  includes the paths file in the `config.nims`
                                  file to make them available for the compiler.
  shell                           Creates a new shell with PATH modified to contain
                                  the bin folders of the dependencies.
  shellenv                        Similar to shell command but it returns the script to run in
                                  order to alter the environment. This is intended to be
                                  used in scripts.

Nimble Options:
  -h, --help                      Print this help message.
  -v, --version                   Print version information.
  -y, --accept                    Accept all interactive prompts.
  -n, --reject                    Reject all interactive prompts.
  -l, --localdeps                 Run in project local dependency mode.
  -p, --package                   For which package in the dependency tree the
                                  command should be executed. If not provided by
                                  default it applies to the current directory
                                  package. For now, it is used only by the run
                                  action and it is ignored by others.
  -t, --tarballs                  Enable downloading of packages as tarballs
                                  when working with GitHub repositories.
      --ver                       Query remote server for package version
                                  information when searching or listing packages.
      --nimbleDir:dirname         Set the Nimble directory.
      --nim:path                  Use specified path for Nim compiler.
      --silent                    Hide all Nimble and Nim output.
      --info                      Show some informative output.
      --verbose                   Show extra non-debugging output.
      --debug                     Show all output including debug messages.
      --offline                   Don't use network.
      --noColor                   Don't colorise output.
      --noSslCheck                Don't check SSL certificates.
      --lockFile                  Override the lock file name.
      --noLockfile                Ignore the lock file if present.
      --developFile               Specifies the name of the develop file which
                                  to be manipulated. If not present creates it.
      --useSystemNim              Use system nim and ignore nim from the lock
                                  file if any.
      --solver:sat|legacy         Use the SAT solver (default) or the legacy for dependency resolution.
      --requires                  Add extra packages to the dependency resolution. Uses the same syntax as the Nimble file. Example: nimble install --requires "pkg1; pkg2 >= 1.2".
      --disableNimBinaries        Disable the use of nim precompiled binaries. Note in some platforms precompiled binaries are not available but the flag can still be used to avoid compile the Nim version once and reuse it.
      --maximumTaggedVersions     Maximum number of tags to check for a package when discovering versions for the SAT solver. 0 means all.
      --parser:declarative|nimvm  Use the declarative parser or the nimvm parser (default).
      --features                  Activate features. Only used when using the declarative parser.
      --ignoreSubmodules          Ignore submodules when cloning a repository.
      --legacy                    Use the legacy code path (pre nimble 1.0.0)
For more information read the GitHub readme:
  https://github.com/nim-lang/nimble#readme
"""

const noHookActions* = {actionCheck}
 #Notice some actions dont need to be touched in vnext. Some other partially incercepted (setup) and some others fully changed (i.e build, install)
const vNextSupportedActions* = { actionInstall, actionBuild, 
  actionSetup, actionRun, actionLock, actionCustom, actionSync,
  actionShellEnv, actionShell, actionUpgrade, actionDoc, actionCompile
}
proc writeHelp*(quit=true) =
  echo(help)
  if quit:
    raise nimbleQuit()

const
  ## You can override this if you are building the
  ## sources outside the git tree of Nimble:
  git_revision_override* {.strdefine.} = ""

  gitRevision* = when git_revision_override.len == 0:
    const execResult = gorgeEx("git rev-parse HEAD")
    when execResult[0].len > 0 and execResult[1] == QuitSuccess:
      execResult[0]
    else:
      {.warning: "Couldn't determine GIT hash: " & execResult[0].}
      "couldn't determine git hash"
  else:
    git_revision_override

proc writeVersion*() =
  echo("nimble v$# compiled at $# $#" %
      [nimbleVersion, CompileDate, CompileTime])
  echo "git hash: ", gitRevision
  raise nimbleQuit()

proc parseActionType*(action: string): ActionType =
  case action.normalize()
  of "install":
    result = actionInstall
  of "path":
    result = actionPath
  of "build":
    result = actionBuild
  of "clean":
    result = actionClean
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
  of "upgrade":
    result = actionUpgrade
  of "tasks":
    result = actionTasks
  of "develop":
    result = actionDevelop
  of "check":
    result = actionCheck
  of "lock":
    result = actionLock
  of "deps":
    result = actionDeps
  of "sync":
    result = actionSync
  of "setup":
    result = actionSetup
  of "shellenv":
    result = actionShellEnv
  of "shell":
    result = actionShell
  of "add":
    result = actionAdd
  of "manual", "guide":
    result = actionManual
  else:
    result = actionCustom

proc initAction*(options: var Options, key: string) =
  ## Initialises `options.actions` fields based on `options.actions.typ` and
  ## `key`.
  let keyNorm = key.normalize()
  case options.action.typ
  of actionCompile, actionDoc, actionBuild:
    if keyNorm != "c" and keyNorm != "compile":
      options.action.backend = keyNorm
  of actionDump:
    options.forcePrompts = forcePromptYes
  of actionCustom:
    options.action.command = key
    options.action.arguments = @[]
    options.action.custCompileFlags = @[]
    options.action.custRunFlags = @[]
  else:
    discard

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

proc nim*(options: Options): string =
  if options.nimBin.isNone:
    raise nimbleError(
      "Unable to find `nim` binary - add to $PATH or use `--nim`")
  return options.nimBin.get().path

proc getNimbleDir*(options: Options): string =
  return options.nimbleDir

proc getPkgsDir*(options: Options): string =
  options.getNimbleDir() / nimblePackagesDirName

proc getPkgsLinksDir*(options: Options): string =
  options.getNimbleDir() / nimblePackagesLinksDirName

proc getBinDir*(options: Options): string =
  options.getNimbleDir() / nimbleBinariesDirName

proc setPackageCache(options: var Options, baseDir: string) =
  if options.useSatSolver:
    options.pkgCachePath = baseDir / "pkgcache"
    if options.verbosity >= LowPriority:
      display("Info:", "Package cache path " & options.pkgCachePath, priority = LowPriority)

proc setNimbleDir*(options: var Options) =
  var
    nimbleDir = options.config.nimbleDir
    propagate = false

  if options.action.typ == actionDevelop:
    options.forceFullClone = true

  if (options.localdeps and options.action.typ == actionDevelop and
      options.action.packages.len != 0):
    # Localdeps + nimble develop pkg1 ...
    options.developLocaldeps = true

  if options.nimbleDir.len != 0:
    # --nimbleDir:<dir> takes priority...
    nimbleDir = options.nimbleDir
    propagate = true
    setPackageCache(options, nimbleDir)
  else:
    # ...followed by the environment variable.
    let env = getEnv("NIMBLE_DIR")
    if env.len != 0:
      display("Info:", "Using the environment variable: NIMBLE_DIR='" &
              env & "'", Success, priority = HighPriority)
      nimbleDir = env
      setPackageCache(options, nimbleDir)
    else:
      # ...followed by project local deps mode
      if dirExists(nimbledeps) or (options.localdeps and not options.developLocaldeps):
        if not options.showVersion:
          display("Warning:", "Using project local deps mode", Warning,
                  priority = HighPriority)
        nimbleDir = nimbledeps
        options.localdeps = true
        propagate = true
        setPackageCache(options, options.config.nimbleDir) #We want to use the nimbleDir from the config so it can be shared

  options.nimbleDir = expandTilde(nimbleDir).absolutePath()
  if options.pkgCachePath == "":
    setPackageCache(options, options.nimbleDir)    
  if propagate:
    # Propagate custom nimbleDir to child processes
    putEnv("NIMBLE_DIR", options.nimbleDir)

    # Add $nimbledeps/bin to PATH
    let path = getEnv("PATH")
    if options.nimbleDir notin path:
      putEnv("PATH", options.nimbleDir / "bin" & PathSep & path)

  if not options.developLocaldeps:
    # Create nimbleDir/pkgs if it doesn't exist - will create nimbleDir as well
    let pkgsDir = options.getPkgsDir()
    if not dirExists(pkgsDir):
      createDir(pkgsDir)

proc parseCommand*(key: string, result: var Options) =
  result.action = Action(typ: parseActionType(key))
  initAction(result, key)


proc getNimbleFileDir*(pkgInfo: PackageInfo): string =
  pkgInfo.myPath.splitFile.dir

proc getRequiredNimVersion*(pkgInfo: PackageInfo): VersionRange =
  let nimPkgTupl = pkgInfo.requires.filterIt(it.name == "nim")
  if nimPkgTupl.len > 0:
    return nimPkgTupl[0].ver
  return VersionRange(kind: verAny)

proc getNimBin*(options: Options): string =
  return options.nim

proc setRunOptions(result: var Options, key, val: string, isArg: bool) =
  if result.action.runFile.isNone():
    if isArg or val == "--":
      result.action.runFile = some(key)
    else:
      result.action.compileFlags.add(val)
  else:
    result.action.runFlags.add(val)

proc parseArgument*(key: string, result: var Options) =
  case result.action.typ
  of actionNil:
    assert false
  of actionInstall, actionPath, actionDevelop, actionUninstall, actionUpgrade, actionAdd:
    # Parse pkg@verRange or git@github.com:nim-lang/nimble.git
    let i = rfind(key, '@')
    let maybeUrl = rfind(key, {'/', ':'})
    if i > maybeUrl:
      let (pkgName, pkgVer) = (key[0 .. i-1], key[i+1 .. key.len-1])
      if pkgVer.len == 0:
        raise nimbleError("Version range expected after '@'.")
      result.action.packages.add((pkgName, pkgVer.parseVersionRange()))
    else:
      result.action.packages.add((key, VersionRange(kind: verAny)))
  of actionRefresh:
    result.action.optionalURL = key
  of actionSearch:
    result.action.search.add(key)
  of actionInit, actionDump:
    if result.action.projName != "":
      raise nimbleError(
        "Can only perform this action on one package at a time.")
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

proc getNimVersionFromBin*(nimBin: string): Option[Version] =
  let cmd = nimBin & " --version"
  if nimBin.fileExists:
    let info = execProcess(cmd)
    var major, minor, patch: int
    for line in info.splitLines:
      if scanf(line, "Nim Compiler Version $i.$i.$i", major, minor, patch):
        let ver = $major & "." & $minor & "." & $patch
        return some newVersion(ver)    

proc getNimVersion*(ver: VersionRange): Version =
  case ver.kind:
  of verLater, verEarlier, verEqLater, verEqEarlier, verEq:
    ver.ver
  of verSpecial:
    ver.spe
  of verIntersect, verTilde, verCaret:
    getNimVersion(ver.verILeft)
  of verAny:
    newVersion "0.0.0"

proc getNimVersion*(pvs: seq[PkgTuple]): Version =
  result = newVersion("0.0.0")
  for pv in pvs:
    if pv.name == "nim":
      result = getNimVersion(pv.ver)  

proc makeNimBin*(options: Options, path: string, nimVersion: Option[Version] = none(Version)): NimBin =
  var path = path
  if path == "nim":
    path = findExe("nim")
  if path == "":
    raise nimbleError("Unable to find `nim` binary - add to $PATH or use `--nim`")
  if not path.isAbsolute():
    path = expandTilde(path).absolutePath()  
  var nimVersion = nimVersion
  if nimVersion.isNone:
    nimVersion = getNimVersionFromBin(path)
  
  return NimBin(path: path, version: nimVersion.get())

proc parseFlag*(flag, val: string, result: var Options, kind = cmdLongOption) =

  let f = flag.normalize().replace("-", "")

  # Global flags.
  var isGlobalFlag = true
  case f
  of "help", "h": result.showHelp = true
  of "version", "v": 
    result.showVersion = true
    result.noColor = true
  of "accept", "y": result.forcePrompts = forcePromptYes
  of "reject", "n": result.forcePrompts = forcePromptNo
  of "nimbledir": result.nimbleDir = val
  of "silent": result.verbosity = SilentPriority
  of "info": result.verbosity = MediumPriority
  of "verbose": result.verbosity = LowPriority
  of "debug": result.verbosity = DebugPriority
  of "offline": result.offline = true
  of "nocolor": result.noColor = true
  of "disablevalidation": result.disableValidation = true
  of "nim": result.nimBin = some makeNimBin(result, val)
  of "localdeps", "l": result.localdeps = true
  of "nosslcheck": result.disableSslCertCheck = true
  of "nolockfile": result.disableLockFile = true
  of "tarballs", "t": result.enableTarballs = true
  of "package", "p": result.package = val
  of "lockfile": result.lockFileName = val
  of "usesystemnim": result.useSystemNim = true
  of "legacy": result.legacy = true
  of "developfile":
    if result.developFile.len == 0:
      result.developFile = val.normalizedPath
    else:
      raise nimbleError(multipleDevelopFileOptionsGivenMsg)
  of "solver": 
    if val == "sat":
      result.useSatSolver = true
    elif val == "legacy":
      result.useSatSolver = false
    else:
      raise nimbleError("Unknown solver option: " & val)
  of "parser":
    if val == "declarative":
      result.useDeclarativeParser = true
    elif val == "nimvm":
      result.useDeclarativeParser = false
    else:
      raise nimbleError("Unknown parser option: " & val)
  of "requires":
    result.extraRequires = val.split(";").mapIt(it.strip.parseRequires())
  of "disablenimbinaries":
    result.disableNimBinaries = true
  of "maximumtaggedversions":
    try: 
      result.maxTaggedVersions = parseUInt(val).int
    except ValueError:
      raise nimbleError(&"{val} is not a valid value")
  of "features":
    result.features = val.split(";").mapIt(it.strip)
  of "ignoresubmodules":
    result.ignoreSubmodules = true
  else: isGlobalFlag = false

  var wasFlagHandled = true
  # Action-specific flags.
  case result.action.typ
  of actionSearch:
    case f
    of "versions", "ver":
      result.action.showSearchVersions = true
    else:
      wasFlagHandled = false
  of actionList:
    case f
    of "installed", "i":
      result.action.onlyInstalled = true
    of "nimbinaries", "n":
      result.action.onlyNimBinaries = true
    of "versions", "ver":
      result.action.showListVersions = true
    else:
      wasFlagHandled = false
  of actionDump:
    case f
    of "json": result.dumpMode = kdumpJson
    of "ini": result.dumpMode = kdumpIni
    of "collect": result.action.collect = true
    of "solve": result.action.solve = true
    else:
      wasFlagHandled = false
  of actionInstall:
    case f
    of "depsonly", "deps", "d":
      result.depsOnly = true
    of "norebuild":
      result.action.noRebuild = true
    of "passnim", "p":
      result.action.passNimFlags.add(val)
    else:
      if not isGlobalFlag:
        result.action.passNimFlags.add(getFlagString(kind, flag, val))
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
    if not isGlobalFlag:
      result.setRunOptions(flag, getFlagString(kind, flag, val), false)
  of actionCustom:
    if not isGlobalFlag:
      if result.action.command.normalize == "test":
        if f == "continue" or f == "c":
          result.continueTestsOnFailure = true

      # Set run flags for custom task
      result.action.custRunFlags.add(getFlagString(kind, flag, val))
  of actionDevelop:
    case f
    of "a", "add":
      result.action.devActions.add (datAdd, val.normalizedPath)
    of "r", "removepath":
      result.action.devActions.add (datRemoveByPath, val.normalizedPath)
    of "n", "removename":
      result.action.devActions.add (datRemoveByName, val)
    of "i", "include":
      result.action.devActions.add (datInclude, val.normalizedPath)
    of "e", "exclude":
      result.action.devActions.add (datExclude, val.normalizedPath)
    of "p", "path":
      if result.action.path.len == 0:
        result.action.path = val.normalizedPath
      else:
        raise nimbleError(multiplePathOptionsGivenMsg)
    of "withdependencies":
      result.action.withDependencies = true
    of "g", "global":
      result.action.global = true
    else:
      wasFlagHandled = false
  of actionSync:
    case f
    of "l", "listonly":
      result.action.listOnly = true
    else:
      wasFlagHandled = false
  of actionPublish:
    case f
    of "tags":
      result.action.publishAction = "tags"
    else:
      wasFlagHandled = false
  of actionDeps:
    case f
    of "format":
      result.action.format = val
    of "tree":
      result.action.depsAction = "tree"
    of "inverted":
      result.action.depsAction = "inverted"
    else:
      wasFlagHandled = false
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
    noColor: not isatty(stdout),
    startDir: getCurrentDir(),
    nimBinariesDir: getHomeDir() / ".nimble" / "nimbinaries", 
    maxTaggedVersions: 4,
    useSatSolver: true,
    useDeclarativeParser: false,
    legacy: false, #default to legacy code path for nimble < 1.0.0
    satResult: SatResult()
  )

proc handleUnknownFlags(options: var Options) =
  if options.action.typ == actionRun:
    # In addition to flags that come after the command before binary,
    # actionRun also uses flags that come before the command as compilation flags.
    options.action.compileFlags.insert(
      map(options.unknownFlags, x => getFlagString(x[0], x[1], x[2]))
    )
    options.unknownFlags = @[]
  elif options.action.typ == actionCustom:
    # actionCustom uses flags that come before the command as compilation flags
    # and flags that come after as run flags.
    options.action.custCompileFlags =
      map(options.unknownFlags, x => getFlagString(x[0], x[1], x[2]))
    options.unknownFlags = @[]
  else:
    # For everything else, handle the flags that came before the command
    # normally.
    let unknownFlags = options.unknownFlags
    options.unknownFlags = @[]
    for flag in unknownFlags:
      parseFlag(flag[1], flag[2], options, flag[0])

  if not options.legacy: 
    #default to declarative parser for new code path.
    options.useDeclarativeParser = true 

  # Any unhandled flags?
  if options.unknownFlags.len > 0:
    let flag = options.unknownFlags[0]
    raise nimbleError("Unknown option: " &
      getFlagString(flag[0], flag[1], flag[2]))

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
  of actionCustom:
    return options.action.custCompileFlags
  else:
    raiseAssert "unreachable"

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
        toSeq(pkgInfo.bin.values)[0]
      else:
        ""

    if runFile.len > 0:
      return some(runFile.changeFileExt(ExeExt))
  else:
    discard

proc isInstallingTopLevel*(options: Options, dir: string): bool =
  return options.startDir == dir

proc lockFile*(options: Options, dir: string): string =
  let lockFile = if options.lockFileName == default(string):
    defaultLockFileName
  else:
    options.lockFileName
  if lockFile.isAbsolute:
    result = lockFile
  else:
    result = dir / lockFile

proc lockFileExists*(options: Options, dir: string): bool =
  return options.lockFile(dir).fileExists

proc isSubdirOf*(subdir, baseDir: string): bool =
  let
    normalizedSubdir = subdir.normalizedPath
    normalizedBaseDir = baseDir.normalizedPath & DirSep

  when defined(windows):
    normalizedSubdir.toLower.startsWith(normalizedBaseDir.toLower)
  else:
    normalizedSubdir.startsWith(normalizedBaseDir)

proc isDevelopment*(pkg: PackageInfo, options: Options): bool =
  ### Returns true if the package is a development package. 
  ### A development package is a root package that is not installed.
  not pkg.myPath.parentDir.startsWith(options.getPkgsDir())

proc isLegacy*(options: Options): bool =
  let isVnext = not options.legacy or options.useDeclarativeParser
  return not isVnext
