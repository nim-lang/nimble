# Copyright (C) Andreas Rumpf. All rights reserved.
# BSD License. Look at license.txt for more info.

## Implements the new configuration system for Nimble. Uses Nim as a
## scripting language.

import
  compiler/ast, compiler/modules, compiler/passes, compiler/passaux,
  compiler/condsyms, compiler/options, compiler/sem, compiler/semdata,
  compiler/llstream, compiler/vm, compiler/vmdef, compiler/commands,
  compiler/msgs, compiler/magicsys, compiler/lists

from compiler/scriptconfig import setupVM
from compiler/idents import getIdent
from compiler/astalgo import strTableGet

import nimbletypes, version
import os, strutils, strtabs, times, osproc

type
  ExecutionResult* = object
    success*: bool
    command*: string
    arguments*: seq[string]
    flags*: StringTableRef

const
  internalCmd = "NimbleInternal"

proc raiseVariableError(ident, typ: string) {.noinline.} =
  raise newException(NimbleError,
    "NimScript's variable '" & ident & "' needs a value of type '" & typ & "'.")

proc isStrLit(n: PNode): bool = n.kind in {nkStrLit..nkTripleStrLit}

proc getGlobal(ident: string): string =
  let n = vm.globalCtx.getGlobalValue(getSysSym ident)
  if n.isStrLit:
    result = if n.strVal.isNil: "" else: n.strVal
  else:
    raiseVariableError(ident, "string")

proc getGlobalAsSeq(ident: string): seq[string] =
  let n = vm.globalCtx.getGlobalValue(getSysSym ident)
  result = @[]
  if n.kind == nkBracket:
    for x in n:
      if x.isStrLit:
        result.add x.strVal
      else:
        raiseVariableError(ident, "seq[string]")
  else:
    raiseVariableError(ident, "seq[string]")

proc extractRequires(result: var seq[PkgTuple]) =
  let n = vm.globalCtx.getGlobalValue(getSysSym "requiresData")
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
    options.setConfigVar(getString(a, 0), getString(a, 1))
  cbconf get:
    setResult(a, options.getConfigVar(a.getString 0))
  cbconf exists:
    setResult(a, options.existsConfigVar(a.getString 0))
  cbconf nimcacheDir:
    setResult(a, options.getNimcacheDir())
  cbconf paramStr:
    setResult(a, os.paramStr(int a.getInt 0))
  cbconf paramCount:
    setResult(a, os.paramCount())
  cbconf cmpIgnoreStyle:
    setResult(a, strutils.cmpIgnoreStyle(a.getString 0, a.getString 1))
  cbconf cmpIgnoreCase:
    setResult(a, strutils.cmpIgnoreCase(a.getString 0, a.getString 1))
  cbconf setCommand:
    options.command = a.getString 0
    let arg = a.getString 1
    if arg.len > 0:
      gProjectName = arg
      try:
        gProjectFull = canonicalizePath(gProjectPath / gProjectName)
      except OSError:
        gProjectFull = gProjectName
  cbconf getCommand:
    setResult(a, options.command)
  cbconf switch:
    if not flags.isNil:
      flags[a.getString 0] = a.getString 1

proc execScript(scriptName: string, flags: StringTableRef) =
  ## Executes the specified script.
  ##
  ## No clean up is performed and must be done manually!
  setDefaultLibpath()
  passes.gIncludeFile = includeModule
  passes.gImportModule = importModule
  initDefines()

  defineSymbol("nimscript")
  defineSymbol("nimconfig")
  defineSymbol("nimble")
  registerPass(semPass)
  registerPass(evalPass)

  appendStr(searchPaths, options.libpath)

  var m = makeModule(scriptName)
  incl(m.flags, sfMainModule)
  vm.globalCtx = setupVM(m, scriptName, flags)

  compileSystemModule()
  processModule(m, llStreamOpen(scriptName, fmRead), nil)

proc cleanup() =
  # ensure everything can be called again:
  options.gProjectName = ""
  options.command = ""
  resetAllModulesHard()
  clearPasses()
  msgs.gErrorMax = 1
  msgs.writeLnHook = nil
  vm.globalCtx = nil
  initDefines()

proc readPackageInfoFromNims*(scriptName: string; result: var PackageInfo) =
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
      previousMsg = output

  # Execute the nimscript file.
  execScript(scriptName, nil)

  # Extract all the necessary fields populated by the nimscript file.
  template trivialField(field) =
    result.field = getGlobal(astToStr field)

  template trivialFieldSeq(field) =
    result.field.add getGlobalAsSeq(astToStr field)

  # keep reasonable default:
  let name = getGlobal"packageName"
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

  extractRequires result.requires

  let binSeq = getGlobalAsSeq("bin")
  for i in binSeq:
    result.bin.add(i.addFileExt(ExeExt))

  let backend = getGlobal("backend")
  if backend.len == 0:
    result.backend = "c"
  elif cmpIgnoreStyle(backend, "javascript") == 0:
    result.backend = "js"
  else:
    result.backend = backend.toLower()

  cleanup()

proc execTask*(scriptName, taskName: string): ExecutionResult =
  ## Executes the specified task in the specified script.
  ##
  ## `scriptName` should be a filename pointing to the nimscript file.
  result.success = true
  result.flags = newStringTable()
  options.command = internalCmd
  echo("Executing task ", taskName, " in ", scriptName)

  execScript(scriptName, result.flags)
  # Explicitly execute the task procedure, instead of relying on hack.
  assert vm.globalCtx.module.kind == skModule
  let prc = vm.globalCtx.module.tab.strTableGet(getIdent(taskName & "Task"))
  if prc.isNil:
    # Procedure not defined in the NimScript module.
    result.success = false
    return
  discard vm.globalCtx.execProc(prc, [])

  # Read the command, arguments and flags set by the executed task.
  result.command = options.command
  result.arguments = @[]
  for arg in options.gProjectName.split():
    result.arguments.add(arg)

  cleanup()

proc getNimScriptCommand(): string =
  options.command

proc setNimScriptCommand(command: string) =
  options.command = command

proc hasTaskRequestedCommand*(execResult: ExecutionResult): bool =
  ## Determines whether the last executed task used ``setCommand``
  return execResult.command != internalCmd

proc listTasks*(scriptName: string) =
  setNimScriptCommand("help")

  execScript(scriptName, nil)
  # TODO: Make the 'task' template generate explicit data structure containing
  # all the task names + descriptions.
  cleanup()
