# Copyright (C) 2026 the Nim PubGrub authors. All rights reserved.
# BSD License. Look at license.txt for more info.

## Sets of versions, represented as a sorted list of disjoint intervals.
##
## PubGrub's `Term` is a package plus a *set* of versions, and conflict
## resolution needs that set closed under union, intersection and complement.
## A single comparison operator on `V` is all this module asks for: it never
## enumerates versions, so `V` may be dense (semver with pre-releases) or
## sparse without changing anything here.
##
## The representation is canonical - segments are ordered, non-empty, disjoint
## and non-adjacent - so `==` is set equality and `isEmpty` is a length check.
## Canonicity is maintained by construction: every operation is derived from
## `complement` and `intersection`, both of which emit normalised output.

type
  BoundKind* = enum
    bkUnbounded  ## No limit on this side.
    bkIncluded   ## The value itself is in the set.
    bkExcluded   ## Everything up to (or past) the value, but not the value.

  Bound*[V] = object
    case kind*: BoundKind
    of bkUnbounded: discard
    of bkIncluded, bkExcluded:
      value*: V

  Interval*[V] = tuple[lower, upper: Bound[V]]

  Ranges*[V] = object
    ## A set of versions. Empty when `segments` is empty.
    segments*: seq[Interval[V]]

proc noBound*[V](): Bound[V] = Bound[V](kind: bkUnbounded)
proc inclBound*[V](v: V): Bound[V] = Bound[V](kind: bkIncluded, value: v)
proc exclBound*[V](v: V): Bound[V] = Bound[V](kind: bkExcluded, value: v)

proc cmpLower[V](a, b: Bound[V]): int =
  ## Orders two *lower* bounds by where the interval they open begins.
  if a.kind == bkUnbounded:
    return if b.kind == bkUnbounded: 0 else: -1
  if b.kind == bkUnbounded: return 1
  if a.value == b.value:
    if a.kind == b.kind: return 0
    # At the same value `[v` opens before `(v`.
    return if a.kind == bkIncluded: -1 else: 1
  return if a.value < b.value: -1 else: 1

proc cmpUpper[V](a, b: Bound[V]): int =
  ## Orders two *upper* bounds by where the interval they close ends.
  if a.kind == bkUnbounded:
    return if b.kind == bkUnbounded: 0 else: 1
  if b.kind == bkUnbounded: return -1
  if a.value == b.value:
    if a.kind == b.kind: return 0
    # At the same value `v)` closes before `v]`.
    return if a.kind == bkIncluded: 1 else: -1
  return if a.value < b.value: -1 else: 1

proc isValid[V](lower, upper: Bound[V]): bool =
  ## Whether an interval with these bounds can hold anything.
  ##
  ## `(v, v)` and `[v, v)` are empty, `[v, v]` is the singleton `v`. Two
  ## exclusive bounds around distinct values are treated as inhabited: whether
  ## `V` has a value strictly between them is not knowable from `<` alone, and
  ## assuming it does keeps the algebra sound for dense version types.
  if lower.kind == bkUnbounded or upper.kind == bkUnbounded: return true
  if lower.value == upper.value:
    return lower.kind == bkIncluded and upper.kind == bkIncluded
  lower.value < upper.value

proc flip[V](b: Bound[V]): Bound[V] =
  ## Turns a lower bound into the upper bound just below it, and vice versa.
  ## Never called on an unbounded side.
  case b.kind
  of bkIncluded: exclBound(b.value)
  of bkExcluded: inclBound(b.value)
  of bkUnbounded: b

proc emptyRange*[V](): Ranges[V] = Ranges[V](segments: @[])

proc fullRange*[V](): Ranges[V] =
  Ranges[V](segments: @[(noBound[V](), noBound[V]())])

proc singleton*[V](v: V): Ranges[V] =
  Ranges[V](segments: @[(inclBound(v), inclBound(v))])

proc atLeast*[V](v: V): Ranges[V] =
  ## `>= v`
  Ranges[V](segments: @[(inclBound(v), noBound[V]())])

proc greaterThan*[V](v: V): Ranges[V] =
  ## `> v`
  Ranges[V](segments: @[(exclBound(v), noBound[V]())])

proc atMost*[V](v: V): Ranges[V] =
  ## `<= v`
  Ranges[V](segments: @[(noBound[V](), inclBound(v))])

proc lessThan*[V](v: V): Ranges[V] =
  ## `< v`
  Ranges[V](segments: @[(noBound[V](), exclBound(v))])

proc between*[V](lo, hi: V): Ranges[V] =
  ## `>= lo & < hi`, the half-open interval every caret/tilde operator wants.
  if isValid(inclBound(lo), exclBound(hi)):
    Ranges[V](segments: @[(inclBound(lo), exclBound(hi))])
  else:
    emptyRange[V]()

proc interval*[V](lower, upper: Bound[V]): Ranges[V] =
  ## An arbitrary single interval, empty if the bounds do not admit anything.
  if isValid(lower, upper):
    Ranges[V](segments: @[(lower, upper)])
  else:
    emptyRange[V]()

proc isEmpty*[V](r: Ranges[V]): bool = r.segments.len == 0

proc isFull*[V](r: Ranges[V]): bool =
  r.segments.len == 1 and r.segments[0].lower.kind == bkUnbounded and
    r.segments[0].upper.kind == bkUnbounded

proc contains*[V](r: Ranges[V], v: V): bool =
  for seg in r.segments:
    let afterLower =
      case seg.lower.kind
      of bkUnbounded: true
      of bkIncluded: not (v < seg.lower.value)
      of bkExcluded: seg.lower.value < v
    if not afterLower: continue
    let beforeUpper =
      case seg.upper.kind
      of bkUnbounded: true
      of bkIncluded: not (seg.upper.value < v)
      of bkExcluded: v < seg.upper.value
    if beforeUpper: return true
  false

proc complement*[V](r: Ranges[V]): Ranges[V] =
  ## Everything `r` leaves out. The gaps between `r`'s segments, plus the tails
  ## on either end when `r` does not already reach them.
  if r.isEmpty: return fullRange[V]()

  var segments: seq[Interval[V]]
  let first = r.segments[0]
  if first.lower.kind != bkUnbounded:
    segments.add (noBound[V](), flip(first.lower))

  for i in 1 ..< r.segments.len:
    segments.add (flip(r.segments[i - 1].upper), flip(r.segments[i].lower))

  let last = r.segments[^1]
  if last.upper.kind != bkUnbounded:
    segments.add (flip(last.upper), noBound[V]())

  Ranges[V](segments: segments)

proc intersection*[V](a, b: Ranges[V]): Ranges[V] =
  ## Walks both segment lists in order, emitting the overlap of each pair and
  ## advancing whichever segment ends first.
  var
    segments: seq[Interval[V]]
    i, j = 0
  while i < a.segments.len and j < b.segments.len:
    let
      x = a.segments[i]
      y = b.segments[j]
      lower = if cmpLower(x.lower, y.lower) >= 0: x.lower else: y.lower
      upper = if cmpUpper(x.upper, y.upper) <= 0: x.upper else: y.upper
    if isValid(lower, upper):
      segments.add (lower, upper)
    if cmpUpper(x.upper, y.upper) <= 0: inc i else: inc j
  Ranges[V](segments: segments)

proc union*[V](a, b: Ranges[V]): Ranges[V] =
  ## De Morgan, which also coalesces adjacent segments for free: complementing
  ## `[1, 2)` and `[2, 3)` produces overlapping tails whose intersection is
  ## `(-inf, 1) | [3, inf)`, and complementing that back yields `[1, 3)`.
  complement(intersection(complement(a), complement(b)))

proc difference*[V](a, b: Ranges[V]): Ranges[V] =
  intersection(a, complement(b))

proc `==`*[V](a, b: Ranges[V]): bool =
  if a.segments.len != b.segments.len: return false
  for i in 0 ..< a.segments.len:
    if cmpLower(a.segments[i].lower, b.segments[i].lower) != 0: return false
    if cmpUpper(a.segments[i].upper, b.segments[i].upper) != 0: return false
  true

proc isSubsetOf*[V](a, b: Ranges[V]): bool =
  difference(a, b).isEmpty

proc isDisjointFrom*[V](a, b: Ranges[V]): bool =
  intersection(a, b).isEmpty

proc union*[V](ranges: openArray[Ranges[V]]): Ranges[V] =
  result = emptyRange[V]()
  for r in ranges:
    result = union(result, r)

proc `$`*[V](r: Ranges[V]): string =
  if r.isEmpty: return "<empty>"
  if r.isFull: return "*"
  for i, seg in r.segments:
    if i > 0: result.add " | "
    result.add:
      case seg.lower.kind
      of bkUnbounded: "(-inf"
      of bkIncluded: "[" & $seg.lower.value
      of bkExcluded: "(" & $seg.lower.value
    result.add ", "
    result.add:
      case seg.upper.kind
      of bkUnbounded: "inf)"
      of bkIncluded: $seg.upper.value & "]"
      of bkExcluded: $seg.upper.value & ")"

proc lowestVersion*[V](r: Ranges[V]): Bound[V] =
  ## The bound opening the set, for providers that pick a "best" version.
  if r.isEmpty: noBound[V]() else: r.segments[0].lower

proc sortedSegments*[V](r: Ranges[V]): seq[Interval[V]] =
  ## The canonical segment list. Exposed so a `VersionSet` implementation over
  ## a discrete version type can enumerate candidates.
  r.segments
