## Utility API for Nim package managers.
## (c) 2021 Andreas Rumpf

import std/strutils

import compiler/[ast, idents, msgs, syntaxes, options, pathutils, lineinfos]
import compiler/[renderer]
from compiler/nimblecmd import getPathVersionChecksum

import version, packageinfotypes, packageinfo, options, packageparser, cli,
  packagemetadatafile
import sha1hashes, vcstools
import std/[tables, sequtils, strscans, strformat, os, options]

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
  nestedRequires*: bool #if true, the requires section contains nested requires meaning that the package is incorrectly defined
  declarativeParserErrorLines*: seq[string]
  #In vnext this means that we will need to re-run sat after selecting nim to get the correct requires

proc eqIdent(a, b: string): bool {.inline.} =
  cmpIgnoreCase(a, b) == 0 and a[0] == b[0]

proc collectRequiresFromNode(n: PNode, result: var seq[string]) =
  case n.kind
  of nkStmtList, nkStmtListExpr:
    for child in n:
      collectRequiresFromNode(child, result)
  of nkCallKinds:
    if n[0].kind == nkIdent and n[0].ident.s == "requires":
      for i in 1 ..< n.len:
        var ch = n[i]
        while ch.kind in {nkStmtListExpr, nkStmtList} and ch.len > 0:
          ch = ch.lastSon
        if ch.kind in {nkStrLit .. nkTripleStrLit}:
          result.add ch.strVal
    else:
      for child in n:
        collectRequiresFromNode(child, result)
  else:
    discard

proc validateNoNestedRequires(nfl: var NimbleFileInfo, n: PNode, conf: ConfigRef, hasErrors: var bool, nestedRequires: var bool, inControlFlow: bool = false) =
  case n.kind
  of nkStmtList, nkStmtListExpr:
    for child in n:
      validateNoNestedRequires(nfl, child, conf, hasErrors, nestedRequires, inControlFlow)
  of nkWhenStmt, nkIfStmt, nkIfExpr, nkElifBranch, nkElse, nkElifExpr, nkElseExpr:
    for child in n:
      validateNoNestedRequires(nfl, child, conf, hasErrors, nestedRequires, true)
  of nkCallKinds:
    if n[0].kind == nkIdent:
      if n[0].ident.s == "requires":
        if inControlFlow:
          nestedRequires = true
          let errorLine = &"{nfl.nimbleFile}({n.info.line}, {n.info.col}) 'requires' cannot be nested inside control flow statements"
          nfl.declarativeParserErrorLines.add errorLine
          hasErrors = true
      elif n[0].ident.s == "taskRequires":
        # taskRequires is not supported in declarative parser yet
        nestedRequires = true
        let errorLine = &"{nfl.nimbleFile}({n.info.line}, {n.info.col}) 'taskRequires' is not supported in declarative parser"
        nfl.declarativeParserErrorLines.add errorLine
        hasErrors = true
      else:
        for child in n:
          validateNoNestedRequires(nfl, child, conf, hasErrors, nestedRequires, inControlFlow)
    else:
      for child in n:
        validateNoNestedRequires(nfl, child, conf, hasErrors, nestedRequires, inControlFlow)
  else:
    discard

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

proc extractFeatures(featureNode: PNode, conf: ConfigRef, hasErrors: var bool, nestedRequires: var bool): seq[string] =
  ## Extracts requirements from a feature declaration
  if featureNode.kind in {nkStmtList, nkStmtListExpr}:
    for stmt in featureNode:
      if stmt.kind in nkCallKinds and stmt[0].kind == nkIdent and 
         stmt[0].ident.s == "requires":
        var requires: seq[string]
        collectRequiresFromNode(stmt, requires)
        result.add requires

proc extract(n: PNode, conf: ConfigRef, result: var NimbleFileInfo) =
  validateNoNestedRequires(result, n, conf, result.hasErrors, result.nestedRequires)
  case n.kind
  of nkStmtList, nkStmtListExpr:
    for child in n:
      extract(child, conf, result)
  of nkCallKinds:
    if n[0].kind == nkIdent:
      case n[0].ident.s
      of "requires":
        collectRequiresFromNode(n, result.requires)
      of "feature":
        if n.len >= 3 and n[1].kind in {nkStrLit .. nkTripleStrLit}:
          let featureName = n[1].strVal
          if not result.features.hasKey(featureName):
            result.features[featureName] = @[]
          result.features[featureName] = extractFeatures(n[2], conf, result.hasErrors, result.nestedRequires)
      of "dev":
        let featureName = "dev"
        if not result.features.hasKey(featureName):
          result.features[featureName] = @[]
        result.features[featureName] = extractFeatures(n[1], conf, result.hasErrors, result.nestedRequires)
      of "task":
        if n.len >= 3 and n[1].kind == nkIdent and
            n[2].kind in {nkStrLit .. nkTripleStrLit}:
          result.tasks.add((n[1].ident.s, n[2].strVal))
      of "before", "after":
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

proc isNimbleFileNim(nimbleFilePath: string): bool =
  let file = nimbleFilePath.splitFile
  let nimbleFile = file.name & file.ext
  nimbleFile == "nim.nimble"

proc getNimCompilationPath*(nimbleFile: string): string =
  ## Extracts the path to the Nim compilation.nim file from the nimble file
  var conf = newConfigRef()
  conf.foreignPackageNotes = {}
  conf.notes = {}
  conf.mainPackageNotes = {}
  conf.errorMax = high(int)
  
  let fileIdx = fileInfoIdx(conf, AbsoluteFile nimbleFile)
  var parser: Parser
  var includePath = ""
  if setupParser(parser, fileIdx, newIdentCache(), conf):
    let ast = parseAll(parser)
    proc findIncludePath(n: PNode) =
      case n.kind
      of nkStmtList, nkStmtListExpr:
        for child in n:
          findIncludePath(child)
      of nkIncludeStmt:
        # Found an include statement
        if n.len > 0 and n[0].kind in {nkStrLit..nkTripleStrLit}:
          includePath = n[0].strVal
          # echo "Found include: ", includePath
      else:
        for i in 0..<n.safeLen:
          findIncludePath(n[i])
    
    findIncludePath(ast)
    closeParser(parser)
  
  if includePath.len > 0:
    if includePath.contains("compilation.nim"):
      result = nimbleFile.parentDir / includePath

proc extractNimVersion*(nimbleFile: string): string =
  ## Extracts Nim version numbers from the system's compilation.nim file
  ## using the compiler API.
  var compilationPath = getNimCompilationPath(nimbleFile)
  
  if not fileExists(compilationPath):
    return ""  
  # Now parse the compilation.nim file to get version numbers
  var major, minor, patch = 0
  
  var conf = newConfigRef()
  conf.foreignPackageNotes = {}
  conf.notes = {}
  conf.mainPackageNotes = {}
  conf.errorMax = high(int)
  
  let compFileIdx = fileInfoIdx(conf, AbsoluteFile compilationPath)
  var parser: Parser

  if setupParser(parser, compFileIdx, newIdentCache(), conf):
    let ast = parseAll(parser)
    
    # Process AST to find NimMajor, NimMinor, NimPatch definitions
    proc processNode(n: PNode) =
      case n.kind
      of nkStmtList, nkStmtListExpr:
        for child in n:
          processNode(child)
      of nkConstSection:
        for child in n:
          if child.kind == nkConstDef:
            var identName = ""
            case child[0].kind
            of nkPostfix:
              if child[0][1].kind == nkIdent:
                identName = child[0][1].ident.s
            of nkIdent:
              identName = child[0].ident.s
            of nkPragmaExpr:
              # Handle pragma expression (like NimMajor* {.intdefine.})
              if child[0][0].kind == nkIdent:
                identName = child[0][0].ident.s
              elif child[0][0].kind == nkPostfix and child[0][0][1].kind == nkIdent:
                identName = child[0][0][1].ident.s
            else: discard
              # echo "Unhandled node kind for const name: ", child[0].kind
            # Extract value
            if child.len > 2:
              case child[2].kind
              of nkIntLit:
                let value = child[2].intVal.int
                case identName
                of "NimMajor": major = value
                of "NimMinor": minor = value
                of "NimPatch": patch = value
                else: discard
              else:
                discard
      else:
        discard
    
    processNode(ast)
    closeParser(parser)
  # echo "Extracted version: ", major, ".", minor, ".", patch
  return &"{major}.{minor}.{patch}"

proc extractRequiresInfo*(nimbleFile: string): NimbleFileInfo =
  ## Extract the `requires` information from a Nimble file. This does **not**
  ## evaluate the Nimble file. Errors are produced on stderr/stdout and are
  ## formatted as the Nim compiler does it. The parser uses the Nim compiler
  ## as an API. The result can be empty, this is not an error, only parsing
  ## errors are reported.
  result.nimbleFile = nimbleFile
  if isNimbleFileNim(nimbleFile):
    let nimVersion = extractNimVersion(nimbleFile)
    result.version = nimVersion
    return result
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
    let ast = parseAll(parser)
    extract(ast, conf, result)
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

proc toRequiresInfo*(pkgInfo: PackageInfo, options: Options, nimbleFileInfo: Option[NimbleFileInfo] = none(NimbleFileInfo)): PackageInfo =
  #For nim we only need the version. Since version is usually in the form of `version = $NimMajor & "." & $NimMinor & "." & $NimPatch
  #we need to use the vm to get the version. Another option could be to use the binary and ask for the version
  # echo "toRequiresInfo: ", $pkgInfo.basicInfo, $pkgInfo.requires
  result = pkgInfo
  let forceDeclarativeOnly = options.satResult.pass == satNimSelection
  if pkgInfo.myPath.splitFile.ext == ".babel":
    if forceDeclarativeOnly: #TODO mark the pass as failed via declarativeParseFailed and continue
      let error = "Package " & pkgInfo.basicInfo.name & " is a babel package, skipping declarative parser"
      options.satResult.declarativeParseFailed = true
      options.satResult.declarativeParserErrorLines = @[error]
      return result
    else:
      displayWarning &"Package {pkgInfo.basicInfo.name} is a babel package, skipping declarative parser", priority = HighPriority
      result = getPkgInfo(pkgInfo.myPath.parentDir, options)
      fillMetaData(result, result.getRealDir(), false, options)
      return result

  let nimbleFileInfo = nimbleFileInfo.get(extractRequiresInfo(pkgInfo.myPath))
  result.requires = getRequires(nimbleFileInfo, result.activeFeatures)
  if pkgInfo.basicInfo.name.isNim: 
    return result
  if pkgInfo.infoKind != pikFull: #dont update as full implies pik requires
    result.infoKind = pikRequires
  
  if nimbleFileInfo.nestedRequires and options.action.typ != actionCheck: #When checking we want to fail on porpuse
    case options.satResult.pass
    of satNimSelection:
      options.satResult.declarativeParseFailed = true
      options.satResult.declarativeParserErrorLines = nimbleFileInfo.declarativeParserErrorLines
    else:
      result = getPkgInfo(result.myPath.parentDir, options)
      # raise nimbleError("Invalid SAT pass: " & $options.satResult.pass)
      # echo " to fullinfo Requires: ", result.requires
      # echo readFile(pkgInfo.myPath)

      # result.requires.add (name: "httpbeast", ver: VersionRange(kind: verAny))
      # echo "Fallback to VM parser for package: ", pkgInfo.basicInfo.name
      # echo "Requires: ", result.requires
  result.features = getFeatures(nimbleFileInfo)
  result.srcDir = nimbleFileInfo.srcDir
  fillMetaData(result, result.getRealDir(), false, options)
  
  # For develop mode dependencies, ensure VCS revision is set
  if result.isLink and result.metaData.vcsRevision == notSetSha1Hash:
    try:
      result.metaData.vcsRevision = getVcsRevision(result.getRealDir())
    except CatchableError:
      # If we can't get VCS revision, leave it as notSetSha1Hash
      discard
  
  if pkgInfo.infoKind == pikRequires:
    result.bin = nimbleFileInfo.bin #Noted that we are not parsing namedBins here, they are only parsed wit full info

proc fillPkgBasicInfo(pkgInfo: var PackageInfo, nimbleFileInfo: NimbleFileInfo) =
  let (_, _, checksum) = getPathVersionChecksum(nimbleFileInfo.nimbleFile.splitPath.tail)
  let sha1Checksum = 
    try:
      initSha1Hash(checksum)
    except InvalidSha1HashError:
      notSetSha1Hash
  pkgInfo.basicInfo.name = nimbleFileInfo.nimbleFile.splitFile.name
  pkgInfo.basicInfo.checksum = sha1Checksum
  pkgInfo.myPath = nimbleFileInfo.nimbleFile
  pkgInfo.basicInfo.version = newVersion nimbleFileInfo.version
  pkgInfo.srcDir = nimbleFileInfo.srcDir

proc getPkgInfoFromDirWithDeclarativeParser*(dir: string, options: Options): PackageInfo =
  let nimbleFile = findNimbleFile(dir, true, options)
  let nimbleFileInfo = extractRequiresInfo(nimbleFile)
  result = initPackageInfo()
  fillPkgBasicInfo(result, nimbleFileInfo)
  result.metadata = loadMetaData(result.getNimbleFileDir(), raiseIfNotFound = false, options)
  result = toRequiresInfo(result, options, some nimbleFileInfo)