# Copyright (C) Andreas Rumpf. All rights reserved.
# BSD License. Look at license.txt for more info.

## Implements the new configuration system for Nimble. Uses Nim as a
## scripting language.

import
  compiler/ast, compiler/modules, compiler/passes, compiler/passaux,
  compiler/condsyms, compiler/sem, compiler/semdata,
  compiler/llstream, compiler/vm, compiler/vmdef, compiler/commands,
  compiler/msgs, compiler/magicsys, compiler/idents,
  compiler/nimconf, compiler/nversion

from compiler/scriptconfig import setupVM
from compiler/astalgo import strTableGet
import compiler/options as compiler_options

import common, version, options, packageinfo, cli
import os, strutils, strtabs, tables, times, osproc, sets, pegs

when not declared(resetAllModulesHard):
  import compiler/modulegraphs

type
  Flags = TableRef[string, seq[string]]
  ExecutionResult*[T] = object
    success*: bool
    command*: string
    arguments*: seq[string]
    flags*: Flags
    retVal*: T

const
  internalCmd = "NimbleInternal"
  nimscriptApi = staticRead("nimscriptapi.nim")

proc raiseVariableError(ident, typ: string) {.noinline.} =
  raise newException(NimbleError,
    "NimScript's variable '" & ident & "' needs a value of type '" & typ & "'.")

proc isStrLit(n: PNode): bool = n.kind in {nkStrLit..nkTripleStrLit}

proc getGlobal(ident: PSym): string =
  let n = vm.globalCtx.getGlobalValue(ident)
  if n.isStrLit:
    result = if n.strVal.isNil: "" else: n.strVal
  else:
    raiseVariableError(ident.name.s, "string")

proc getGlobalAsSeq(ident: PSym): seq[string] =
  let n = vm.globalCtx.getGlobalValue(ident)
  result = @[]
  if n.kind == nkBracket:
    for x in n:
      if x.isStrLit:
        result.add x.strVal
      else:
        raiseVariableError(ident.name.s, "seq[string]")
  else:
    raiseVariableError(ident.name.s, "seq[string]")

proc extractRequires(ident: PSym, result: var seq[PkgTuple]) =
  let n = vm.globalCtx.getGlobalValue(ident)
  if n.kind == nkBracket:
    for x in n:
      if x.kind == nkPar and x.len == 2 and x[0].isStrLit and x[1].isStrLit:
        result.add(parseRequires(x[0].strVal & x[1].strVal))
      elif x.isStrLit:
        result.add(parseRequires(x.strVal))
      else:
        raiseVariableError("requiresData", "seq[(string, VersionReq)]")
  else:
    raiseVariableError("requiresData", "seq[(string, VersionReq)]")

when declared(newIdentCache):
  var identCache = newIdentCache()

proc setupVM(graph: ModuleGraph; module: PSym; scriptName: string, flags: Flags): PEvalContext =
  ## This procedure is exported in the compiler sources, but its implementation
  ## is too Nim-specific to be used by Nimble.
  ## Specifically, the implementation of ``switch`` is problematic. Sooo
  ## I simply copied it here and edited it :)
  when declared(NimCompilerApiVersion):
    result = newCtx(module, identCache, graph)
  elif declared(newIdentCache):
    result = newCtx(module, identCache)
  else:
    result = newCtx(module)
  result.mode = emRepl
  registerAdditionalOps(result)

  # captured vars:
  let conf = graph.config
  var errorMsg: string
  var vthisDir = scriptName.splitFile.dir

  proc listDirs(a: VmArgs, filter: set[PathComponent]) =
    let dir = getString(a, 0)
    var res: seq[string] = @[]
    for kind, path in walkDir(dir):
      if kind in filter: res.add path
    setResult(a, res)

  template cbconf(name, body) {.dirty.} =
    result.registerCallback "stdlib.system." & astToStr(name),
      proc (a: VmArgs) =
        body

  template cbos(name, body) {.dirty.} =
    result.registerCallback "stdlib.system." & astToStr(name),
      proc (a: VmArgs) =
        try:
          body
        except OSError:
          errorMsg = getCurrentExceptionMsg()

  # Idea: Treat link to file as a file, but ignore link to directory to prevent
  # endless recursions out of the box.
  cbos listFiles:
    listDirs(a, {pcFile, pcLinkToFile})
  cbos listDirs:
    listDirs(a, {pcDir})
  cbos removeDir:
    os.removeDir getString(a, 0)
  cbos removeFile:
    os.removeFile getString(a, 0)
  cbos createDir:
    os.createDir getString(a, 0)
  cbos getOsError:
    setResult(a, errorMsg)
  cbos setCurrentDir:
    os.setCurrentDir getString(a, 0)
  cbos getCurrentDir:
    setResult(a, os.getCurrentDir())
  cbos moveFile:
    os.moveFile(getString(a, 0), getString(a, 1))
  cbos copyFile:
    os.copyFile(getString(a, 0), getString(a, 1))
  cbos getLastModificationTime:
    setResult(a, toSeconds(getLastModificationTime(getString(a, 0))))

  cbos rawExec:
    setResult(a, osproc.execCmd getString(a, 0))

  cbconf getEnv:
    setResult(a, os.getEnv(a.getString 0))
  cbconf existsEnv:
    setResult(a, os.existsEnv(a.getString 0))
  cbconf dirExists:
    setResult(a, os.dirExists(a.getString 0))
  cbconf fileExists:
    setResult(a, os.fileExists(a.getString 0))

  cbconf thisDir:
    setResult(a, vthisDir)
  cbconf put:
    when declared(NimCompilerApiVersion):
      compiler_options.setConfigVar(conf, getString(a, 0), getString(a, 1))
    else:
      compiler_options.setConfigVar(getString(a, 0), getString(a, 1))
  cbconf get:
    when declared(NimCompilerApiVersion):
      setResult(a, compiler_options.getConfigVar(conf, a.getString 0))
    else:
      setResult(a, compiler_options.getConfigVar(a.getString 0))
  cbconf exists:
    when declared(NimCompilerApiVersion):
      setResult(a, compiler_options.existsConfigVar(conf, a.getString 0))
    else:
      setResult(a, compiler_options.existsConfigVar(a.getString 0))
  cbconf nimcacheDir:
    when declared(NimCompilerApiVersion):
      setResult(a, compiler_options.getNimcacheDir(conf))
    else:
      setResult(a, compiler_options.getNimcacheDir())
  cbconf paramStr:
    setResult(a, os.paramStr(int a.getInt 0))
  cbconf paramCount:
    setResult(a, os.paramCount())
  cbconf cmpIgnoreStyle:
    setResult(a, strutils.cmpIgnoreStyle(a.getString 0, a.getString 1))
  cbconf cmpIgnoreCase:
    setResult(a, strutils.cmpIgnoreCase(a.getString 0, a.getString 1))
  cbconf setCommand:
    when declared(NimCompilerApiVersion):
      conf.command = a.getString 0
      let arg = a.getString 1
      if arg.len > 0:
        conf.projectName = arg
        try:
          conf.projectFull = canonicalizePath(conf, conf.projectPath / conf.projectName)
        except OSError:
          conf.projectFull = conf.projectName
    else:
      compiler_options.command = a.getString 0
      let arg = a.getString 1
      if arg.len > 0:
        gProjectName = arg
        try:
          gProjectFull = canonicalizePath(gProjectPath / gProjectName)
        except OSError:
          gProjectFull = gProjectName
  cbconf getCommand:
    when declared(NimCompilerApiVersion):
      setResult(a, conf.command)
    else:
      setResult(a, compiler_options.command)
  cbconf switch:
    if not flags.isNil:
      let
        key = a.getString 0
        value = a.getString 1
      if flags.hasKey(key):
        flags[key].add(value)
      else:
        flags[key] = @[value]

proc isValidLibPath(lib: string): bool =
  return fileExists(lib / "system.nim")

proc getNimPrefixDir(options: Options): string =
  let env = getEnv("NIM_LIB_PREFIX")
  if env != "":
    let msg = "Using env var NIM_LIB_PREFIX: " & env
    display("Warning:", msg, Warning, HighPriority)
    return env

  if options.config.nimLibPrefix != "":
    result = options.config.nimLibPrefix
    let msg = "Using Nim stdlib prefix from Nimble config file: " & result
    display("Warning:", msg, Warning, HighPriority)
    return

  result = splitPath(findExe("nim")).head.parentDir
  # The above heuristic doesn't work for 'choosenim' proxies. Thankfully in
  # that case the `nimble` binary is beside the `nim` binary so things should
  # just work.
  if not dirExists(result / "lib"):
    # By specifying an empty string we instruct the Nim compiler to use
    # getAppDir().head as the prefix dir. See compiler/options module for
    # the code responsible for this.
    result = ""

proc getLibVersion(lib: string): Version =
  ## This is quite a hacky procedure, but there is no other way to extract
  ## this out of the ``system`` module. We could evaluate it, but that would
  ## cause an error if the stdlib is out of date. The purpose of this
  ## proc is to give a nice error message to the user instead of a confusing
  ## Nim compile error.
  let systemPath = lib / "system.nim"
  if not fileExists(systemPath):
    raiseNimbleError("system module not found in stdlib path: " & lib)

  let systemFile = readFile(systemPath)
  let majorPeg = peg"'NimMajor' @ '=' \s* {\d*}"
  let minorPeg = peg"'NimMinor' @ '=' \s* {\d*}"
  let patchPeg = peg"'NimPatch' @ '=' \s* {\d*}"

  var majorMatches: array[1, string]
  let major = find(systemFile, majorPeg, majorMatches)
  var minorMatches: array[1, string]
  let minor = find(systemFile, minorPeg, minorMatches)
  var patchMatches: array[1, string]
  let patch = find(systemFile, patchPeg, patchMatches)

  if major != -1 and minor != -1 and patch != -1:
    return newVersion(majorMatches[0] & "." & minorMatches[0] & "." & patchMatches[0])
  else:
    return system.NimVersion.newVersion()

when declared(ModuleGraph):
  var graph = newModuleGraph()

proc execScript(scriptName: string, flags: Flags, options: Options): PSym =
  ## Executes the specified script. Returns the script's module symbol.
  ##
  ## No clean up is performed and must be done manually!
  graph = newModuleGraph()

  let conf = graph.config
  when declared(NimCompilerApiVersion):
    if "nimblepkg/nimscriptapi" notin conf.implicitImports:
      conf.implicitImports.add("nimblepkg/nimscriptapi")
  elif declared(resetAllModulesHard):
    # for compatibility with older Nim versions:
    if "nimblepkg/nimscriptapi" notin compiler_options.implicitIncludes:
      compiler_options.implicitIncludes.add("nimblepkg/nimscriptapi")
  else:
    if "nimblepkg/nimscriptapi" notin compiler_options.implicitImports:
      compiler_options.implicitImports.add("nimblepkg/nimscriptapi")

  # Ensure the compiler can find its standard library #220.
  when declared(NimCompilerApiVersion):
    conf.prefixDir = getNimPrefixDir(options)
    display("Setting", "Nim stdlib prefix to " & conf.prefixDir,
            priority=LowPriority)

    template myLibPath(): untyped = conf.libpath

    # Verify that lib path points to existing stdlib.
    setDefaultLibpath(conf)
  else:
    compiler_options.gPrefixDir = getNimPrefixDir(options)
    display("Setting", "Nim stdlib prefix to " & compiler_options.gPrefixDir,
            priority=LowPriority)

    template myLibPath(): untyped = compiler_options.libpath

    # Verify that lib path points to existing stdlib.
    compiler_options.setDefaultLibpath()

  display("Setting", "Nim stdlib path to " & myLibPath(),
          priority=LowPriority)
  if not isValidLibPath(myLibPath()):
    let msg = "Nimble cannot find Nim's standard library.\nLast try in:\n  - $1" %
                myLibPath()
    let hint = "Nimble does its best to find Nim's standard library, " &
               "sometimes this fails. You can set the environment variable " &
               "NIM_LIB_PREFIX to where Nim's `lib` directory is located as " &
               "a workaround. " &
               "See https://github.com/nim-lang/nimble#troubleshooting for " &
               "more info."
    raiseNimbleError(msg, hint)

  # Verify that the stdlib that was found isn't older than the stdlib that Nimble
  # was compiled with.
  let libVersion = getLibVersion(myLibPath())
  if NimVersion.newVersion() > libVersion:
    let msg = ("Nimble cannot use an older stdlib than the one it was compiled " &
               "with.\n  Stdlib in '$#' has version: $#.\n  Nimble needs at least: $#.") %
              [myLibPath(), $libVersion, NimVersion]
    let hint = "You may be running a newer version of Nimble than you intended " &
               "to. Run an older version of Nimble that is compatible with " &
               "the stdlib that Nimble is attempting to use or set the environment variable " &
               "NIM_LIB_PREFIX to where a different stdlib's `lib` directory is located as " &
               "a workaround." &
               "See https://github.com/nim-lang/nimble#troubleshooting for " &
               "more info."
    raiseNimbleError(msg, hint)

  let pkgName = scriptName.splitFile.name

  # Ensure that "nimblepkg/nimscriptapi" is in the PATH.
  block:
    let t = options.getNimbleDir / "nimblecache"
    let tmpNimscriptApiPath = t / "nimblepkg" / "nimscriptapi.nim"
    createDir(tmpNimscriptApiPath.splitFile.dir)
    writeFile(tmpNimscriptApiPath, nimscriptApi)
    when declared(NimCompilerApiVersion):
      conf.searchPaths.add(t)
    else:
      searchPaths.add(t)

  when declared(NimCompilerApiVersion):
    initDefines(conf.symbols)
    loadConfigs(DefaultConfig, conf)
    passes.gIncludeFile = includeModule
    passes.gImportModule = importModule

    defineSymbol(conf.symbols, "nimscript")
    defineSymbol(conf.symbols, "nimconfig")
    defineSymbol(conf.symbols, "nimble")
    registerPass(semPass)
    registerPass(evalPass)

    conf.searchPaths.add(conf.libpath)
  else:
    initDefines()
    loadConfigs(DefaultConfig)
    passes.gIncludeFile = includeModule
    passes.gImportModule = importModule

    defineSymbol("nimscript")
    defineSymbol("nimconfig")
    defineSymbol("nimble")
    registerPass(semPass)
    registerPass(evalPass)

    searchPaths.add(compiler_options.libpath)

  when declared(resetAllModulesHard):
    result = makeModule(scriptName)
  else:
    result = graph.makeModule(scriptName)

  incl(result.flags, sfMainModule)
  vm.globalCtx = setupVM(graph, result, scriptName, flags)

  # Setup builtins defined in nimscriptapi.nim
  template cbApi(name, body) {.dirty.} =
    vm.globalCtx.registerCallback pkgName & "." & astToStr(name),
      proc (a: VmArgs) =
        body

  cbApi getPkgDir:
    setResult(a, scriptName.splitFile.dir)

  when declared(newIdentCache):
    graph.compileSystemModule(identCache)
    graph.processModule(result, llStreamOpen(scriptName, fmRead), nil, identCache)
  else:
    compileSystemModule()
    processModule(result, llStreamOpen(scriptName, fmRead), nil)

proc cleanup() =
  # ensure everything can be called again:
  when declared(NimCompilerApiVersion):
    let conf = graph.config
    conf.projectName = ""
    conf.command = ""
  else:
    compiler_options.gProjectName = ""
    compiler_options.command = ""
  when declared(NimCompilerApiVersion):
    resetSystemArtifacts(graph)
  elif declared(resetAllModulesHard):
    resetAllModulesHard()
  else:
    resetSystemArtifacts()
  clearPasses()
  when declared(NimCompilerApiVersion):
    conf.errorMax = 1
    msgs.writeLnHook = nil
    vm.globalCtx = nil
    initDefines(conf.symbols)
  else:
    msgs.gErrorMax = 1
    msgs.writeLnHook = nil
    vm.globalCtx = nil
    initDefines()

proc readPackageInfoFromNims*(scriptName: string, options: Options,
    result: var PackageInfo) =
  ## Executes the `scriptName` nimscript file. Reads the package information
  ## that it populates.

  # Setup custom error handling.
  when declared(NimCompilerApiVersion):
    let conf = graph.config
    conf.errorMax = high(int)
  else:
    msgs.gErrorMax = high(int)

  template errCounter(): int =
    when declared(NimCompilerApiVersion): conf.errorCounter
    else: msgs.gErrorCounter

  var previousMsg = ""
  msgs.writeLnHook =
    proc (output: string) =
      # The error counter is incremented after the writeLnHook is invoked.
      if errCounter() > 0:
        raise newException(NimbleError, previousMsg)
      elif previousMsg.len > 0:
        display("Info", previousMsg, priority = MediumPriority)
      if output.normalize.startsWith("error"):
        raise newException(NimbleError, output)
      previousMsg = output

  when declared(NimCompilerApiVersion):
    conf.command = internalCmd
  else:
    compiler_options.command = internalCmd

  # Execute the nimscript file.
  let thisModule = execScript(scriptName, nil, options)

  when declared(resetAllModulesHard):
    let apiModule = thisModule
  else:
    var apiModule: PSym
    for i in 0..<graph.modules.len:
      if graph.modules[i] != nil and
          graph.modules[i].name.s == "nimscriptapi":
        apiModule = graph.modules[i]
        break
    doAssert apiModule != nil

  # Check whether an error has occurred.
  if errCounter() > 0:
    raise newException(NimbleError, previousMsg)

  # Extract all the necessary fields populated by the nimscript file.
  proc getSym(apiModule: PSym, ident: string): PSym =
    result = apiModule.tab.strTableGet(getIdent(ident))
    if result.isNil:
      raise newException(NimbleError, "Ident not found: " & ident)

  template trivialField(field) =
    result.field = getGlobal(getSym(apiModule, astToStr field))

  template trivialFieldSeq(field) =
    result.field.add getGlobalAsSeq(getSym(apiModule, astToStr field))

  # keep reasonable default:
  let name = getGlobal(apiModule.tab.strTableGet(getIdent"packageName"))
  if name.len > 0: result.name = name

  trivialField version
  trivialField author
  trivialField description
  trivialField license
  trivialField srcdir
  trivialField bindir
  trivialFieldSeq skipDirs
  trivialFieldSeq skipFiles
  trivialFieldSeq skipExt
  trivialFieldSeq installDirs
  trivialFieldSeq installFiles
  trivialFieldSeq installExt
  trivialFieldSeq foreignDeps

  extractRequires(getSym(apiModule, "requiresData"), result.requires)

  let binSeq = getGlobalAsSeq(getSym(apiModule, "bin"))
  for i in binSeq:
    result.bin.add(i.addFileExt(ExeExt))

  let backend = getGlobal(getSym(apiModule, "backend"))
  if backend.len == 0:
    result.backend = "c"
  elif cmpIgnoreStyle(backend, "javascript") == 0:
    result.backend = "js"
  else:
    result.backend = backend.toLowerAscii()

  # Grab all the global procs
  for i in thisModule.tab.data:
    if not i.isNil():
      let name = i.name.s.normalize()
      if name.endsWith("before"):
        result.preHooks.incl(name[0 .. ^7])
      if name.endsWith("after"):
        result.postHooks.incl(name[0 .. ^6])

  cleanup()

when declared(NimCompilerApiVersion):
  template nimCommand(): untyped = conf.command
  template nimProjectName(): untyped = conf.projectName
else:
  template nimCommand(): untyped = compiler_options.command
  template nimProjectName(): untyped = compiler_options.gProjectName

proc execTask*(scriptName, taskName: string,
    options: Options): ExecutionResult[void] =
  ## Executes the specified task in the specified script.
  ##
  ## `scriptName` should be a filename pointing to the nimscript file.
  result.success = true
  result.flags = newTable[string, seq[string]]()
  when declared(NimCompilerApiVersion):
    let conf = graph.config
  nimCommand() = internalCmd
  display("Executing",  "task $# in $#" % [taskName, scriptName],
          priority = HighPriority)

  let thisModule = execScript(scriptName, result.flags, options)
  let prc = thisModule.tab.strTableGet(getIdent(taskName & "Task"))
  if prc.isNil:
    # Procedure not defined in the NimScript module.
    result.success = false
    return
  discard vm.globalCtx.execProc(prc, [])

  # Read the command, arguments and flags set by the executed task.
  result.command = nimCommand()
  result.arguments = @[]
  for arg in nimProjectName().split():
    result.arguments.add(arg)

  cleanup()

proc execHook*(scriptName, actionName: string, before: bool,
    options: Options): ExecutionResult[bool] =
  ## Executes the specified action's hook. Depending on ``before``, either
  ## the "before" or the "after" hook.
  ##
  ## `scriptName` should be a filename pointing to the nimscript file.
  when declared(NimCompilerApiVersion):
    let conf = graph.config
  result.success = true
  result.flags = newTable[string, seq[string]]()
  nimCommand() = internalCmd
  let hookName =
    if before: actionName.toLowerAscii & "Before"
    else: actionName.toLowerAscii & "After"
  display("Attempting", "to execute hook $# in $#" % [hookName, scriptName],
          priority = MediumPriority)

  let thisModule = execScript(scriptName, result.flags, options)
  # Explicitly execute the task procedure, instead of relying on hack.
  let prc = thisModule.tab.strTableGet(getIdent(hookName))
  if prc.isNil:
    # Procedure not defined in the NimScript module.
    result.success = false
    cleanup()
    return
  let returnVal = vm.globalCtx.execProc(prc, [])
  case returnVal.kind
  of nkCharLit..nkUInt64Lit:
    result.retVal = returnVal.intVal == 1
  else: assert false

  # Read the command, arguments and flags set by the executed task.
  result.command = nimCommand()
  result.arguments = @[]
  for arg in nimProjectName().split():
    result.arguments.add(arg)

  cleanup()

proc getNimScriptCommand(): string =
  when declared(NimCompilerApiVersion):
    let conf = graph.config
  nimCommand()

proc setNimScriptCommand(command: string) =
  when declared(NimCompilerApiVersion):
    let conf = graph.config
  nimCommand() = command

proc hasTaskRequestedCommand*(execResult: ExecutionResult): bool =
  ## Determines whether the last executed task used ``setCommand``
  return execResult.command != internalCmd

proc listTasks*(scriptName: string, options: Options) =
  setNimScriptCommand("help")

  discard execScript(scriptName, nil, options)
  # TODO (#402): Make the 'task' template generate explicit data structure
  # containing all the task names + descriptions.
  cleanup()