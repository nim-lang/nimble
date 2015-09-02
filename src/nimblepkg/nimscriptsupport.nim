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

import nimbletypes, version
import os, strutils

proc raiseVariableError(ident, typ: string) {.noinline.} =
  raise newException(NimbleError,
    "NimScript's variable '" & ident & "' needs a value of type '" & typ & "'.")

proc isStrLit(n: PNode): bool = n.kind in {nkStrLit..nkTripleStrLit}

proc getGlobal(ident: string): string =
  let n = vm.globalCtx.getGlobalValue(getSysSym ident)
  if n.isStrLit:
    result = n.strVal
  else:
    raiseVariableError(ident, "string")

proc getGlobalAsSeq(ident: string): seq[string] =
  let n = vm.globalCtx.getGlobalValue(getSysSym ident)
  result = @[]
  if n.kind == nkBracket:
    for x in n:
      if x.isStrLit:
        result.add n.strVal
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

proc readPackageInfoFromNims*(scriptName: string; result: var PackageInfo) =
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
  vm.globalCtx = setupVM(m, scriptName)

  compileSystemModule()
  processModule(m, llStreamOpen(scriptName, fmRead), nil)

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
  if cmpIgnoreStyle(backend, "javascript") == 0:
    result.backend = "js"
  else:
    result.backend = backend.toLower()

  # ensure everything can be called again:
  resetAllModulesHard()
  vm.globalCtx = nil
  initDefines()
