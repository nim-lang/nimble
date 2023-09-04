import std/[
  sequtils, macros, tables, options, strformat, strutils,
  parseutils, algorithm, hashes
]

export options

runnableExamples:
  {.experimental: "caseStmtMacros".}

  case [(1, 3), (3, 4)]:
    of [(1, @a), _]:
      echo a

    else:
      echo "Match failed"


## .. include:: matching.rst

const
  nnkStrKinds* = {
    nnkStrLit .. nnkTripleStrLit
  } ## Set of all nim node kinds for string nodes

  nnkIntKinds* = {
    nnkCharLit .. nnkUInt64Lit
  } ## Set of all nim node kinds for integer literal nodes

  nnkFloatKinds* = {
    nnkFloatLit .. nnkFloat128Lit
  } ## Set of all nim node kinds for float literal nodes

  nnkIdentKinds* = {
    nnkIdent, nnkSym, nnkOpenSymChoice
  } ## Set of all nim node kinds for identifier-like nodes

  nnkTokenKinds* =
    nnkStrKinds + nnkIntKinds + nnkFloatKinds +
    nnkIdentKinds + {nnkEmpty}
    ## Set of all token-like nodes (primitive type literals or
    ## identifiers)


const debugWIP = false

template echov(arg: untyped, indent: int = 0): untyped {.used.} =
  {.noSideEffect.}:
    when debugWIP:
      let pref = "  ".repeat(indent)
      let val = $arg
      if split(val, '\n').len > 1:
        echo instantiationInfo().line, pref, " \e[32m",
         astToStr(arg), "\e[39m "
        echo pref, val

      else:
        echo instantiationInfo().line, pref,
          " \e[32m", astToStr(arg), "\e[39m ", val

template varOfIteration*(arg: untyped): untyped =
  when compiles(
    for item in items(arg):
      discard
  ):
    ((
      # Hack around `{.requiresinit.}`
      block:
        var tmp2: ref typeof(items(arg), typeOfIter)
        let tmp = tmp2[]
        tmp
    ))

  else:
    proc aux(): auto =
      for val in arg:
        return val

    var tmp2: ref typeof(aux())
    let tmp1 = tmp2[]
    tmp1

func fullCopy[T](s: seq[T]): seq[T] =
  for elem in s:
    result.add elem

func codeFmt(str: string): string {.inline.} =
  &"\e[4m{str}\e[24m"

func codeFmt(node: NimNode): NimNode {.inline.} =
  node.strVal().codeFmt().newLit()

func toPatternStr(node: NimNode): NimNode =
  var tmp = node.toStrLit().strVal()
  if split(tmp, '\n').len > 1:
    tmp = "\n" & tmp.split('\n').mapIt("  " & it).join("\n") & "\n\n"

  else:
    tmp = codeFmt(tmp) & ". "

  newLit(tmp)


func nodeStr(n: NimNode): string =
  ## Get nim node string value from any identifier or string literal node
  case n.kind:
    of nnkIdent: n.strVal()
    of nnkOpenSymChoice: n[0].strVal()
    of nnkSym: n.strVal()
    of nnkStrKinds: n.strVal()
    else: raiseAssert(&"Cannot get string value from node kind {n.kind}")

func lineIInfo(node: NimNode): NimNode =
  ## Create tuple literal for `{.line: .}` pragma
  let iinfo = node.lineInfoObj()
  newLit((filename: iinfo.filename, line: iinfo.line))



func idxTreeRepr(inputNode: NimNode, maxLevel: int = 120): string =
  func aux(node: NimNode, parent: seq[int]): seq[string] =
    result.add parent.mapIt(&"[{it}]").join("") &
      "  ".repeat(6) &
      ($node.kind)[3..^1] &
      (if node.len == 0: " " & node.toStrLit().nodeStr() else: "")

    for idx, subn in node:
      if parent.len + 1 < maxLevel:
        result &= aux(subn, parent & @[idx])
      else:
        result &= (parent & @[idx]).mapIt(&"[{it}]").join("") &
          " ".repeat(6 + 3 + 3)  & "[...] " & ($subn.kind)[3..^1]

  return aux(inputNode, @[]).join("\n")




template getSome[T](opt: Option[T], injected: untyped): bool =
  opt.isSome() and ((let injected {.inject.} = opt.get(); true))

func splitDots(n: NimNode): seq[NimNode] =
  ## Split nested `DotExpr` node into sequence of nodes. `a.b.c -> @[a, b, c]`
  result = case n.kind:
    of nnkDotExpr:
      if n[0].kind == nnkDotExpr:
        splitDots(n[0]) & @[n[1]]
      elif n[0].kind == nnkBracketExpr:
        splitDots(n[0]) & splitDots(n[1])
      else:
        @[n[0], n[1]]
    of nnkBracketExpr:
      if n[0].kind in nnkIdentKinds:
        @[n[0]] & splitDots(n[1]).mapIt(nnkBracket.newTree(it))
      else:
        n[0][0].splitDots() & (
          n[0][1].splitDots() & n[1].splitDots()
        ).mapIt(nnkBracket.newTree(it))
    else:
      @[n]

func firstDot(n: NimNode): NimNode {.inline.} =
  splitDots(n)[0]

template assertKind(node: NimNode, kindSet: set[NimNodeKind]): untyped =
  {.line: instantiationInfo(fullpaths = true).}:
    if node.kind notin kindSet:
      raiseAssert("Expected one of " & $kindSet & " but node has kind " &
        $node.kind & " (assertion on " & $instantiationInfo() & ")")

func startsWith(n: NimNode, str: string): bool =
  n.nodeStr().startsWith(str)



func parseEnumField(field: NimNode): string =
  ## Get name of enum field from nim node
  case field.kind:
    of nnkEnumFieldDef:
      field[0].nodeStr
    of nnkSym:
      field.nodeStr
    else:
      raiseAssert(&"Cannot parse enum field for kind: {field.kind}")

func parseEnumImpl(en: NimNode): seq[string] =
  ## Get sequence of enum value names
  case en.kind:
    of nnkSym:
      let impl = en.getTypeImpl()
      case impl.kind:
        of nnkBracketExpr:
          return parseEnumImpl(impl.getTypeInst()[1].getImpl())
        of nnkEnumTy:
          result = parseEnumImpl(impl)
        else:
          assertKind(impl, {nnkBracketExpr, nnkEnumTy})
          # raiseAssert(&"#[ IMPLEMENT {impl.kind} ]#")
    of nnkTypeDef:
      result = parseEnumImpl(en[2])
    of nnkEnumTy:
      for field in en[1..^1]:
        result.add parseEnumField(field)
    of nnkTypeSection:
      result = parseEnumImpl(en[0])
    else:
      raiseAssert(&"Cannot parse enum element for kind {en.kind}")


func pref(name: string): string =
  discard name.parseUntil(result, {'A' .. 'Z', '0' .. '9'})

func foldInfix(
    s: seq[NimNode],
    inf: string, start: seq[NimNode] = @[]): NimNode =

  if inf == "or" and s.len > 0 and (
    s[0].eqIdent("true") or s[0] == newLit(true)
  ):
    result = newLit(true)

  else:
    result = ( start & s ).mapIt(it.newPar().newPar()).foldl(
      nnkInfix.newTree(ident inf, a, b))


func nilAccessCondition(condition, access: NimNode): NimNode =
  nnkInfix.newTree(
    ident "and",
    (
      quote do:
        block:
          type AccessType = typeof(`access`)
          when AccessType is ref: not isNil(`access`)
          elif AccessType is ptr: not isNil(`access`)
          else: true
    ),
    condition
  )


func commonPrefix(strs: seq[string]): string =
  ## Find common prefix for seq of strings
  if strs.len == 0:
    return ""
  else:
    let strs = strs.sorted()
    for i in 0 ..< min(strs[0].len, strs[^1].len):
      if strs[0][i] == strs[^1][i]:
        result.add strs[0][i]
      else:
        return


func dropPrefix(str: string, alt: string): string =
  if str.startsWith(alt):
    return str[min(alt.len, str.len)..^1]
  return str

func dropPrefix(ss: seq[string], pattern: string): seq[string] =
  for s in ss:
    result.add s.dropPrefix(pattern)


func addPrefix(str, pref: string): string =
  if not str.startsWith(pref): pref & str else: str

func hash(iinfo: LineInfo): Hash =
  !$(iinfo.line.hash !& iinfo.column.hash !& iinfo.filename.hash)

proc getKindNames*(head: NimNode): (string, seq[string]) =
  var
    pref: string
    names: seq[string]
    cache {.global.}: Table[LineInfo, (string, seq[string])]

  block:
    let
      impl = head.getTypeImpl()
      iinfo = impl.lineInfoObj()

    if iinfo notin cache:
      let
        decl = impl.parseEnumImpl()
        pref = decl.commonPrefix().pref()

      cache[iinfo] = (pref, decl.dropPrefix(pref))

    pref = cache[iinfo][0]
    names = cache[iinfo][1]

  return (pref, names)



macro hasKindImpl*(head: typed, kind: untyped): untyped =
  if kind.kind == nnkDotExpr:
    result = nnkInfix.newTree(ident "==", head, kind)

  else:
    let (pref, names) = getKindNames(head)
    kind.assertKind({nnkIdent})
    let str = kind.toStrLit().nodeStr().addPrefix(pref)
    let kind = ident(str)
    if not names.anyIt(eqIdent(it.addPrefix(pref), str)):
      error("Invalid kind name - " & kind.toStrLit().strVal(), kind)

    result = nnkInfix.newTree(ident "==", head, kind)

template hasKind*(head, kindExpr: untyped): untyped =
  ## Determine if `head` has `kind` value. Either function/procedure
  ## `kind` or field with the same name is expected to be declared.
  ## Type of `kind` must be an enum. Kind expression is a pattern
  ## describing expected values. Possible examples of pattern
  ## (assuming value of type `NimNode` is used as `head`)
  ##
  ## - `nnkIntLit` - match integer literal
  ## - `IntLit` - alternative (preferred) syntax for matching enum values
  ##   `nnk` prefix can be omitted.
  when compiles(head.kind):
    hasKindImpl(head.kind, kindExpr)

  elif compiles(head is kindExpr):
    true

  else:
    static: error "No `kind` defined for " & $typeof(head)

when (NimMajor, NimMinor, NimPatch) >= (1, 4, 2):
  type FieldIndex* = distinct int
  func `==`*(idx: FieldIndex, i: SomeInteger): bool = idx.int == i
  template `[]`*(t: tuple, idx: static[FieldIndex]): untyped =
    t[idx.int]

else:
  type FieldIndex* = int


type
  MatchKind* = enum
    ## Different kinds of matching patterns
    kItem ## Match single element
    kSeq ## Match sequence of elements
    kTuple ## Mach tuple (anonymous or named)
    kPairs ## Match key-value pairs
    kObject ## Match object, named tuple or object-like value
    kSet ## Match set of elements
    kAlt ## Ordered choice - mactch any of patterns.

  SeqKeyword* = enum
    ## Possible special words for seq pattern matching
    lkAny = "any" ## Any element from seq
    lkAll = "all" ## All elements from seq
    lkNone = "none"  ## None of the elements from seq
    lkOpt = "opt" ## Optionaly match element in seq
    lkUntil = "until" ## All elements until
    lkPref = "pref" ## All elements while
    lkPos ## Exact position
    lkSlice ## Subrange slice
    lkTrail ## Variadic placeholder `.._`

  SeqStructure* = object
    decl: NimNode ## Original declaration of the node
    bindVar*: Option[NimNode] ## Optional bound variable
    pattern*: Match ## Patterh for element matching
    case kind*: SeqKeyword
      of lkSlice:
        slice*: NimNode
      else:
        discard

  ItemMatchKind* = enum
    ## Type of item pattern match
    imkInfixEq ## Match item using infix operator
    imkSubPattern ## Match item by checking it agains subpattern
    imkPredicate ## Execute custom predicate to determine if element
                 ## matches pattern.

  KVPair* = object
    key: NimNode
    pattern: Match

  MatchError* = ref object of CatchableError ## Exception indicating match failure


  Match* = ref object
    ## Object describing single match for element
    bindVar*: Option[NimNode] ## Bound variable (if any)
    declNode*: NimNode ## Original declaration of match
    isOptional*: bool
    fallback*: Option[NimNode] ## Default value in case match fails
    case kind*: MatchKind
      of kItem:
        case itemMatch: ItemMatchKind
          of imkInfixEq:
            infix*: string ## Infix operator used for comparison
            rhsNode*: NimNode ## Rhs expression to compare against
            isPlaceholder*: bool ## Always true? `_` pattern is an
            ## infix expression with `isPlaceholder` equal to true
          of imkSubPattern:
            rhsPattern*: Match ## SubPattern to compare value against
          of imkPredicate:
            isCall*: bool ## Predicate is a call expression
            ## (`@val.matches()`) or a free-standing expression
            ## (`@val(it.len < 100)`)
            predBody*: NimNode ## Body of the expression

      of kAlt:
        altElements*: seq[Match] ## Alternatives for matching
      of kSeq:
        seqElements*: seq[SeqStructure] ## Sequence subpatterns
      of kTuple:
        tupleElements*: seq[Match] ## Tuple elements
      of kPairs:
        pairElements*: seq[KVPair]
        nocheck*: bool

      of kSet:
        setElements*: seq[Match]

      of kObject:
        kindCall*: Option[NimNode] ## Optional node with kind
        ## expression pattern (see `hasKind`)
        isRefKind*: bool
        fieldElements*: seq[tuple[
          name: string,
          pattern: Match
        ]]

        kvMatches*: Option[Match] ## Optional key-value matches for
        ## expressions like `JObject({"key": @val})`
        seqMatches*: Option[Match]  ## Optional indexed matches for
        ## subelement access using `Infix([@op, @lhs, @rhs])` pattern.

  AccsElem = object
    isVariadic: bool
    case inStruct: MatchKind
      of kSeq:
        pos*: NimNode ## Expressions for accessing seq element

      of kTuple:
        idx*: int ## Tuple field index

      of kObject:
        field*: string ## Object field name

      of kPairs:
        key*: NimNode ## Expression for key-value pair
        nocheck*: bool

      of kSet:
        discard

      of kAlt:
        altIdx*: int
        altMax*: int

      of kItem:
        isOpt*: bool ## Is match optional

  Path = seq[AccsElem]

  VarKind* = enum
    ## Kind of matched variables
    vkRegular ## Regular variable, assigned once
    vkSequence
    vkOption
    vkSet
    vkAlt

  AltSpec = object
    altMax: int16 ## Max alterantive index
    altPositions: set[int16] ## Previous positions for index
    completed: bool ## Completed index

  VarSpec* = object
    decl*: NimNode ## First time variable has been declared
    case varKind*: VarKind ## Type of the variable
      of vkAlt:
        prefixMap*: Table[Path, AltSpec]
      else:
        nil

    typePath*: Path ## Whole path for expression that can be used to
                    ## determine type of the variable.
    foundCount*: int ## Number of variable occurencies in expression

  VarTable = Table[string, VarSpec]

func hash(accs: AccsElem): Hash =
  var h: Hash = 0
  h = h !& hash(accs.isVariadic)
  case accs.inStruct:
    of kSeq:    h = h !& hash(accs.pos.repr)
    of kTuple:  h = h !& hash(accs.idx)
    of kObject: h = h !& hash(accs.field)
    of kPairs:  h = h !& hash(accs.key.repr) !& hash(accs.nocheck)
    of kAlt:    h = h !& hash(accs.altIdx) !& hash(accs.altMax)
    of kItem:   h = h !& hash(accs.isOpt)
    of kSet:
      discard

  result = !$h

func `==`(a, b: AccsElem): bool =
  a.isVariadic == b.isVariadic and
  a.inStruct == b.inStruct and
  (
    case a.inStruct:
      of kSeq:
        a.pos == b.pos
      of kTuple:
        a.idx == b.idx
      of kObject:
        a.field == b.field
      of kPairs:
        a.key == b.key and a.nocheck == b.nocheck
      of kItem:
        a.isOpt == b.isOpt
      of kSet:
        true
      of kAlt:
        a.altIdx == b.altIdx and a.altMax == b.altMax
  )


func `$`*(path: Path): string =
  for elem in path:
    case elem.inStruct:
      of kTuple:
        result &= &"({elem.idx})"

      of kSeq:
        result &= "[pos]"

      of kAlt:
        result &= &"|{elem.altIdx}/{elem.altMax}|"

      of kPairs:
        result &= &"[{elem.key.repr}]"

      of kSet:
        result &= "{set}"

      of kObject:
        result &= &".{elem.field}"

      of kItem:
        result &= "<item>"


func `$`*(match: Match): string

func `$`*(kvp: KVPair): string =
  &"{kvp.key.repr}: {kvp.pattern}"


func `$`*(ss: SeqStructure): string =
  if ss.kind == lkSlice:
    result = &"{ss.repr}"
  else:
    result = $ss.kind


  if ss.bindVar.getSome(bv):
    result &= " " & bv.repr
  result &= " " & $ss.pattern



func `$`*(match: Match): string =
  case match.kind:
    of kAlt:
      result = match.altElements.mapIt($it).join(" | ")

    of kSeq:
      result = "[" & match.seqElements.mapIt($it).join(", ") & "]"

    of kTuple:
      result = "(" & match.tupleElements.mapIt($it).join(", ") & ")"

    of kPairs:
      result = "{" & match.pairElements.mapIt($it).join(", ") & "}"

    of kItem:
      case match.itemMatch:
        of imkInfixEq:
          if match.isPlaceholder:
            if match.isOptional:
              result = "opt "


            if match.bindVar.getSome(vn):
              result &= &"@{vn.repr}"

            else:
              result &= "_"

            if match.fallback.getSome(fallback):
              result &= &" or {fallback.toStrLit().strVal()}"


          else:
            result = &"{match.infix} {match.rhsNode.repr}"
        of imkSubPattern:
          result = $match.rhsPattern
        of imkPredicate:
          result = match.predBody.repr

    of kSet:
      result = "{" & match.setElements.mapIt($it).join(", ") & "}"

    of kObject:
      var kk: string
      if match.kindCall.getSome(kkn):
        kk = kkn.repr

      result = &"{kk}(" & match.fieldElements.mapIt(
        &"{it.name}: {it.pattern}").join(", ")

      if match.kvMatches.getSome(kvm):
        result &= $kvm

      if match.seqMatches.getSome(sm):
        result &= $sm

      result &= ")"


func isNamedTuple(node: NimNode): bool =
  template implies(a, b: bool): bool = (if a: b else: true)
  node.allIt(it.kind in {
    nnkExprColonExpr, # `(field: )`
    nnkBracket, # `([])`
    nnkTableConstr # `{key: val}`
  }) and
  node.allIt((it.kind == nnkIdent) .implies (it.nodeStr == "_"))

func makeVarSet(
  varn: NimNode, expr: NimNode, vtable: VarTable, doRaise: bool): NimNode =
  varn.assertKind({nnkIdent})
  case vtable[varn.nodeStr()].varKind:
    of vkSequence:
      return quote do:
        `varn`.add `expr` ## Append item to sequence
        true

    of vkOption:
      return quote do:
        `varn` = some(`expr`) ## Set optional value
        true

    of vkSet:
      return quote do:
        `varn`.incl some(`expr`) ## Add element to set
        true

    of vkRegular:
      let wasSet = ident(varn.nodeStr() & "WasSet")
      let varStr = varn.toStrLit()
      let ln = lineIInfo(vtable[varn.nodeStr()].decl)
      let matchError =
        if doRaise and not debugWIP:
          quote do:
            when compiles($(`varn`)):
              {.line: `ln`.}:
                raise MatchError(
                  msg: "Match failure: capture '" & `varStr` &
                    "' is already set to '" & $(`varn`) &
                    "', and does not match with '" & $(`expr`) & "'."
                )
            else:
              {.line: `ln`.}:
                raise MatchError(
                  msg: "Match failure: capture '" & `varStr` &
                    "' is already set and new value does not match."
                )
         else:
           quote do:
             discard false


      if vtable[varn.nodeStr()].foundCount > 1:
        return quote do:
          if `wasSet`:
            if `varn` == `expr`:
              true
            else:
              if true:
                `matchError`
              false
          else:
            `varn` = `expr`
            `wasSet` = true
            true
      else:
        return quote do:
          `varn` = `expr`
          true

    of vkAlt:
      return quote do: # WARNING - for now I assume unification with
                       # alternative variables is not supported, but
                       # this might be either declared as invalid
                       # (most likely) or handled via some kind of
                       # convoluted logic that is yet to be
                       # determined.
        `varn` = some(`expr`)
        true

func toAccs*(path: Path, name: NimNode, pathForType: bool): NimNode =
  ## Convert path in object to expression for getting element at path.
  func aux(prefix: NimNode, top: Path): NimNode =
    let head = top[0]
    result = case head.inStruct:
      of kSeq:
        if pathForType:
          newCall("varOfIteration", prefix)
        else:
          nnkBracketExpr.newTree(prefix, top[0].pos)

      of kTuple:
        nnkBracketExpr.newTree(
          prefix, newCall("FieldIndex", newLit(top[0].idx)))

      of kObject:
        nnkDotExpr.newTree(prefix, ident head.field)

      of kPairs:
        nnkBracketExpr.newTree(prefix, head.key)

      of kItem, kAlt:
        prefix

      of kSet:
        raiseAssert(
          "Invalid access path: cannot create explicit access for set")

    if top.len > 1:
      result = result.aux(top[1 ..^ 1])


  result =
    if path.len > 0:
      name.aux(path.fullCopy())
    else:
      name


func parseMatchExpr*(n: NimNode): Match

func parseNestedKey(n: NimNode): Match =
  ## Unparse key-value pair with nested fields. `field: <pattern>` and
  ## `field1.subfield.subsubfield: <pattern>`. Lattern one is just
  ## shorthand for `(field1: (subfield: (subsubfield: <pattern>)))`.
  ## This function returns `(subfield: (subsubfield: <pattern>))` part
  ## - first key should be handled by caller.
  n.assertKind({nnkExprColonExpr})
  func aux(spl: seq[NimNode]): Match =
    case spl[0].kind:
      of nnkIdentKinds:
        if spl.len == 1:
          return n[1].parseMatchExpr()
        else:
          if spl[1].kind in nnkIdentKinds:
            return Match(
              kind: kObject,
              declNode: spl[0],
              fieldElements: @[
                (name: spl[1].nodeStr(), pattern: aux(spl[1 ..^ 1]))
              ])
          else:
            return Match(
              kind: kPairs,
              declNode: spl[0],
              pairElements: @[KVPair(
                key: spl[1][0], pattern: aux(spl[1 ..^ 1]))],
              nocheck: true
            )
      of nnkBracket:
        if spl.len == 1:
          return n[1].parseMatchExpr()
        else:
          if spl[1].kind in nnkIdentKinds:
            return Match(
              kind: kObject,
              declNode: spl[0],
              fieldElements: @[
                (name: spl[1].nodeStr(), pattern: aux(spl[1 ..^ 1]))
              ])
          else:
            return Match(
              kind: kPairs,
              declNode: spl[1],
              pairElements: @[KVPair(
                key: spl[1][0], pattern: aux(spl[1 ..^ 1]))],
              nocheck: true
            )
      else:
        error(
          "Malformed path access - expected either field name, " &
            "or bracket access ['key'], but found " &
            spl[0].toStrLit().strVal() &
            " of kind " & $spl[0].kind,
          spl[0]
        )

  return aux(n[0].splitDots())



func parseKVTuple(n: NimNode): Match =
  ## Parse key-value tuple for object access - object or tuple fields.
  if n[0].eqIdent("Some"):
    # Special case for `Some(@var)` - expanded into `isSome` check and some
    # additional cruft
    if not (n.len <= 2):
      error("Expected `Some(<pattern>)`", n)

    # n[1].assertKind({nnkPrefix})

    result = Match(kind: kObject, declNode: n, fieldElements: @{
      "isSome": Match(kind: kItem, itemMatch: imkInfixEq, declNode: n[0],
                      rhsNode: newLit(true), infix: "==")
    })

    if n.len > 1:
      result.fieldElements.add ("get", parseMatchExpr(n[1]))

    return

  elif n[0].eqIdent("None"):
    return Match(kind: kObject, declNode: n, fieldElements: @{
      "isNone": Match(kind: kItem, itemMatch: imkInfixEq, declNode: n[0],
                      rhsNode: newLit(true), infix: "==")
    })

  result = Match(kind: kObject, declNode: n)
  var start = 0 # Starting subnode for actual object fields
  if n.kind in {nnkCall, nnkObjConstr}:
    start = 1
    result.kindCall = some(n[0])

  for elem in n[start .. ^1]:
    case elem.kind:
      of nnkExprColonExpr:
        var str: string
        case elem[0].kind:
          of nnkIdentKinds, nnkDotExpr, nnkBracketExpr:
            let first = elem[0].firstDot()
            if first.kind == nnkIdent:
              str = first.nodeStr()

            else:
              error(
                "First field access element must be an identifier. " &
                  "For accessing int-indexable objects use [] subscript " &
                  "directly, like (" & first.repr & ")",
                first
              )

          else:
            error(
              "Malformed path access - expected either field name, " &
                "or bracket access, but found '" &
                elem[0].toStrLit().strVal() & "'" &
                " of kind " & $elem[0].kind,
              elem[0]
            )

        result.fieldElements.add((str, elem.parseNestedKey()))

      of nnkBracket, nnkStmtList:
        # `Bracket` - Special case for object access - allow omission of
        # parentesis, so you can write `ForStmt[@a, @b]` (which is very
        # useful when working with AST types)
        #
        # `StmtList` - second special case for writing list patterns,
        # allows to use treeRepr-like code.
        result.seqMatches = some(elem.parseMatchExpr())

      of nnkTableConstr:
        # Special case for matching key-value pairs (tables and other
        # objects implementing `contains` and `[]` operator)
        result.kvMatches = some(elem.parseMatchExpr())

      else:
        elem.assertKind({nnkExprColonExpr})

func contains(kwds: openArray[SeqKeyword], str: string): bool =
  for kwd in kwds:
    if eqIdent($kwd, str):
      return true

func parseSeqMatch(n: NimNode): seq[SeqStructure] =
  for elem in n:
    if elem.kind == nnkPrefix and elem[0].eqIdent(".."):
      elem[1].assertKind({nnkIdent})
      result.add SeqStructure(kind: lkTrail, pattern: Match(
        declNode: elem,
      ), decl: elem)

    elif
      # `^1 is <patt>`
      elem.kind == nnkInfix and elem[1].kind == nnkPrefix and
      elem[0].eqIdent("is") and elem[1][0].eqIdent("^") and
      elem[1][1].kind in nnkIntKinds
      :

      var res = SeqStructure(
        kind: lkSlice, slice: elem[1], decl: elem,
        pattern: parseMatchExpr(elem[2]),
      )

      res.bindVar = res.pattern.bindVar
      res.pattern.bindVar = none(NimNode)
      result.add res


    elif
      # `1 is <patt>`
      elem.kind == nnkInfix and
      elem[1].kind in nnkIntKinds and
      elem[0].eqIdent("is")
      :

      var res = SeqStructure(
        kind: lkSlice, slice: elem[1], decl: elem,
        pattern: parseMatchExpr(elem[2]),
      )

      res.bindVar = res.pattern.bindVar
      res.pattern.bindVar = none(NimNode)
      result.add res

    elif
      # `[0 .. 3 @head is Jstring()]`
      (elem.kind == nnkInfix and (elem[0].startsWith(".."))) or
      # `[(0 .. 3) @head is Jstring()]`
      (elem.kind == nnkCommand and elem[0].kind == nnkPar) or
      # `[0 .. 2 is 12]`
      (elem.kind == nnkInfix and
       elem[1].kind == nnkInfix and
       elem[1][0].startsWith("..")
      ):

      var dotInfix, rangeStart, rangeEnd, body: NimNode

      if elem.kind == nnkInfix:
        if elem.kind == nnkInfix and elem[1].kind == nnkInfix:
          # `0 .. 2 is 12`
          #             Infix
          # [0]            Ident is
          # [1]            Infix
          # [1][0]            [...] Ident
          # [1][1]            [...] IntLit
          # [1][2]            [...] IntLit
          # [2]            IntLit 12
          dotInfix = elem[1][0]
          rangeStart = elem[1][1]
          rangeEnd = elem[1][2]
          body = elem[2]
        else:
          # `0 .. 2 @a is 12`
          #             Infix
          # [0]            Ident ..
          # [1]            IntLit 0
          # [2]            Command
          # [2][0]            IntLit 2
          # [2][1]            Infix
          # [2][1][0]            [...] Ident
          # [2][1][1]            [...] Prefix
          # [2][1][2]            [...] IntLit
          dotInfix = ident elem[0].nodeStr()
          rangeStart = elem[1]
          rangeEnd = elem[2][0]
          body = elem[2][1]

      elif elem.kind == nnkCommand:
        # I wonder, why do we need pattern matching in stdlib?
        dotInfix = ident elem[0][0][0].nodeStr()
        rangeStart = elem[0][0][1]
        rangeEnd = elem[0][0][1]
        body = elem[1]
      # elif elem.kind == nnkInfix and :

      var res = SeqStructure(
        kind: lkSlice, slice: nnkInfix.newTree(
          dotInfix,
          rangeStart,
          rangeEnd
        ),
        pattern: parseMatchExpr(body),
        decl: elem
      )

      res.bindVar = res.pattern.bindVar
      res.pattern.bindVar = none(NimNode)
      result.add res

    else:
      func toKwd(node: NimNode): SeqKeyword =
        for (key, val) in {
          "any" : lkAny,
          "all" : lkAll,
          "opt" : lkOpt,
          "until" : lkUntil,
          "none" : lkNone,
          "pref" : lkPref
            }:
          if node.eqIdent(key):
            result = val
            break


      let topElem = elem
      var (elem, opKind) = (elem, lkPos)
      let seqKwds = [lkAny, lkAll, lkNone, lkOpt, lkUntil, lkPref]
      if elem.kind in {nnkCall, nnkCommand} and
         elem[0].kind in {nnkSym, nnkIdent} and
         elem[0].nodeStr() in seqKwds:
        opKind = toKwd(elem[0])
        elem = elem[1]
      elif elem.kind in {nnkInfix} and
           elem[1].kind in {nnkIdent}:

        if elem[1].nodeStr() in seqKwds:
          opKind = toKwd(elem[1])
          elem = nnkInfix.newTree(elem[0], ident "_", elem[2])

        else:
          if not elem[1].eqIdent("_"):
            error("Invalid node match keyword - " &
              elem[1].repr.codeFmt() & "",elem[1])

      var
        match = parseMatchExpr(elem)
        bindv = match.bindVar

      if opKind != lkPos:
        match.bindVar = none(NimNode)

      match.isOptional = opKind in {lkOpt}

      var it = SeqStructure(bindVar: bindv, kind: opKind, decl: topElem)
      it.pattern = match
      result.add(it)

func parseTableMatch(n: NimNode): seq[KVPair] =
  for elem in n:
    result.add(KVPair(
      key: elem[0],
      pattern: elem[1].parseMatchExpr()
    ))

func parseAltMatch(n: NimNode): Match =
  let
    lhs = n[1].parseMatchExpr()
    rhs = n[2].parseMatchExpr()

  var alts: seq[Match]
  if lhs.kind == kAlt: alts.add lhs.altElements else: alts.add lhs
  if rhs.kind == kAlt: alts.add rhs.altElements else: alts.add rhs
  result = Match(kind: kAlt, altElements: alts, declNode: n)

func splitOpt(n: NimNode): tuple[
  lhs: NimNode, rhs: Option[NimNode]] =

  n[0].assertKind({nnkIdent})
  if not n[0].eqIdent("opt"):
    error("Only `opt` is supported for standalone item matches", n[0])

  if not n.len == 2:
    error("Expected exactly one parameter for `opt`", n)

  if n[1].kind == nnkInfix:
    result.lhs = n[1][1]
    result.rhs = some n[1][2]
  else:
    result.lhs = n[1]

func isBrokenBracket(n: NimNode): bool =
  result = (
    n.kind == nnkCommand and
    n[1].kind == nnkBracket
  ) or
  (
    n.kind == nnkCommand and
    n[1].kind == nnkInfix and
    n[1][1].kind == nnkBracket and
    n[1][2].kind == nnkCommand
  )

func fixBrokenBracket(inNode: NimNode): NimNode =

  func aux(n: NimNode): NimNode =
    if n.kind == nnkCommand and n[1].kind == nnkBracket:
      # `A [1] -> A[1]`
      result = nnkBracketExpr.newTree(n[0])
      for arg in n[1]:
        result.add arg
    else:
      # It is possible to have something else ony if second part is
      # infix,

      # `Par [_] | Par [_]` gives ast like this (paste below). It ts
      # necessary to transform it into `Par[_] | Par[_]` - move infix
      # up in the AST and convert all brackets into bracket
      # expressions.

      #```
      #             Command
      # [0]            Ident Par
      # [1]            Infix
      # [1][0]            Ident |
      # [1][1]            Bracket
      # [1][1][0]            Ident _
      # [1][2]            Command
      # [1][2][0]            Ident Par
      # [1][2][1]            Bracket
      # [1][2][1][0]            Ident _
      #```
      var brac = nnkBracketExpr.newTree(n[0]) # First bracket head

      for arg in n[1][1]:
        brac.add arg

      result = nnkInfix.newTree(
        n[1][0], # Infix indentifier
        brac,
        aux(n[1][2]) # Everything else is handled recursively
      )


  result = aux(inNode)

func isBrokenPar(n: NimNode): bool =
  result = (
    n.kind == nnkCommand and
    n[1].kind in {nnkPar, nnkTupleConstr})



func fixBrokenPar(inNode: NimNode): NimNode =
  func aux(n: NimNode): NimNode =
    result = nnkCall.newTree(n[0])

    for arg in n[1]:
      result.add arg


  result = aux(inNode)

macro dumpIdxTree(n: untyped) {.used.} =
  echo n.idxTreeRepr()

func parseMatchExpr*(n: NimNode): Match =
  ## Parse match expression from nim node
  case n.kind:
    of nnkIdent, nnkSym, nnkIntKinds, nnkStrKinds, nnkFloatKinds:
      result = Match(kind: kItem, itemMatch: imkInfixEq, declNode: n)
      # Underscore placeholders are converted to always-true matches,
      # otherwise comparison is done using `==` operator. RHS node is
      # pasted without modification for primitive literals (strings,
      # integers, floats).
      if n == ident "_":
        result.isPlaceholder = true

      else:
        result.rhsNode = n
        result.infix = "=="

    of nnkPar, nnkTupleConstr: # Named or unnamed tuple
      if n.isNamedTuple(): # `(field1: ...)`
        result = parseKVTuple(n)

      elif n[0].kind == nnkInfix and n[0][0].eqIdent("|"):
        # `(Par (Infix (Ident "|") (IntLit 1) (IntLit 2)))`
        # `(1 | 2)`
        result = parseAltMatch(n[0])

      else: # Unnamed tuple `( , , , , )`
        if n.len == 1: # Tuple with single argument is most likely used as
                       # regular parens in order to change operator
                       # precendence.
          result = parseMatchExpr(n[0])

        else:
          result = Match(kind: kTuple, declNode: n)
          for elem in n:
            result.tupleElements.add parseMatchExpr(elem)

    of nnkPrefix: # `is Pattern()`, `@capture` or other prefix expression
      if n[0].nodeStr() in ["is", "of"]: # `is Pattern()`
        result = Match(
          kind: kItem, itemMatch: imkSubPattern,
          rhsPattern: parseMatchExpr(n[1]), declNode: n)

        if n[0].nodeStr() == "of" and result.rhsPattern.kind == kObject:
          result.rhsPattern.isRefKind = true

      elif n[0].nodeStr() == "@": # `@capture`
        n[1].assertKind({nnkIdent})
        result = Match(
          kind: kItem,
          itemMatch: imkInfixEq,
          isPlaceholder: true,
          bindVar: some(n[1]),
          declNode: n
        )

      else: # Other prefix expression, for example `== 12`
        result = Match(
          kind: kItem, itemMatch: imkInfixEq, infix: n[0].nodeStr(),
          rhsNode: n[1], declNode: n
        )

    of nnkBracket, nnkStmtList:
      # `[1,2,3]` - seq pattern in inline form or as seq of elements
      # (stmt list)
      result = Match(
        kind: kSeq, seqElements: parseSeqMatch(n), declNode: n)

    of nnkTableConstr: # `{"key": "val"}` - key-value matches
      result = Match(
        kind: kPairs, pairElements: parseTableMatch(n), declNode: n)

    of nnkCurly: # `{1, 2}` - set pattern
      result = Match(kind: kSet, declNode: n)
      for node in n:
        if node.kind in {nnkExprColonExpr}:
          error("Unexpected colon", node)

        case node.kind:
          of nnkIntKinds, nnkIdent, nnkSym:
            # Regular set element, `{1, 2}`, possibly with enum idents
            result.setElements.add Match(
              kind: kItem,
              itemMatch: imkInfixEq,
              rhsNode: node,
              declNode: node
            )

          of nnkInfix:
            if not node[0].eqIdent(".."):
              error(
                "Set patter expects infix `..`, but found " & node[0].repr, node)

            else:
              result.setElements.add Match(
                kind: kItem,
                itemMatch: imkInfixEq,
                rhsNode: node,
                declNode: node
              )

          else:
            error(
              &"Unexpected node kind in set pattern - {node.kind}", node)


    of nnkBracketExpr:
      result = Match(
        kindCall: some n[0],
        kind: kObject,
        declNode: n,
        seqMatches: some parseMatchExpr(
          nnkBracket.newTree(n[1..^1])
        )
      )

    elif n.kind in {nnkObjConstr, nnkCall, nnkCommand} and
         not n[0].eqIdent("opt"):
      # - Object pattern matches `Kind(field: expr)`
      # - Standalone calls `Kind()` - if no field matches is needed

      if n.isBrokenBracket():
        # Broken bracket expression that was written as `A [1]` and
        # subsequently parsed into
        # `(Command (Ident "A") (Bracket (IntLit 1)))`
        # when actually it was ment to be used as `A[1]`
        # `(BracketExpr (Ident "A") (IntLit 1))`
        result = parseMatchExpr(n.fixBrokenBracket())

      elif n.isBrokenPar():
        result = parseMatchExpr(n.fixBrokenPar())

      else:
        if n[0].kind == nnkPrefix:
          n[0][1].assertKind({nnkIdent}) # `@capture(<some-expression>)`
          result = Match(
            kind: kItem,
            itemMatch: imkPredicate,
            bindVar: some(n[0][1]),
            declNode: n,
            predBody: n[1]
          )

        elif n[0].kind == nnkDotExpr:
          if n[0][0].kind == nnkIdent and
             n[0][1].kind == nnkIdent and
             n[0][0].strVal() != "_":
            # `PureEnum.Value(<pattern>)` but not `_.call(<arguments>)`
            result = parseKvTuple(n)
            result.kindCall = some(n[0])

          else:
            var body = n
            var bindVar: Option[NimNode]
            if n[0][0].kind == nnkPrefix:
              n[0][0][1].assertKind({nnkIdent})
              bindVar = some(n[0][0][1])

              # Store name of the bound variable and then replace `_` with
              # `it` to make `it.call("arguments")`
              body[0][0] = ident("it")

            else: # `_.call("Arguments")`
              # `(DotExpr (Ident "_") (Ident "<function-name>"))`
              n[0][1].assertKind({nnkIdent, nnkOpenSymChoice})
              n[0][0].assertKind({nnkIdent, nnkOpenSymChoice})

              # Replace `_` with `it` to make `it.call("arguments")`
              body[0][0] = ident("it")

            result = Match(
              kind: kItem,
              itemMatch: imkPredicate,
              declNode: n,
              predBody: body,
              bindVar: bindVar
            )

        elif n.kind == nnkCall and n[0].eqIdent("_"):
          # `_(some < expression)`. NOTE - this is probably a
          # not-that-common use case, but I don't think explicitly
          # disallowing it will make things more intuitive.
          result = Match(
            kind: kItem,
            itemMatch: imkPredicate,
            declNode: n[1],
            predBody: n[1]
          )

        elif n.kind == nnkCall and
             n.len > 1 and
             n[1].kind == nnkStmtList:
          #```
          # BracketExpr:
          #   @head
          #   @typeParam
          #```

          if n[0].kind == nnkIdent:
            result = parseKVTuple(n)

          else:
            result = parseMatchExpr(n[0])
            result.seqMatches = some(parseMatchExpr(n[1]))

        else:
          result = parseKVTuple(n)

    elif (n.kind in {nnkCommand, nnkCall}) and n[0].eqIdent("opt"):
      # Separate handling of `opt @capture` expressions for sequence, field
      # and key-value pair matching.
      # Expected input has for of `opt @capture or default`
      # `(Command (Ident "opt") (Infix (Ident "or") (Prefix (Ident "@") (Ident "capture")) (IntLit 12)))`
      let (lhs, rhs) = splitOpt(n)
      result = lhs.parseMatchExpr()
      result.isOptional = true
      result.fallback = rhs

    elif n.kind == nnkInfix and n[0].eqIdent("|"):
      # `(true, true) | (false, false)`
      result = parseAltMatch(n)

    elif n.kind in {nnkInfix, nnkPragmaExpr}:
      n[1].assertKind({nnkPrefix, nnkIdent, nnkPragma})
      if n[1].kind in {nnkPrefix}:
        n[1][1].assertKind({nnkIdent})

      if n[0].nodeStr() == "is":
        # `@pattern is JString()`
        # `@head is 'd'`
        result = Match(
          kind: kItem, itemMatch: imkSubPattern,
          rhsPattern: parseMatchExpr(n[2]), declNode: n)

      elif n[0].nodeStr() == "of":
        result = Match(
          kind: kItem, itemMatch: imkSubPattern,
          rhsPattern: parseMatchExpr(n[2]), declNode: n)

        if n[0].nodeStr() == "of" and result.rhsPattern.kind == kObject:
          result.rhsPattern.isRefKind = true

      else:
        # `@a | @b`, `@a == 6`
        result = Match(
          kind: kItem, itemMatch: imkInfixEq,
          rhsNode: n[2],
          infix: n[0].nodeStr(), declNode: n)

        if result.infix == "or":
          result.isOptional = true
          result.fallback = some n[2]

      if n[1].kind == nnkPrefix: # WARNING
        result.bindVar = some(n[1][1])

    else:
      error(
        "Malformed DSL - found " & n.toStrLit().strVal() &
          " of kind " & $n.kind & ".", n)

func isVariadic(p: Path): bool = p.anyIt(it.isVariadic)

func isAlt(p: Path): bool =
  result = p.anyIt(it.inStruct == kAlt)

iterator altPrefixes(p: Path): Path =
  var idx = p.len - 1
  while idx >= 0:
    if p[idx].inStruct == kAlt:
      yield p[0 .. idx]
    dec idx

func isOption(p: Path): bool =
  p.anyIt(it.inStruct == kItem and it.isOpt)

func classifyPath(path: Path): VarKind =
  if path.isVariadic:
    vkSequence
  elif path.isOption():
    vkOption
  elif path.isAlt():
    vkAlt
  else:
    vkRegular



func addVar(tbl: var VarTable, vsym: NimNode, path: Path): void =
  ## Register addition of variable `vsym` used at `path` to symbol table
  ## `tbl`. This might also update resulting variable type (when capture
  ## have been encountered in all alternative branches).
  let vs = vsym.nodeStr()
  let class = path.classifyPath()

  if vs notin tbl:
    tbl[vs] = VarSpec(decl: vsym, varKind: class, typePath: path.fullCopy())

  else:
    var doUpdate =
      (class == vkSequence) or
      (class == vkOption and tbl[vs].varKind in {vkRegular})

    if doUpdate:
      tbl[vs].varKind = class
      tbl[vs].typePath = path.fullCopy()

  if class == vkAlt and tbl[vs].varKind == vkAlt:
    for prefix in path.altPrefixes():
      let noalt = prefix[0 .. ^2]
      if noalt notin tbl[vs].prefixMap:
        tbl[vs].prefixMap[noalt] = AltSpec(altMax: prefix[^1].altMax.int16)

      var spec = tbl[vs].prefixMap[noalt]
      spec.altPositions.incl prefix[^1].altIdx.int16
      if spec.altPositions.len == spec.altMax + 1:
        spec.completed = true

      if spec.completed:
        tbl[vs] = VarSpec(
          decl: vsym,
          varKind: vkRegular,
          typePath: path.fullCopy()
        )

      else:
        tbl[vs].prefixMap[noalt] = spec


  inc tbl[vs].foundCount

func correctPathForOptionalField(
  sub: Match, vt: var VarTable, pattern: Match, path: Path) =

  if pattern.isOptional and pattern.bindVar.isSome():
    let name = pattern.bindVar.get().toStrLit().strVal()
    let spec = vt[name]

    if pattern.fallback.isNone():
      vt[name] = VarSpec(
        varKind: spec.varKind,
        decl: spec.decl,
        foundCount: spec.foundCount,
        typePath: spec.typePath,
      )

    else:
      vt[name] = VarSpec(
        varKind: spec.varKind,
        decl: spec.decl,
        foundCount: spec.foundCount,
        typePath: spec.typePath & @[
          AccsElem(inStruct: kObject, field: "get")],
      )


func makeVarTable(m: Match):
  tuple[table: VarTable, mixident: seq[string]] =

  func aux(sub: Match, vt: var VarTable, path: Path): seq[string] =
    if sub.bindVar.getSome(bindv):
      if sub.isOptional and sub.fallback.isNone():
        vt.addVar(bindv, path.fullCopy() & @[
          AccsElem(inStruct: kItem, isOpt: true)
        ])

      else:
        vt.addVar(bindv, path.fullCopy())

    case sub.kind:
      of kItem:
        if sub.itemMatch == imkInfixEq and
           sub.isPlaceholder and
           sub.bindVar.isNone()
          :
          result &= "_"

        if sub.itemMatch == imkSubPattern:
          if sub.rhsPattern.kind == kObject and
             sub.rhsPattern.isRefKind and
             sub.rhsPattern.kindCall.getSome(kk)
            :
            result &= aux(sub.rhsPattern, vt, path.fullCopy() & @[
              AccsElem(inStruct: kObject, field: kk.repr)])

          else:
            result &= aux(sub.rhsPattern, vt, path.fullCopy())


      of kSet:
        discard

      of kAlt:
        for idx, alt in sub.altElements:
          result &= aux(alt, vt, path.fullCopy() & @[AccsElem(
            inStruct: kAlt,
            altIdx: idx,
            altMax: sub.altElements.len - 1
          )])

      of kSeq:
        for elem in sub.seqElements:
          let parent = path.fullCopy() & @[AccsElem(
            inStruct: kSeq, pos: newLit(0),
            isVariadic: elem.kind notin {lkPos, lkOpt})]

          if elem.bindVar.getSome(bindv):
            if elem.pattern.isOptional and elem.pattern.fallback.isNone():
              vt.addVar(bindv, parent.fullCopy() & @[
                AccsElem(inStruct: kItem, isOpt: true)
              ])
            else:
              vt.addVar(bindv, parent)

          result &= aux(elem.pattern, vt, parent)

      of kTuple:
        for idx, it in sub.tupleElements:
          result &= aux(it, vt, path.fullCopy() & @[
            AccsElem(inStruct: kTuple, idx: idx)])

          correctPathForOptionalField(sub, vt, it, path)


      of kPairs:
        for pair in sub.pairElements:
          result &= aux(pair.pattern, vt, path.fullCopy() & @[
            AccsElem(inStruct: kPairs, key: pair.key)])

      of kObject:
        for (field, pattern) in sub.fieldElements:
          result &= aux(
            pattern, vt, path.fullCopy() & @[
              AccsElem(inStruct: kObject, field: field)])

          correctPathForOptionalField(sub, vt, pattern, path)

        if sub.seqMatches.getSome(seqm):
          result &= aux(seqm, vt, path.fullCopy())

        if sub.kvMatches.getSome(kv):
          result &= aux(kv, vt, path.fullCopy())


  result.mixident = aux(m, result.table, @[]).deduplicate()


func makeMatchExpr(
    m:                Match,
    vtable:           VarTable;
    path:             Path,
    typePath:         Path,
    mainExpr:         NimNode,
    doRaise:          bool,
    originalMainExpr: NimNode
  ): NimNode

proc makeElemMatch(
    elem:      SeqStructure, # Pattern for element match
    minLen:    var int,      # Required min len for object
    maxLen:    var int,      # Required max len for object
    doRaise:   bool,         # Raise exception on failed match?
    failBreak: var NimNode,  # Break of match chec loop
    posid:     NimNode,      # Identifier for current position in sequence match
    vtable:    VarTable,     # Table of variables
    parent:    Path,         # Path to parent node
    expr:      NimNode,      # Expression to check for pattern match
    getLen:    NimNode,      # Get expression len
    elemId:    NimNode,      # Main loop variable
    idx:       int,
    counter:   NimNode,
    seqm:      Match
  ): tuple[
    body: NimNode, # Body of matching block
    statevars: seq[tuple[varid, init: NimNode]], # Additional state variables
    defaults: seq[NimNode] # Default `opt` setters
  ] =

  result.body = newStmtList()


  result.body.add newCommentStmtNode(
    $elem.kind & " " & elem.pattern.declNode.repr)

  let parent: Path = @[]
  let mainExpr = elemId

  let patternStr = newLit(elem.decl.toStrLit().strVal())
  case elem.kind:
    of lkPos:
      inc minLen
      inc maxLen
      let ln = elem.decl.lineIInfo()
      if doRaise and not debugWIP:
        var str = newNimNode(nnkRStrLit)
        str.strVal = "Match failure for pattern '" & patternStr.strVal() &
            "'. Item at index "

        failBreak = quote do:
          {.line: `ln`.}:
            raise MatchError(msg: `str` & $(`posid` - 1) & " failed")

      var varset = newStmtList()
      if elem.bindVar.getSome(bindv):
        result.body.add newCommentStmtNode(
          "Set variable " & bindv.nodeStr() & " " &
            $vtable[bindv.nodeStr()].varKind)

        let vars = makeVarSet(
          bindv, parent.toAccs(mainExpr, false), vtable, doRaise)

        varset.add quote do:
          if not `vars`:
            `failBreak`

      if elem.pattern.kind == kItem and
         elem.pattern.itemMatch == imkInfixEq and
         elem.pattern.isPlaceholder:
        result.body.add quote do:
          `varSet`
          inc `counter`
          inc `posid`
          continue
      else:
        result.body.add quote do:
          if `expr`:
            inc `counter`
            inc `posid`
            continue

          else:
            `failBreak`

    else:
      if elem.kind == lkSlice:
        case elem.slice.kind:
          of nnkIntKinds:
            maxLen = max(maxLen, elem.slice.intVal.int + 1)
            minLen = max(minLen, elem.slice.intVal.int + 1)

          of nnkInfix:
            if elem.slice[1].kind in nnkIntKinds and
               elem.slice[2].kind in nnkIntKinds:

              let diff = if elem.slice[0].strVal == "..": +1 else: 0


              maxLen = max([
                maxLen,
                elem.slice[1].intVal.int,
                elem.slice[2].intVal.int + diff
              ])

              minLen = max(minLen, elem.slice[1].intVal.int)

            else:
              maxLen = 5000

          else:
            maxLen = 5000

        # echov elem.kind
        # echov maxLen
        # echov minLen

      else:
        maxLen = 5000

      var varset = newEmptyNode()

      if elem.bindVar.getSome(bindv):
        varset = makeVarSet(
          bindv, parent.toAccs(mainExpr, false), vtable, doRaise)
        # vtable.addVar(bindv, parent) # XXXX

      let ln = elem.decl.lineIInfo()
      if doRaise and not debugWIP:
        case elem.kind:
          of lkAll:
            failBreak = quote do:
              {.line: `ln`.}:
                raise MatchError(
                  msg: "Match failure for pattern '" & `patternStr` &
                    "' expected all elements to match, but item at index " &
                    $(`posid` - 1) & " failed"
                )

          of lkAny:
            failBreak = quote do:
              {.line: `ln`.}:
                raise MatchError(
                  msg: "Match failure for pattern '" & `patternStr` &
                    "'. Expected at least one elemen to match, but got none"
                )

          of lkNone:
            failBreak = quote do:
              {.line: `ln`.}:
                raise MatchError(
                  msg: "Match failure for pattern '" & `patternStr` &
                    "'. Expected no elements to match, but index " &
                    $(`posid` - 1) & " matched."
                )

          of lkSlice:
            let positions = elem.slice.toStrLit().codeFmt()
            failBreak = quote do:
              {.line: `ln`.}:
                raise MatchError(
                  msg: "Match failure for pattern '" & `patternStr` &
                    "'. Elements for positions " & `positions` &
                    " were expected to match no elements to match"
                )

          else:
            discard

      if varset.kind == nnkEmpty:
        varset = newLit(true)

      case elem.kind:
        of lkAll:
          # let allOk = genSym(nskVar, "allOk")
          # result.statevars.add (allOk, newLit(true))
          result.body.add quote do:
            block:
              # If iteration value matches pattern, and all variables can
              # be set, continue iteration. Otherwise fail (`all`) is a
              # greedy patter - mismatch on single element would mean
              # failure for whole sequence pattern
              if `expr` and `varset`:
                discard

              else:
                `failBreak`

        of lkSlice:
          var rangeExpr = elem.slice
          # echov rangeExpr.idxTreeRepr()
          if rangeExpr.kind in {nnkPrefix} + nnkIntKinds:
            result.body.add quote do:
              if `expr` and `varset`:
                discard

              else:
                `failBreak`

              inc `counter`

          else:
            result.body.add quote do:
              if `posid` in `rangeExpr`:

                if `expr` and `varset`:
                  discard

                else:
                  `failBreak`

              else:
                inc `counter`

        of lkUntil:
          result.body.add quote do:
            if `expr`:
              # After finishing `until` increment counter
              inc `counter`
            else:
              discard `varset`

          if idx == seqm.seqElements.len - 1:
            # If `until` is a last element we need to match if fully
            result.body.add quote do:
              if (`posid` < `getLen`): ## Not full match
                `failBreak`

        of lkAny:
          let state = genSym(nskVar, "anyState")
          result.statevars.add (state, newLit(false))

          result.body.add quote do:
            block:
              if `expr` and `varset`:
                `state` = true

              else:
                if (`posid` == `getLen` - 1):
                  if not `state`:
                    `failBreak`

        of lkPref:
          result.body.add quote do:
            if `expr`:
              discard `varset`
            else:
              inc `counter`

        of lkOpt:
          let state = genSym(nskVar, "opt" & $idx & "State")
          result.statevars.add (state, newLit(false))

          if elem.pattern.isOptional and
             elem.bindVar.getSome(bindv) and
             elem.pattern.fallback.getSome(fallback):

            let default = makeVarSet(bindv, fallback, vtable, doRaise)

            result.defaults.add quote do:
              if not `state`:
                discard `default`

          result.body.add quote do:
            discard `varset`
            `state` = true

            inc `counter`
            inc `posid`
            continue

        of lkNone:
          result.body.add quote do:
            block:
              if (not `expr`) and `varset`:
                discard
              else:
                `failBreak`

        of lkTrail, lkPos:
          discard





func makeSeqMatch(
    seqm: Match, vtable: VarTable; path: Path,
    mainExpr: NimNode,
    doRaise: bool,
    originalMainExpr: NimNode
  ): NimNode =

  var idx = 1
  while idx < seqm.seqElements.len:
    if seqm.seqElements[idx - 1].kind notin {
      lkUntil, lkPos, lkOpt, lkPref, lkSlice}:
      error("Greedy seq match must be last element in pattern",
            seqm.seqElements[idx].decl)

    inc idx

  let
    posid     = genSym(nskVar, "pos")
    matched   = genSym(nskVar, "matched")
    failBlock = ident("failBlock")
    getLen    = newCall("len", path.fullCopy().toAccs(mainExpr, false))

  var failBreak = nnkBreakStmt.newTree(failBlock)


  result = newStmtList()
  var minLen = 0
  var maxLen = 0

  let counter = genSym(nskVar, "counter") # Current pattern counter
  let elemId = genSym(nskForVar, "elemId") # Main loop variable

  var loopBody = newStmtList()

  # Out-of-loop state variables
  var statevars = newStmtList()

  # Default valudes for `opt` matches
  var defaults = newStmtList()

  let successBlock = ident("successBlock")

  # Find necessary element size (fail-fast on `len` mismatch)
  for idx, elem in seqm.seqElements:
    let idLit = newLit(idx)
    if elem.kind == lkTrail:
      maxLen = 5000
      loopBody.add quote do:
        if `counter` == `idLit`:
          break `successBlock`

    else:
      var
        elemMainExpr = elemId
        parent: Path = path.fullCopy() & @[AccsElem(
          inStruct: kSeq, pos: posid,
          isVariadic: elem.kind notin {lkPos, lkOpt}
        )]

      if elem.kind == lkSlice and
         elem.slice.kind in (nnkIntKinds + {nnkPrefix}):
        parent[^1].isVariadic = false
        parent[^1].pos = elem.slice
        elemMainExpr = nnkBracketExpr.newTree(mainExpr, elem.slice)

      let
        expr: NimNode = elem.pattern.makeMatchExpr(
          vtable,
          # Passing empty path and overriding `mainExpr` for elemen access
          # in order to make all nested matches use loop variable
          path = @[],
          mainExpr = elemMainExpr,
          # Expression for type path must be unchanged
          typePath = parent,
          doRaise = false,
          # WARNING no detailed reporting for subpattern matching failure.
          # In order to get these I need to return failure string from each
          # element, which makes thing more complicated. It is not that
          # hard to just return `(bool, string)` or something similar, but
          # it would require quite annoying (albeit simple) redesign of the
          # whole code, to account for new expression types. Not impossible
          # though.

          # doRaise and (elem.kind notin {lkUntil, lkAny, lkNone})
          originalMainExpr = originalMainExpr
        )

      let (body, state, defsets) = makeElemMatch(
        elem      = elem,
        elemId    = elemId,
        minLen    = minLen,
        maxLen    = maxLen,
        doRaise   = doRaise,
        failBreak = failBreak,
        posid     = posid,
        vtable    = vtable,
        parent    = parent,
        expr      = expr,
        getLen    = getLen,
        idx       = idx,
        seqm      = seqm,
        counter   = counter
      )

      defaults.add defsets

      loopBody.add quote do:
        if `counter` == `idLit`:
          `body`

      for (varname, init) in state:
        statevars.add nnkVarSection.newTree(
          nnkIdentDefs.newTree(varname, newEmptyNode(), init))


  result.add loopBody


  let
    comment = newCommentStmtNode(seqm.declNode.repr)
    minNode = newLit(minLen)
    maxNode = newLit(maxLen)

  var setCheck: NimNode
  if maxLen >= 5000:
    setCheck = quote do:
      ## Check required len
      `getLen` < `minNode`

  else:
    setCheck = quote do:
      ## Check required len
      `getLen` notin `minNode` .. `maxNode`

  if doRaise and not debugWIP:
    var patternStr = seqm.declNode.toPatternStr()
    let ln = seqm.declNode.lineIInfo()
    let lenObj = path.fullCopy().toAccs(
      originalMainExpr, false).toStrLit().codeFmt()

    if maxLen >= 5000:
      failBreak = quote do:
        {.line: `ln`.}:
          raise MatchError(
            msg: "Match failure for pattern " & `patternStr` &
              "Expected at least " & $(`minNode`) &
              " elements, but " & (`lenObj`) &
              " has .len of " & $(`getLen`) & "."
          )

    else:
      failBreak = quote do:
        {.line: `ln`.}:
          raise MatchError(
            msg: "Match failure for pattern " & `patternStr` &
              "Expected length in range '" & $(`minNode`) & " .. " &
              $(`maxNode`) & "', but `" & (`lenObj`) &
              "` has .len of " & $(`getLen`) & "."
          )

  let tmpExpr = path.fullCopy().toAccs(mainExpr, false)

  result = quote do:
    # Main match loop
    for `elemId` in `tmpExpr`:
      `result`
      inc `posid`


  var str = seqm.declNode.toStrLit().strVal()
  if split(str, '\n').len > 1:
    str = "\n" & str

  let patternLiteral = newLit(str).codeFmt()

  let compileCheck =
    if debugWIP:
      newStmtList()

    else:
      quote do:
        when not compiles(((discard `tmpExpr`.len()))):
          static:
            error " no `len` defined for " & $typeof(`tmpExpr`) &
              " - needed to find number of elements for pattern " &
              `patternLiteral`

        when not compiles(((
          for item in items(`tmpExpr`):
            discard
        ))):
          static:
            error " no `items` defined for " & $typeof(`tmpExpr`) &
              " - iteration is require for pattern " &
              `patternLiteral`



  result = quote do:
    `comment`
    `compileCheck`
    var `matched` = false
    # Main expression of match

    # Failure block
    block `failBlock`:
      var `posid` = 0 ## Start seq match
      var `counter` = 0

      # Check for `len` first
      if `setCheck`:
        ## fail on seq len
        `failBreak`

      # State variable initalization
      `statevars`

      # Block for early successfuly return from iteration
      block `successBlock`:
        `result`

      `defaults`

      `matched` = true ## Seq match ok

    `matched`

  result = result.newPar().newPar()
  # echov result.repr


func makeOptionalFieldExprConditions(
    pattern: Match,
    path: Path,
    vtable: VarTable,
    mainExpr: NimNode,
    doRaise: bool,
    originalMainExpr: NimNode
  ): seq[NimNode] =

  if pattern.isOptional:
    var patternPath = path.fullCopy()

    # If fallback expression is present variable has type `T`, and
    # result has to be assigned from `<path>.get()` expression.
    # Otherwise optional field value is assigned as-is (hence empty
    # sequence)
    if pattern.fallback.isSome():
      patternPath &= AccsElem(inStruct: kObject, field: "get")

    let isSomeCheck = nnkInfix.newTree(
      ident "and",
      newCall("isSome", path.fullCopy().toAccs(mainExpr, false)),
      pattern.makeMatchExpr(
        vtable,
        patternPath,
        patternPath,
        mainExpr, doRaise, originalMainExpr
      )
    )

    if pattern.fallback.getSome(fallback):
      result.add nnkInfix.newTree(
        # Additional wrapper expression to execute fallback
        # assignment (always true) in case of missing value.
        ident "or",
        isSomeCheck,
        makeVarSet(pattern.bindVar.get(), fallback, vtable, doRaise)
      )

    else:
      result.add isSomeCheck


func makeMatchExpr(
    m: Match,
    vtable: VarTable;
    path: Path,
    typePath: Path,
    mainExpr: NimNode,
    doRaise: bool,
    originalMainExpr: NimNode
  ): NimNode =

  case m.kind:
    of kItem:
      let parent = path.fullCopy().toAccs(mainExpr, false)
      case m.itemMatch:
        of imkInfixEq, imkSubPattern:
          if m.itemMatch == imkInfixEq:
            if m.isPlaceholder:
              result = newLit(true)

            else:
              result = nnkInfix.newTree(ident m.infix, parent, m.rhsNode)

          else:
            result = makeMatchExpr(
              m.rhsPattern, vtable,
              path.fullCopy(), path.fullCopy(), mainExpr, # Type path and access path are the same
              doRaise, originalMainExpr
            )

          if m.bindVar.getSome(vname):
            # vtable.addVar(vname, path) # XXXX
            let bindVar = makeVarSet(vname, parent, vtable, doRaise)
            if result == newLit(true):
              result = bindVar
            else:
              result = quote do:
                block:
                  if `result`:
                    `bindVar`
                  else:
                    false


        of imkPredicate:
          let pred = m.predBody
          var bindVar = newEmptyNode()
          if m.bindVar.getSome(vname):
            # vtable.addVar(vname, path) # XXXX
            bindVar = makeVarSet(vname, parent, vtable, doRaise)
          else:
            bindVar = newLit(true)

          result = quote do:
            block:
              let it {.inject.} = `parent`
              if `pred`:
                `bindVar`
              else:
                false

    of kSeq:
      return makeSeqMatch(
        m, vtable, path.fullCopy(), mainExpr, doRaise, originalMainExpr)

    of kTuple:
      var conds: seq[NimNode]
      for idx, it in m.tupleElements:
        let path = path.fullCopy() & @[AccsElem(inStruct: kTuple, idx: idx)]

        if it.isOptional:
          conds.add makeOptionalFieldExprConditions(
            it, path, vtable, mainExpr, doRaise, originalMainExpr)

        else:
          conds.add it.makeMatchExpr(
            vtable, path.fullCopy(), path.fullCopy(), mainExpr, doRaise, originalMainExpr)

      result = conds.foldInfix("and")

    of kObject:
      var conds: seq[NimNode]
      var refCast: seq[AccsElem]
      if m.kindCall.getSome(kc):
        if m.isRefKind:
          # Derived object matching call
          conds.add newCall(
            "not",
            # Inject explicit `isNil` check (by default `of` does not perform it)
            newCall(ident "isNil", path.fullCopy().toAccs(mainExpr, false)))

          conds.add newCall(ident "of", path.fullCopy().toAccs(mainExpr, false), kc)
          refCast.add AccsElem(inStruct: kObject, field: kc.repr)

        else:
          # Insert call to helper `hasKind` implementation that handles
          # prefix optionality
          conds.add newCall(ident "hasKind", path.fullCopy().toAccs(mainExpr, false), kc)

      for (field, pattern) in m.fieldElements:
        let path = path.fullCopy() &
          refCast.fullCopy() &
          @[AccsElem(inStruct: kObject, field: field)]

        if pattern.isOptional:
          conds.add makeOptionalFieldExprConditions(
            pattern, path, vtable, mainExpr, doRaise, originalMainExpr)

        else:
          conds.add pattern.makeMatchExpr(
            vtable, path.fullCopy(), path.fullCopy(), mainExpr, doRaise, originalMainExpr)

      if m.seqMatches.getSome(seqm):
        conds.add seqm.makeMatchExpr(
          vtable, path.fullCopy(), path.fullCopy(), mainExpr, doRaise, originalMainExpr)

      if m.kvMatches.getSome(kv):
        conds.add kv.makeMatchExpr(
          vtable, path.fullCopy(), path.fullCopy(), mainExpr, doRaise, originalMainExpr)

      result = conds.foldInfix("and")

    of kPairs:
      var conds: seq[NimNode]
      for pair in m.pairElements:
        let
          accs = path.fullCopy().toAccs(mainExpr, false)
          valPath = path.fullCopy() & @[AccsElem(
            inStruct: kPairs, key: pair.key, nocheck: m.nocheck)]

          valGet = valPath.fullCopy().toAccs(mainExpr, false)

        if m.nocheck:
          conds.add pair.pattern.makeMatchExpr(
            vtable, valPath.fullCopy(),
            valPath.fullCopy(), mainExpr, doRaise,
            originalMainExpr
          )

        else:
          let
            incheck = nnkInfix.newTree(ident "in", pair.key, accs).nilAccessCondition(accs)

          if not pair.pattern.isOptional:
            conds.add nnkInfix.newTree(
              ident "and", incheck,
              pair.pattern.makeMatchExpr(
                vtable, valPath.fullCopy(), valPath.fullCopy(),
                mainExpr, doRaise, originalMainExpr,
              )
            )

          else:
            let varn = pair.pattern.bindVar.get
            let varsetOk = makeVarSet(varn, valGet, vtable, doRaise)
            if pair.pattern.fallback.getSome(fallback):
              let varsetFail = makeVarSet(
                varn, fallback, vtable, doRaise)

              conds.add quote do:
                block:
                  if `incheck`:
                    `varsetOk`
                  else:
                    `varsetFail`
            else:
              conds.add quote do:
                if `incheck`:
                  `varsetOk`
                else:
                  true

      result = conds.foldInfix("and")

    of kAlt:
      var conds: seq[NimNode]
      for idx, alt in m.altElements:
        let path = path.fullCopy() & @[AccsElem(
          inStruct: kAlt,
          altIdx: idx,
          altMax: m.altElements.len - 1
        )]

        conds.add alt.makeMatchExpr(
         vtable, path.fullCopy(), path.fullCopy(), mainExpr, false, originalMainExpr)

      let res = conds.foldInfix("or")
      if not doRaise:
        return res

      else:
        let patternStr = m.declNode.toStrLit()
        return quote do:
          `res` or (block: raise MatchError(
            msg: "Match failure for pattern '" & `patternStr` &
              "' - None of the alternatives matched."
          ); true)

    of kSet:
      var testSet = nnkCurly.newTree()
      let setPath = path.fullCopy().toAccs(mainExpr, false)
      for elem in m.setElements:
        if elem.kind == kItem:
          testSet.add elem.rhsNode

      result = quote do:
        `setPath` in `testSet`

  if doRaise:
    let msgLit = newLit(
      "Pattern match failed: element does not match " &
        m.declNode.toPatternStr().strVal())

    result = quote do:
      `result` or ((block: raise MatchError(msg: `msgLit`) ; false))


func makeMatchExpr*(
    m: Match, mainExpr: NimNode,
    doRaise: bool, originalMainExpr: NimNode
  ): tuple[
    expr: NimNode, vtable: VarTable, mixident: seq[string]
  ] =

  ## Create NimNode for checking whether or not item referred to by
  ## `mainExpr` matches pattern described by `Match`

  (result.vtable, result.mixident) = makeVarTable(m)
  result.expr = makeMatchExpr(
    m, result.vtable, @[], @[], mainExpr, doRaise, originalMainExpr)

func toNode(
    expr: NimNode, vtable: VarTable, mainExpr: NimNode
  ): NimNode =

  var exprNew = nnkStmtList.newTree()
  var hasOption: bool = false
  for name, spec in vtable:
    let vname = ident(name)
    var typeExpr = toAccs(spec.typePath.fullCopy(), mainExpr, true)
    typeExpr = quote do:
      ((let tmp = `typeExpr`; tmp))

    var wasSet = newEmptyNode()
    if vtable[name].foundCount > 1:
      let varn = ident(name & "WasSet")
      wasSet = quote do:
        var `varn`: bool = false

    exprNew.add wasSet


    case spec.varKind:
      of vkSequence:
        block:
          let varExpr = toAccs(
            spec.typePath[0 .. ^2].fullCopy(), mainExpr, false)

          exprNew.add quote do:
            when not compiles(((discard `typeExpr`))):
              static: error $typeof(`varExpr`) &
                " does not support iteration via `items`"

        exprNew.add quote do:
          var `vname`: seq[typeof(`typeExpr`)]


      of vkOption, vkAlt:
        hasOption = true
        exprNew.add quote do:
          var `vname`: Option[typeof(`typeExpr`)]

      of vkSet:
        exprNew.add quote do:
          var `vname`: typeof(`typeExpr`)

      of vkRegular:
        exprNew.add quote do:
          var `vname`: typeof(`typeExpr`)

  result = quote do:
    `exprNew`
    `expr`

macro expand*(body: typed): untyped = body

proc matchImpl(n: NimNode): NimNode =
  var matchcase = nnkIfStmt.newTree()
  var mixidents: seq[string]
  let mainExpr = genSym(nskLet, "expr")
  for elem in n[1 .. ^1]:
    case elem.kind:
      of nnkOfBranch:
        if elem[0] == ident "_":
          error("To create catch-all match use `else` clause", elem[0])

        let (expr, vtable, mixid) =
          toSeq(elem[0 .. ^2]).foldl(
            nnkInfix.newTree(ident "|", a, b)
          ).parseMatchExpr().makeMatchExpr(mainExpr, false, n)

        mixidents.add mixid

        matchcase.add nnkElifBranch.newTree(
          toNode(expr, vtable, mainExpr).newPar().newPar(),
          elem[^1]
        )

      of nnkElifBranch, nnkElse:
        matchcase.add elem
      else:
        discard

  let head = n[0]
  var mixinList = newStmtList nnkMixinStmt.newTree(
    mixidents.deduplicate.mapIt(
      ident it
    )
  )

  if mixidents.len == 0:
    mixinList = newEmptyNode()

  let ln = lineIInfo(n[0])
  let posId = genSym(nskLet, "pos")
  result = quote do:
    block:
      {.line: `ln`.}:
        let `mainExpr` {.used.} = `head`

      let `posId` {.used.}: int = 0
      discard `posId`
      `matchcase`

when (NimMajor, NimMinor, NimPatch) >= (1,5,1):
  macro `case`*(n: untyped): untyped = matchImpl(n)
else:
  macro match*(n: untyped): untyped = matchImpl(n)

macro assertMatch*(input, pattern: untyped): untyped =
  ## Try to match `input` using `pattern` and raise `MatchError` on
  ## failure. For DSL syntax details see start of the document.
  let pattern =
    if pattern.kind == nnkStmtList and pattern.len == 1:
      pattern[0]
    else:
      pattern

  let
    expr = genSym(nskLet, "expr")
    (mexpr, vtable, _) = pattern.parseMatchExpr().makeMatchExpr(
      expr, true, input)

  let
    matched = toNode(mexpr, vtable, expr)


  result = quote do:
    let `expr` = `input`
    let ok = `matched`
    discard ok


macro matches*(input, pattern: untyped): untyped =
  ## Try to match `input` using `pattern` and return `false` on
  ## failure. For DSL syntax details see start of the document.
  let pattern =
    if pattern.kind == nnkStmtList and pattern.len == 1:
      pattern[0]
    else:
      pattern

  let
    expr = genSym(nskLet, "expr")
    (mexpr, vtable, _) = pattern.parseMatchExpr().makeMatchExpr(
      expr, false, input # .toStrLit().strVal()
    )

    matched = toNode(mexpr, vtable, expr)

  result = quote do:
    let `expr` = `input`
    `matched`

func buildTreeMaker(
  prefix: string,
  resType: NimNode,
  match: Match,
  newRes: bool = true,
  tmp = genSym(nskVar, "res")): NimNode =

  case match.kind:
    of kItem:
      if (match.itemMatch == imkInfixEq):
        if match.isPlaceholder:
          if match.bindVar.getSome(bindv):
            result = newIdentNode(bindv.nodeStr())
          else:
            error(
              "Only variable placeholders allowed for pattern " &
                "construction, but expression is a `_` placeholder - " &
                match.declNode.toStrLit().strVal().codeFmt()
              ,
              match.declNode
            )
        else:
          if match.rhsNode != nil:
            result = match.rhsNode
          else:
            error("Empty rhs node for item", match.declNode)
      else:
        error(
          "Predicate expressions are not supported for tree " &
          "construction, use `== <expression>` to set field result"
        )
    of kObject:
      var res = newStmtList()
      let tmp = genSym(nskVar, "res")

      res.add quote do:
        var `tmp`: `resType`
        when `tmp` is ref:
          new(`tmp`)

      if match.kindCall.getSome(call):
        let kind = ident call.nodeStr().addPrefix(prefix)
        res.add quote do:
          {.push warning[CaseTransition]: off.}
          when declared(FieldDefect):
            try:
              `tmp`.kind = `kind`
            except FieldDefect:
              raise newException(FieldDefect,
                "Error while setting `kind` for " & $typeof(`tmp`) &
                  " - type does not provide `kind=` override."
              )
          else:
            `tmp`.kind = `kind`
          {.pop.}

      else:
        error(
          "Named tuple construction is not supported. To Create " &
            "object use `Kind(f1: val1, f2: val2)`" ,
          match.declNode
        )

      for (name, patt) in match.fieldElements:
        res.add nnkAsgn.newTree(newDotExpr(
          tmp, ident name
        ), buildTreeMaker(prefix, resType, patt))

      if match.seqMatches.getSome(seqm):
        res.add buildTreeMaker(prefix, resType, seqm, false, tmp)
      # if match.seqMatches.isSome():
      #   for sub in match.seqMatches.get().seqElements:
      #     res.add newCall("add", tmp, buildTreeMaker(
      #       prefix, resType, sub.patt))

      res.add tmp

      result = newBlockStmt(res)
    of kSeq:
      var res = newStmtList()
      if newRes:
        res.add quote do:
          var `tmp`: seq[`resType`]

      for sub in match.seqElements:
        case sub.kind:
          of lkAll:
            if sub.bindVar.getSome(bindv):
              res.add quote do:
                for elem in `bindv`:
                  `tmp`.add elem
            elif sub.pattern.kind == kItem and
                 sub.pattern.itemMatch == imkInfixEq and
                 sub.pattern.infix == "==":
              let body = sub.pattern.rhsNode
              res.add quote do:
                for elem in `body`:
                  `tmp`.add elem

            else:
              error("`all` for pattern construction must have varaible",
                    sub.decl)
          of lkPos:
            res.add newCall("add", tmp, buildTreeMaker(
              prefix, resType, sub.pattern))
          else:
            raiseAssert("#[ IMPLEMENT ]#")

      if newRes:
        res.add quote do:
          `tmp`

      result = newBlockStmt(res)
    else:
      error(
        &"Pattern of kind {match.kind} is " &
          "not supported for tree construction",
        match.declNode
      )

func `kind=`*(node: var NimNode, kind: NimNodeKind) =
  node = newNimNode(kind, node)

func str*(node: NimNode): string = node.nodeStr()
func `str=`*(node: var NimNode, val: string) =
  if node.kind in {nnkIdent, nnkSym}:
    node = ident val
  else:
    node.strVal = val

func getTypeIdent(node: NimNode): NimNode =
  case node.getType().kind:
    of nnkObjectTy, nnkBracketExpr:
      newCall("typeof", node)
    else:
      node.getType()

macro makeTreeImpl(node, kind: typed, pattern: untyped): untyped =
  var inpattern = pattern
  if pattern.kind in {nnkStmtList}:
    if pattern.len > 1:
      inpattern = newStmtList(pattern.toSeq())
    else:
      inpattern = pattern[0]

  let (pref, _) = kind.getKindNames()

  var match = inpattern.parseMatchExpr()
  result = buildTreeMaker(pref, node.getTypeIdent(), match)

  if pattern.kind in {nnkStmtList} and
     pattern[0].len == 1 and
     match.kind == kSeq and
     pattern[0].kind notin {nnkBracket}
    :
    result = nnkBracketExpr.newTree(result, newLit(0))


template makeTree*(T: typed, pattern: untyped): untyped =
  ## Construct tree from pattern matching expression. For example of
  ## use see documentation at the start of the module
  block:
    var tmp: T
    when not compiles((var t: T; discard t.kind)):
      static: error "No `kind` defined for " & $typeof(tmp)

    when not compiles((var t: T; t.kind = t.kind)):
      static: error "Cannot set `kind=` for " & $typeof(tmp)

    when not compiles((var t: T; t.add t)):
      static: error "No `add` defined for " & $typeof(tmp)

    makeTreeImpl(tmp, tmp.kind, pattern)

template `:=`*(lhs, rhs: untyped): untyped =
  ## Shorthand for `assertMatch`
  assertMatch(rhs, lhs)

template `?=`*(lhs, rhs: untyped): untyped =
  ## Shorthand for `matches`
  matches(rhs, lhs)
