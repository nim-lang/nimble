## Utility API for Nim package managers.
## (c) 2021 Andreas Rumpf

import std/strutils

import compiler/[ast, idents, msgs, syntaxes, options, pathutils, lineinfos]
import version, packageinfotypes, packageinfo, options, packageparser, cli
import std/[tables, sequtils, strscans, strformat, os]

type NimbleFileInfo* = object
  nimbleFile*: string
  requires*: seq[string]
  srcDir*: string
  version*: string
  tasks*: seq[(string, string)]
  features*: Table[string, seq[string]]
  bin*: Table[string, string]
  hasInstallHooks*: bool
  hasErrors*: bool

proc eqIdent(a, b: string): bool {.inline.} =
  cmpIgnoreCase(a, b) == 0 and a[0] == b[0]

proc extractRequires(n: PNode, conf: ConfigRef, result: var seq[string], hasErrors: var bool) =
  for i in 1 ..< n.len:
    var ch: PNode = n[i]
    while ch.kind in {nkStmtListExpr, nkStmtList} and ch.len > 0:
      ch = ch.lastSon
    if ch.kind in {nkStrLit .. nkTripleStrLit}:
      result.add ch.strVal
    else:
      localError(conf, ch.info, "'requires' takes string literals")
      hasErrors = true

proc extractSeqLiteral(n: PNode, conf: ConfigRef, varName: string): seq[string] =
  ## Extracts a sequence literal of the form @["item1", "item2"]
  if n.kind == nkPrefix and n[0].kind == nkIdent and n[0].ident.s == "@":
    if n[1].kind == nkBracket:
      for item in n[1]:
        if item.kind in {nkStrLit .. nkTripleStrLit}:
          result.add item.strVal
        else:
          localError(conf, item.info, &"'{varName}' sequence items must be string literals")
    else:
      localError(conf, n.info, &"'{varName}' must be assigned a sequence of strings")
  else:
    localError(conf, n.info, &"'{varName}' must be assigned a sequence with @ prefix")

proc extractFeatures(featureNode: PNode, conf: ConfigRef, hasErrors: var bool): seq[string] =
  ## Extracts requirements from a feature declaration
  if featureNode.kind in {nkStmtList, nkStmtListExpr}:
    for stmt in featureNode:
      if stmt.kind in nkCallKinds and stmt[0].kind == nkIdent and 
         stmt[0].ident.s == "requires":
        var requires: seq[string]
        extractRequires(stmt, conf, requires, hasErrors)
        result.add requires

proc extract(n: PNode, conf: ConfigRef, result: var NimbleFileInfo) =
  case n.kind
  of nkStmtList, nkStmtListExpr:
    for child in n:
      extract(child, conf, result)
  of nkCallKinds:
    if n[0].kind == nkIdent:
      case n[0].ident.s
      of "requires":
        extractRequires(n, conf, result.requires, result.hasErrors)
      of "feature":
        if n.len >= 3 and n[1].kind in {nkStrLit .. nkTripleStrLit}:
          let featureName = n[1].strVal
          if not result.features.hasKey(featureName):
            result.features[featureName] = @[]
          result.features[featureName] = extractFeatures(n[2], conf, result.hasErrors)
      of "dev":
        let featureName = "dev"
        if not result.features.hasKey(featureName):
          result.features[featureName] = @[]
        result.features[featureName] = extractFeatures(n[1], conf, result.hasErrors)
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
    elif n[0].kind == nkIdent and eqIdent(n[0].ident.s, "bin"):
      let binSeq = extractSeqLiteral(n[1], conf, "bin")
      for bin in binSeq:
        when defined(windows):
          var bin = bin & ".exe"
          result.bin[bin] = bin 
        else:
          result.bin[bin] = bin        
    else:
      discard
  else:
    discard

proc extractRequiresInfo*(nimbleFile: string): NimbleFileInfo =
  ## Extract the `requires` information from a Nimble file. This does **not**
  ## evaluate the Nimble file. Errors are produced on stderr/stdout and are
  ## formatted as the Nim compiler does it. The parser uses the Nim compiler
  ## as an API. The result can be empty, this is not an error, only parsing
  ## errors are reported.
  result.nimbleFile = nimbleFile
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


proc parseRequiresWithFeatures(require: string): seq[(PkgTuple, seq[string])] =
  #features are expressed like this: require[feature1, feature2]
  result = newSeq[(PkgTuple, seq[string])]()
  for req in require.split(",").mapIt(it.strip):
    var featuresStr: string
    var requireStr: string
    var features = newSeq[string]()
    if scanf(req, "$*[$*]", requireStr, featuresStr):
      features = featuresStr.split(",")
      result.add((parseRequires(requireStr), features))
    else:
      result.add((parseRequires(req), @[]))

proc getRequires*(nimbleFileInfo: NimbleFileInfo, pkgActiveFeatures: var Table[PkgTuple, seq[string]]): seq[PkgTuple] =
  for require in nimbleFileInfo.requires:
    for (pkgTuple, activeFeatures) in parseRequiresWithFeatures(require):
      if activeFeatures.len > 0:      
        # displayInfo &"Package {nimbleFileInfo.nimbleFile} Found active features {activeFeatures} for {pkgTuple}", priority = HighPriority
        pkgActiveFeatures[pkgTuple] = activeFeatures

      result.add(pkgTuple)

proc getFeatures*(nimbleFileInfo: NimbleFileInfo): Table[string, seq[PkgTuple]] =
  result = initTable[string, seq[PkgTuple]]()
  for feature, requires in nimbleFileInfo.features:
    result[feature] = requires.map(parseRequires)    

proc toRequiresInfo*(pkgInfo: PackageInfo, options: Options): PackageInfo =
  #For nim we only need the version. Since version is usually in the form of `version = $NimMajor & "." & $NimMinor & "." & $NimPatch
  #we need to use the vm to get the version. Another option could be to use the binary and ask for the version
  if pkgInfo.basicInfo.name.isNim:
    return pkgInfo.toFullInfo(options)
  
  if pkgInfo.myPath.splitFile.ext == ".babel":
    displayWarning &"Package {pkgInfo.basicInfo.name} is a babel package, skipping declarative parser", priority = HighPriority
    return pkgInfo.toFullInfo(options)

  let nimbleFileInfo = extractRequiresInfo(pkgInfo.myPath)
  result = pkgInfo
  result.requires = getRequires(nimbleFileInfo, result.activeFeatures)
  if pkgInfo.infoKind != pikFull: #dont update as full implies pik requires
    result.infoKind = pikRequires
  result.features = getFeatures(nimbleFileInfo)
  result.bin = nimbleFileInfo.bin
  
when isMainModule:
  for x in tokenizeRequires("jester@#head >= 1.5 & <= 1.8"):
    echo x