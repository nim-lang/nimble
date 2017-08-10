# Copyright (C) Andreas Rumpf. All rights reserved.
# BSD License. Look at license.txt for more info.

## Implements the new configuration system for Nimble. Uses Nim as a
## scripting language.

import
  compiler/ast, compiler/modules, compiler/passes, compiler/passaux,
  compiler/condsyms, compiler/sem, compiler/semdata,
  compiler/llstream, compiler/vm, compiler/vmdef, compiler/commands,
  compiler/msgs, compiler/magicsys, compiler/idents,
  compiler/nimconf

from compiler/scriptconfig import setupVM
from compiler/astalgo import strTableGet
import compiler/options as compiler_options

import common, version, options, packageinfo, cli
import os, strutils, strtabs, tables, times, osproc, sets

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

proc setupVM(module: PSym; scriptName: string, flags: Flags): PEvalContext =
  ## This procedure is exported in the compiler sources, but its implementation
  ## is too Nim-specific to be used by Nimble.
  ## Specifically, the implementation of ``switch`` is problematic. Sooo
  ## I simply copied it here and edited it :)

  when declared(newIdentCache):
    result = newCtx(module, identCache)
  else:
    result = newCtx(module)
  result.mode = emRepl
  registerAdditionalOps(result)

  # captured vars:
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
    compiler_options.setConfigVar(getString(a, 0), getString(a, 1))
  cbconf get:
    setResult(a, compiler_options.getConfigVar(a.getString 0))
  cbconf exists:
    setResult(a, compiler_options.existsConfigVar(a.getString 0))
  cbconf nimcacheDir:
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
    compiler_options.command = a.getString 0
    let arg = a.getString 1
    if arg.len > 0:
      gProjectName = arg
      try:
        gProjectFull = canonicalizePath(gProjectPath / gProjectName)
      except OSError:
        gProjectFull = gProjectName
  cbconf getCommand:
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

proc getNimPrefixDir(): string =
  let env = getEnv("NIM_LIB_PREFIX")
  if env != "":
    return env

  result = splitPath(findExe("nim")).head.parentDir
  # The above heuristic doesn't work for 'choosenim' proxies. Thankfully in
  # that case the `nimble` binary is beside the `nim` binary so things should
  # just work.
  if not dirExists(result / "lib"):
    # By specifying an empty string we instruct the Nim compiler to use
    # getAppDir().head as the prefix dir. See compiler/options module for
    # the code responsible for this.
    result = ""

when declared(ModuleGraph):
  var graph: ModuleGraph

proc execScript(scriptName: string, flags: Flags, options: Options): PSym =
  ## Executes the specified script. Returns the script's module symbol.
  ##
  ## No clean up is performed and must be done manually!
  when declared(resetAllModulesHard):
    # for compatibility with older Nim versions:
    if "nimblepkg/nimscriptapi" notin compiler_options.implicitIncludes:
      compiler_options.implicitIncludes.add("nimblepkg/nimscriptapi")
  else:
    if "nimblepkg/nimscriptapi" notin compiler_options.implicitImports:
      compiler_options.implicitImports.add("nimblepkg/nimscriptapi")

  # Ensure the compiler can find its standard library #220.
  compiler_options.gPrefixDir = getNimPrefixDir()

  let pkgName = scriptName.splitFile.name

  # Ensure that "nimblepkg/nimscriptapi" is in the PATH.
  # TODO: put this in a more isolated directory.
  let tmpNimscriptApiPath = getTempDir() / "nimblepkg" / "nimscriptapi.nim"
  createDir(tmpNimscriptApiPath.splitFile.dir)
  writeFile(tmpNimscriptApiPath, nimscriptApi)
  searchPaths.add(getTempDir())

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
    graph = newModuleGraph()
    result = graph.makeModule(scriptName)

  incl(result.flags, sfMainModule)
  vm.globalCtx = setupVM(result, scriptName, flags)

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
  compiler_options.gProjectName = ""
  compiler_options.command = ""
  when declared(resetAllModulesHard):
    resetAllModulesHard()
  else:
    resetSystemArtifacts()
  clearPasses()
  msgs.gErrorMax = 1
  msgs.writeLnHook = nil
  vm.globalCtx = nil
  initDefines()

proc readPackageInfoFromNims*(scriptName: string, options: Options,
    result: var PackageInfo) =
  ## Executes the `scriptName` nimscript file. Reads the package information
  ## that it populates.

  # Setup custom error handling.
  msgs.gErrorMax = high(int)
  var previousMsg = ""
  msgs.writeLnHook =
    proc (output: string) =
      # The error counter is incremented after the writeLnHook is invoked.
      if msgs.gErrorCounter > 0:
        raise newException(NimbleError, previousMsg)
      elif previousMsg.len > 0:
        display("Info", previousMsg, priority = HighPriority)
      if output.normalize.startsWith("error"):
        raise newException(NimbleError, output)
      previousMsg = output

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
  if msgs.gErrorCounter > 0:
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

proc execTask*(scriptName, taskName: string,
    options: Options): ExecutionResult[void] =
  ## Executes the specified task in the specified script.
  ##
  ## `scriptName` should be a filename pointing to the nimscript file.
  result.success = true
  result.flags = newTable[string, seq[string]]()
  compiler_options.command = internalCmd
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
  result.command = compiler_options.command
  result.arguments = @[]
  for arg in compiler_options.gProjectName.split():
    result.arguments.add(arg)

  cleanup()

proc execHook*(scriptName, actionName: string, before: bool,
    options: Options): ExecutionResult[bool] =
  ## Executes the specified action's hook. Depending on ``before``, either
  ## the "before" or the "after" hook.
  ##
  ## `scriptName` should be a filename pointing to the nimscript file.
  result.success = true
  result.flags = newTable[string, seq[string]]()
  compiler_options.command = internalCmd
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
  result.command = compiler_options.command
  result.arguments = @[]
  for arg in compiler_options.gProjectName.split():
    result.arguments.add(arg)

  cleanup()

proc getNimScriptCommand(): string =
  compiler_options.command

proc setNimScriptCommand(command: string) =
  compiler_options.command = command

proc hasTaskRequestedCommand*(execResult: ExecutionResult): bool =
  ## Determines whether the last executed task used ``setCommand``
  return execResult.command != internalCmd

proc listTasks*(scriptName: string, options: Options) =
  setNimScriptCommand("help")

  discard execScript(scriptName, nil, options)
  # TODO: Make the 'task' template generate explicit data structure containing
  # all the task names + descriptions.
  cleanup()
