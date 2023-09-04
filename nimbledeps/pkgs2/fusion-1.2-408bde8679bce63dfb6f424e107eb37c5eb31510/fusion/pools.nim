#
#
#            Nim's Runtime Library
#        (c) Copyright 2020 Nim contributors
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## Pooled allocation for Nim. Usage:
##
## .. code-block:: nim
##
##   var p: Pool[MyObjectType]
##   var n0 = newNode(p)
##   var n1 = newNode(p)
##
## The destructor of `Pool` is resonsible for bulk-freeing
## every object constructed by the Pool. Pools cannot be
## copied.

from typetraits import supportsCopyMem

type
  Chunk[T] = object
    next: ptr Chunk[T]
    len: int
    elems: UncheckedArray[T]

  Pool*[T] = object ## A pool of 'T' nodes.
    len: int
    last: ptr Chunk[T]
    lastCap: int

proc `=destroy`*[T](p: var Pool[T]) =
  var it = p.last
  while it != nil:
    when not supportsCopyMem(T):
      for i in 0..<it.len:
        `=destroy`(it.elems[i])
    let next = it.next
    deallocShared(it)
    it = next

proc `=copy`*[T](dest: var Pool[T]; src: Pool[T]) {.error.}

proc newNode*[T](p: var Pool[T]): ptr T =
  if p.len >= p.lastCap:
    if p.lastCap == 0: p.lastCap = 4
    elif p.lastCap < 65_000: p.lastCap *= 2
    when not supportsCopyMem(T):
      let n = cast[ptr Chunk[T]](allocShared0(sizeof(Chunk[T]) + p.lastCap * sizeof(T)))
    else:
      let n = cast[ptr Chunk[T]](allocShared(sizeof(Chunk[T]) + p.lastCap * sizeof(T)))
    n.next = nil
    n.next = p.last
    p.last = n
    p.len = 0
  result = addr(p.last.elems[p.len])
  inc p.len
  inc p.last.len

when isMainModule:
  const withNonTrivialDestructor = false
  include prelude

  type
    NodeObj = object
      le, ri: Node
      when withNonTrivialDestructor:
        s: string
    Node = ptr NodeObj

  proc checkTree(n: Node): int =
    if n.le == nil: 1
    else: 1 + checkTree(n.le) + checkTree(n.ri)

  proc makeTree(p: var Pool; depth: int): Node =
    result = newNode(p)
    when withNonTrivialDestructor:
      result.s = $depth
    if depth == 0:
      result.le = nil
      result.ri = nil
    else:
      result.le = makeTree(p, depth-1)
      result.ri = makeTree(p, depth-1)

  proc main =
    let maxDepth = parseInt(paramStr(1))
    const minDepth = 4

    let stretchDepth = maxDepth + 1

    var longLived: Pool[NodeObj]
    let stree = makeTree(longLived, stretchDepth)
    echo("stretch tree of depth ", stretchDepth, "\t check:",
      checkTree stree)

    let longLivedTree = makeTree(longLived, maxDepth)
    var iterations = 1 shl maxDepth

    for depth in countup(minDepth, maxDepth, 2):
      var check = 0
      for i in 1..iterations:
        var shortLived: Pool[NodeObj]
        assert shortLived.len == 0
        check += checkTree(makeTree(shortLived, depth))

      echo iterations, "\t trees of depth ", depth, "\t check:", check
      iterations = iterations div 4

  let t = epochTime()
  #dumpAllocstats:
  main()
  echo("Completed in ", $(epochTime() - t), "s. Success! Peak mem ", formatSize getMaxMem())
  # use '21' as the command line argument
