## Utility API for Nim package managers.
## (c) 2021 Andreas Rumpf

import std/strutils

import compiler/[ast, idents, msgs, syntaxes, options, pathutils, lineinfos]
import version, packageinfotypes, packageinfo, options, packageparser

type NimbleFileInfo* = object
  requires*: seq[string]
  srcDir*: string
  version*: string
  tasks*: seq[(string, string)]
  hasInstallHooks*: bool
  hasErrors*: bool

proc eqIdent(a, b: string): bool {.inline.} =
  cmpIgnoreCase(a, b) == 0 and a[0] == b[0]

proc extract(n: PNode, conf: ConfigRef, result: var NimbleFileInfo) =
  case n.kind
  of nkStmtList, nkStmtListExpr:
    for child in n:
      extract(child, conf, result)
  of nkCallKinds:
    if n[0].kind == nkIdent:
      case n[0].ident.s
      of "requires":
        for i in 1 ..< n.len:
          var ch = n[i]
          while ch.kind in {nkStmtListExpr, nkStmtList} and ch.len > 0:
            ch = ch.lastSon
          if ch.kind in {nkStrLit .. nkTripleStrLit}:
            result.requires.add ch.strVal
          else:
            localError(conf, ch.info, "'requires' takes string literals")
            result.hasErrors = true
      of "task":
        if n.len >= 3 and n[1].kind == nkIdent and
            n[2].kind in {nkStrLit .. nkTripleStrLit}:
          result.tasks.add((n[1].ident.s, n[2].strVal))
      of "before", "after":
        #[
          before install do:
            exec "git submodule update --init"
            var make = "make"
            when defined(windows):
              make = "mingw32-make"
            exec make
        ]#
        if n.len >= 3 and n[1].kind == nkIdent and n[1].ident.s == "install":
          result.hasInstallHooks = true
      else:
        discard
  of nkAsgn, nkFastAsgn:
    if n[0].kind == nkIdent and eqIdent(n[0].ident.s, "srcDir"):
      if n[1].kind in {nkStrLit .. nkTripleStrLit}:
        result.srcDir = n[1].strVal
      else:
        localError(conf, n[1].info, "assignments to 'srcDir' must be string literals")
        result.hasErrors = true
    elif n[0].kind == nkIdent and eqIdent(n[0].ident.s, "version"):
      if n[1].kind in {nkStrLit .. nkTripleStrLit}:
        result.version = n[1].strVal
      else:
        localError(conf, n[1].info, "assignments to 'version' must be string literals")
        result.hasErrors = true
  else:
    discard

proc extractRequiresInfo*(nimbleFile: string): NimbleFileInfo =
  ## Extract the `requires` information from a Nimble file. This does **not**
  ## evaluate the Nimble file. Errors are produced on stderr/stdout and are
  ## formatted as the Nim compiler does it. The parser uses the Nim compiler
  ## as an API. The result can be empty, this is not an error, only parsing
  ## errors are reported.
  var conf = newConfigRef()
  conf.foreignPackageNotes = {}
  conf.notes = {}
  conf.mainPackageNotes = {}
  conf.errorMax = high(int)
  conf.structuredErrorHook = proc(
      config: ConfigRef, info: TLineInfo, msg: string, severity: Severity
  ) {.gcsafe.} =
    localError(config, info, warnUser, msg)

  let fileIdx = fileInfoIdx(conf, AbsoluteFile nimbleFile)
  var parser: Parser
  if setupParser(parser, fileIdx, newIdentCache(), conf):
    extract(parseAll(parser), conf, result)
    closeParser(parser)
  result.hasErrors = result.hasErrors or conf.errorCounter > 0

type PluginInfo* = object
  builderPatterns*: seq[(string, string)]

proc extractPlugin(
    nimscriptFile: string, n: PNode, conf: ConfigRef, result: var PluginInfo
) =
  case n.kind
  of nkStmtList, nkStmtListExpr:
    for child in n:
      extractPlugin(nimscriptFile, child, conf, result)
  of nkCallKinds:
    if n[0].kind == nkIdent:
      case n[0].ident.s
      of "builder":
        if n.len >= 3 and n[1].kind in {nkStrLit .. nkTripleStrLit}:
          result.builderPatterns.add((n[1].strVal, nimscriptFile))
      else:
        discard
  else:
    discard

proc extractPluginInfo*(nimscriptFile: string, info: var PluginInfo) =
  var conf = newConfigRef()
  conf.foreignPackageNotes = {}
  conf.notes = {}
  conf.mainPackageNotes = {}

  let fileIdx = fileInfoIdx(conf, AbsoluteFile nimscriptFile)
  var parser: Parser
  if setupParser(parser, fileIdx, newIdentCache(), conf):
    extractPlugin(nimscriptFile, parseAll(parser), conf, info)
    closeParser(parser)

const Operators* = {'<', '>', '=', '&', '@', '!', '^'}

proc token(s: string, idx: int, lit: var string): int =
  var i = idx
  if i >= s.len:
    return i
  while s[i] in Whitespace:
    inc(i)
  case s[i]
  of Letters, '#':
    lit.add s[i]
    inc i
    while i < s.len and s[i] notin (Whitespace + {'@', '#'}):
      lit.add s[i]
      inc i
  of '0' .. '9':
    while i < s.len and s[i] in {'0' .. '9', '.'}:
      lit.add s[i]
      inc i
  of '"':
    inc i
    while i < s.len and s[i] != '"':
      lit.add s[i]
      inc i
    inc i
  of Operators:
    while i < s.len and s[i] in Operators:
      lit.add s[i]
      inc i
  else:
    lit.add s[i]
    inc i
  result = i

iterator tokenizeRequires*(s: string): string =
  var start = 0
  var tok = ""
  while start < s.len:
    tok.setLen 0
    start = token(s, start, tok)
    yield tok

proc getRequires*(nimbleFileInfo: NimbleFileInfo): seq[PkgTuple] =
  for require in nimbleFileInfo.requires:
    result.add(parseRequires(require))

proc toRequiresInfo*(pkgInfo: PackageInfo, options: Options): PackageInfo =
  #For nim we only need the version. Since version is usually in the form of `version = $NimMajor & "." & $NimMinor & "." & $NimPatch
  #we need to use the vm to get the version. Another option could be to use the binary and ask for the version
  if pkgInfo.basicInfo.name.isNim:
    return pkgInfo.toFullInfo(options)
    
  let nimbleFileInfo = extractRequiresInfo(pkgInfo.myPath)
  result = pkgInfo
  result.requires = getRequires(nimbleFileInfo)
  result.infoKind = pikRequires

when isMainModule:
  for x in tokenizeRequires("jester@#head >= 1.5 & <= 1.8"):
    echo x