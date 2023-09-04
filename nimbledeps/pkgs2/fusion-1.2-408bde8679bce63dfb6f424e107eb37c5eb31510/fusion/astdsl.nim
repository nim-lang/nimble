import macros, sets, strutils

const # normalized
  StmtContext = ["[]=", "add", "inc", "echo", "dec", "!", "expectkind",
                 "expectminlen", "expectlen", "expectident",
                 "error", "warning", "hint"]
  SpecialAttrs = ["intval", "floatval", "strval"]

var
  allnimnodes {.compileTime.}: HashSet[string]

proc isNimNode(x: string): bool {.compileTime.} =
  allnimnodes.contains(x)

proc addNodes() {.compileTime.} =
  for i in nnkEmpty..NimNodeKind.high:
    allnimnodes.incl normalize(substr($i, 3))
  allnimnodes.excl "ident"

static:
  addNodes()

proc getName(n: NimNode): string =
  case n.kind
  of nnkStrLit..nnkTripleStrLit, nnkIdent, nnkSym:
    result = n.strVal
  of nnkDotExpr:
    result = getName(n[1])
  of nnkAccQuoted, nnkOpenSymChoice, nnkClosedSymChoice:
    result = getName(n[0])
  else:
    expectKind(n, nnkIdent)

proc newDotAsgn(tmp: NimNode, key: string, x: NimNode): NimNode =
  result = newTree(nnkAsgn, newDotExpr(tmp, newIdentNode key), x)

proc tcall(n, tmpContext: NimNode): NimNode =
  case n.kind
  of nnkLiterals, nnkIdent, nnkSym, nnkDotExpr, nnkBracketExpr:
    if tmpContext != nil:
      result = newCall(bindSym"add", tmpContext, n)
    else:
      result = n
  of nnkForStmt, nnkIfExpr, nnkElifExpr, nnkElseExpr,
      nnkOfBranch, nnkElifBranch, nnkExceptBranch, nnkElse,
      nnkConstDef, nnkWhileStmt, nnkIdentDefs, nnkVarTuple:
    # recurse for the last son:
    result = copyNimTree(n)
    let len = n.len
    if len > 0:
      result[len-1] = tcall(result[len-1], tmpContext)
  of nnkStmtList, nnkStmtListExpr, nnkWhenStmt, nnkIfStmt, nnkTryStmt,
      nnkFinally, nnkBlockStmt, nnkBlockExpr:
    # recurse for every child:
    result = copyNimNode(n)
    for x in n:
      result.add tcall(x, tmpContext)
  of nnkCaseStmt:
    # recurse for children, but don't add call for case ident
    result = copyNimNode(n)
    result.add n[0]
    for i in 1 ..< n.len:
      result.add tcall(n[i], tmpContext)
  of nnkProcDef, nnkVarSection, nnkLetSection, nnkConstSection:
    result = n
  of nnkCallKinds:
    let op = normalize(getName(n[0]))
    if isNimNode(op):
      let tmp = genSym(nskLet, "tmp")
      let call = newCall(bindSym"newNimNode", ident("nnk" & op))
      result = newTree(
        if tmpContext == nil: nnkStmtListExpr else: nnkStmtList,
        newLetStmt(tmp, call))
      for i in 1 ..< n.len:
        let x = n[i]
        if x.kind == nnkExprEqExpr:
          let key = normalize(getName(x[0]))
          if key in SpecialAttrs:
            result.add newDotAsgn(tmp, key, x[1])
          else: error("Unsupported setter: " & key, x)
        else:
          result.add tcall(x, tmp)
      if tmpContext == nil:
        result.add tmp
      else:
        result.add newCall(bindSym"add", tmpContext, tmp)
    elif tmpContext != nil and op notin StmtContext:
      result = newCall(bindSym"add", tmpContext, n)
    elif op == "!" and n.len == 2:
      result = n[1]
    else:
      result = n
  else:
    result = n

macro buildAst*(node, children: untyped): NimNode =
  ## A DSL for convenient construction of Nim ASTs (of type NimNode).
  ## It composes with all of Nim's control flow constructs.
  ##
  ## *Note*: Check `The AST in Nim <macros.html#the-ast-in-nim>`_ section of
  ## `macros` module on how to construct valid Nim ASTs.
  ##
  ## Also see ``dumpTree``, ``dumpAstGen`` and ``dumpLisp``.
  runnableExamples:
    import macros

    macro hello(): untyped =
      result = buildAst(stmtList):
        call(bindSym"echo", newLit"Hello world")

    macro min(args: varargs[untyped]): untyped =
      result = buildAst(stmtListExpr):
        let tmp = genSym(nskVar, "minResult")
        expectMinLen(args, 1)
        newVarStmt(tmp, args[0])
        for i in 1..<args.len:
          ifStmt:
            elifBranch(infix(ident"<", args[i], tmp)):
              asgn(tmp, args[i])
        tmp

    assert min("d", "c", "b", "a") == "a"

  let kids = newProc(procType=nnkDo, body=children)
  expectKind kids, nnkDo
  var call: NimNode
  if node.kind in nnkCallKinds:
    call = node
  else:
    call = newCall(node)
  call.add body(kids)
  result = tcall(call, nil)
  when defined(debugAstDsl):
    echo repr(result)

macro buildAst*(children: untyped): NimNode =
  let kids = newProc(procType=nnkDo, body=children)
  expectKind kids, nnkDo
  result = tcall(body(kids), nil)
  when defined(debugAstDsl):
    echo repr(result)

when isMainModule:
  template templ1(e) {.dirty.} =
    var e = 2
    echo(e + 2)
  macro test1: untyped =
    let e = genSym(nskVar, "e")
    result = buildAst(stmtList):
      newVarStmt(e, newLit(2))
      call(ident"echo"):
        infix(ident("+"), e, intLit(intVal = 2))
    assert result == getAst(templ1(e))
  test1()

  template templ2 {.dirty.} =
    type Foo {.acyclic.} = object
  macro test2: untyped =
    result = buildAst(typeSection):
      typeDef:
        pragmaExpr(ident"Foo"):
          pragma(ident"acyclic")
        empty()
        objectTy:
          empty()
          empty()
          empty()
    assert result == getAst(templ2())
  test2()

  template templ3 {.dirty.} =
    proc bar(a, b: int): float = discard
  macro test3: untyped =
    template discardT = discard
    result = buildAst:
      procDef(ident"bar"):
        empty()
        empty()
        formalParams:
          ident"float"
          identDefs:
            ident"a"
            ident"b"
            ident"int"
            empty()
        empty()
        empty()
        stmtList(getAst(discardT()))
    assert result == getAst(templ3())
  test3()
