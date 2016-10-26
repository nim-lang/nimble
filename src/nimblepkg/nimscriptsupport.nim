# Copyright (C) Andreas Rumpf. All rights reserved.
# BSD License. Look at license.txt for more info.

## Implements the new configuration system for Nimble. Uses Nim as a
## scripting language.

import
  compiler/ast, compiler/modules, compiler/passes, compiler/passaux,
  compiler/condsyms, compiler/sem, compiler/semdata,
  compiler/llstream, compiler/vm, compiler/vmdef, compiler/commands,
  compiler/msgs, compiler/magicsys, compiler/lists, compiler/nimconf

from compiler/scriptconfig import setupVM
from compiler/idents import getIdent
from compiler/astalgo import strTableGet
import compiler/options as compiler_options

import common, version, options, packageinfo
import os, strutils, strtabs, times, osproc, sets

type
  ExecutionResult*[T] = object
    success*: bool
    command*: string
    arguments*: seq[string]
    flags*: StringTableRef
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

proc setupVM(module: PSym; scriptName: string,
    flags: StringTableRef): PEvalContext =
  ## This procedure is exported in the compiler sources, but its implementation
  ## is too Nim-specific to be used by Nimble.
  ## Specifically, the implementation of ``switch`` is problematic. Sooo
  ## I simply copied it here and edited it :)

  result = newCtx(module)
  result.mode = emRepl
  registerAdditionalOps(result)

  # captured vars:
  var errorMsg: string
  var vthisDir = scriptName.splitFile.dir

  proc listDirs(a: VmArgs, filter: set[PathComponent]) =
    let dir = getString(a, 0)
    var result: seq[string] = @[]
    for kind, path in walkDir(dir):
      if kind in filter: result.add path
    setResult(a, result)

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
      flags[a.getString 0] = a.getString 1

proc findNimscriptApi(options: Options): string =
  ## Returns the directory containing ``nimscriptapi.nim`` or an empty string
  ## if it cannot be found.
  result = ""
  # Try finding it in exe's path
  if fileExists(getAppDir() / "nimblepkg" / "nimscriptapi.nim"):
    result = getAppDir()

  if result.len == 0:
    let pkgs = getInstalledPkgsMin(options.getPkgsDir(), options)
    var pkg: PackageInfo
    if pkgs.findPkg(("nimble", newVRAny()), pkg):
      let pkgDir = pkg.getRealDir()
      if fileExists(pkgDir / "nimblepkg" / "nimscriptapi.nim"):
        result = pkgDir

proc getNimPrefixDir(): string = splitPath(findExe("nim")).head.parentDir

proc execScript(scriptName: string, flags: StringTableRef, options: Options) =
  ## Executes the specified script.
  ##
  ## No clean up is performed and must be done manually!
  if "nimblepkg/nimscriptapi" notin compiler_options.implicitIncludes:
    compiler_options.implicitIncludes.add("nimblepkg/nimscriptapi")

  # Ensure the compiler can find its standard library #220.
  compiler_options.gPrefixDir = getNimPrefixDir()

  let pkgName = scriptName.splitFile.name

  # Ensure that "nimblepkg/nimscriptapi" is in the PATH.
  let nimscriptApiPath = findNimscriptApi(options)
  if nimscriptApiPath.len > 0:
    # TODO: Once better output is implemented show a message here.
    appendStr(searchPaths, nimscriptApiPath)
  else:
    let tmpNimscriptApiPath = getTempDir() / "nimblepkg" / "nimscriptapi.nim"
    createDir(tmpNimscriptApiPath.splitFile.dir)
    if not existsFile(tmpNimscriptApiPath):
      writeFile(tmpNimscriptApiPath, nimscriptApi)
    appendStr(searchPaths, getTempDir())

  initDefines()
  loadConfigs(DefaultConfig)
  passes.gIncludeFile = includeModule
  passes.gImportModule = importModule

  defineSymbol("nimscript")
  defineSymbol("nimconfig")
  defineSymbol("nimble")
  registerPass(semPass)
  registerPass(evalPass)

  appendStr(searchPaths, compiler_options.libpath)

  var m = makeModule(scriptName)
  incl(m.flags, sfMainModule)
  vm.globalCtx = setupVM(m, scriptName, flags)

  # Setup builtins defined in nimscriptapi.nim
  template cbApi(name, body) {.dirty.} =
    vm.globalCtx.registerCallback pkgName & "." & astToStr(name),
      proc (a: VmArgs) =
        body

  cbApi getPkgDir:
    setResult(a, scriptName.splitFile.dir)

  compileSystemModule()
  processModule(m, llStreamOpen(scriptName, fmRead), nil)

proc cleanup() =
  # ensure everything can be called again:
  compiler_options.gProjectName = ""
  compiler_options.command = ""
  resetAllModulesHard()
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
        echo(previousMsg)
      if output.normalize.startsWith("error"):
        raise newException(NimbleError, output)
      previousMsg = output

  compiler_options.command = internalCmd

  # Execute the nimscript file.
  execScript(scriptName, nil, options)

  # Check whether an error has occurred.
  if msgs.gErrorCounter > 0:
    raise newException(NimbleError, previousMsg)

  # Extract all the necessary fields populated by the nimscript file.
  proc getSym(thisModule: PSym, ident: string): PSym =
    result = thisModule.tab.strTableGet(getIdent(ident))
    if result.isNil:
      raise newException(NimbleError, "Ident not found: " & ident)

  template trivialField(field) =
    result.field = getGlobal(getSym(thisModule, astToStr field))

  template trivialFieldSeq(field) =
    result.field.add getGlobalAsSeq(getSym(thisModule, astToStr field))

  # Grab the module Sym for .nimble file (nimscriptapi is included in it).
  let idx = fileInfoIdx(scriptName)
  let thisModule = getModule(idx)
  assert(not thisModule.isNil)
  assert thisModule.kind == skModule

  # keep reasonable default:
  let name = getGlobal(thisModule.tab.strTableGet(getIdent"packageName"))
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

  extractRequires(getSym(thisModule, "requiresData"), result.requires)

  let binSeq = getGlobalAsSeq(getSym(thisModule, "bin"))
  for i in binSeq:
    result.bin.add(i.addFileExt(ExeExt))

  let backend = getGlobal(getSym(thisModule, "backend"))
  if backend.len == 0:
    result.backend = "c"
  elif cmpIgnoreStyle(backend, "javascript") == 0:
    result.backend = "js"
  else:
    result.backend = backend.toLower()

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
  result.flags = newStringTable()
  compiler_options.command = internalCmd
  echo("Executing task ", taskName, " in ", scriptName)

  execScript(scriptName, result.flags, options)
  # Explicitly execute the task procedure, instead of relying on hack.
  let idx = fileInfoIdx(scriptName)
  let thisModule = getModule(idx)
  assert thisModule.kind == skModule
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
  result.flags = newStringTable()
  compiler_options.command = internalCmd
  let hookName =
    if before: actionName.toLower & "Before"
    else: actionName.toLower & "After"
  echo("Attempting to execute hook ", hookName, " in ", scriptName)

  execScript(scriptName, result.flags, options)
  # Explicitly execute the task procedure, instead of relying on hack.
  let idx = fileInfoIdx(scriptName)
  let thisModule = getModule(idx)
  assert thisModule.kind == skModule
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

  execScript(scriptName, nil, options)
  # TODO: Make the 'task' template generate explicit data structure containing
  # all the task names + descriptions.
  cleanup()
