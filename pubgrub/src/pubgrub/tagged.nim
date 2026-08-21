# Copyright (C) 2026 the Nim PubGrub authors. All rights reserved.
# BSD License. Look at license.txt for more info.

## Version sets over an ordered line *plus* a discrete dimension of tags.
##
## Some versions do not sit on the ordered line at all. A branch head or a
## commit pin has identity but no order: `#head` is not less than `1.2.0`, and
## two commits are not comparable to each other. Forcing them onto the line
## breaks the set algebra - `Ranges` assumes `<` is a total order - so this
## module keeps them in their own dimension. The universe is the disjoint
## union of an ordered version type `V` and a tag type `T` that only needs
## `==`.
##
## A set is a `Ranges[V]` over the line plus a finite or *cofinite* set of
## tags. Cofinite - "every tag except these" - because the tags of a real
## registry cannot be enumerated, and without it the complement of `{#head}`
## would not be representable. Every operation works componentwise, which is
## sound exactly because the union is disjoint.
##
## A range never contains a tag: `>= 1.0` covers the line only. Whether a
## requirement like `>= 1.0` should admit a pinned commit whose semantic
## version happens to match is a policy of the requirement *translation*, not
## of the algebra - a translator that wants that writes the tag into the set
## explicitly, which it can do whenever the package universe is known up
## front.

import std/strutils
import ./ranges

type
  TaggedVersionKind* = enum
    tvVersion  ## A point on the ordered line.
    tvTag      ## A tag: identity, no order.

  TaggedVersion*[V, T] = object
    ## A version in the two-dimensional universe - what the solver decides on
    ## when its `VS` is `TaggedRanges`.
    case kind*: TaggedVersionKind
    of tvVersion: version*: V
    of tvTag: tag*: T

  TaggedRanges*[V, T] = object
    ## `cofinite = false`: the tag part is exactly `tags`.
    ## `cofinite = true`: the tag part is every tag *except* `tags`.
    ## `tags` is kept deduplicated; its order carries no meaning.
    line*: Ranges[V]
    cofinite*: bool
    tags*: seq[T]

proc lineVersion*[V, T](v: V): TaggedVersion[V, T] =
  TaggedVersion[V, T](kind: tvVersion, version: v)

proc tagVersion*[V, T](t: T): TaggedVersion[V, T] =
  TaggedVersion[V, T](kind: tvTag, tag: t)

proc `==`*[V, T](a, b: TaggedVersion[V, T]): bool =
  if a.kind != b.kind: return false
  case a.kind
  of tvVersion: a.version == b.version
  of tvTag: a.tag == b.tag

proc `$`*[V, T](tv: TaggedVersion[V, T]): string =
  ## Tags render through `T`'s own `$`, so a translation that wants the `#`
  ## convention puts it in the tag value.
  case tv.kind
  of tvVersion: $tv.version
  of tvTag: $tv.tag

proc dedup[T](tags: seq[T]): seq[T] =
  for t in tags:
    if t notin result: result.add t

proc tagged*[V, T](line: Ranges[V], tags: seq[T] = @[],
                   cofinite = false): TaggedRanges[V, T] =
  TaggedRanges[V, T](line: line, cofinite: cofinite, tags: dedup(tags))

proc taggedEmpty*[V, T](): TaggedRanges[V, T] =
  TaggedRanges[V, T](line: emptyRange[V]())

proc taggedFull*[V, T](): TaggedRanges[V, T] =
  TaggedRanges[V, T](line: fullRange[V](), cofinite: true)

proc onlyTags*[V, T](tags: seq[T]): TaggedRanges[V, T] =
  TaggedRanges[V, T](line: emptyRange[V](), tags: dedup(tags))

proc singleton*[V, T](tv: TaggedVersion[V, T]): TaggedRanges[V, T] =
  case tv.kind
  of tvVersion:
    TaggedRanges[V, T](line: singleton(tv.version))
  of tvTag:
    TaggedRanges[V, T](line: emptyRange[V](), tags: @[tv.tag])

proc isEmpty*[V, T](s: TaggedRanges[V, T]): bool =
  s.line.isEmpty and not s.cofinite and s.tags.len == 0

proc isFull*[V, T](s: TaggedRanges[V, T]): bool =
  s.line.isFull and s.cofinite and s.tags.len == 0

proc contains*[V, T](s: TaggedRanges[V, T], tv: TaggedVersion[V, T]): bool =
  case tv.kind
  of tvVersion:
    s.line.contains(tv.version)
  of tvTag:
    if s.cofinite: tv.tag notin s.tags else: tv.tag in s.tags

proc complement*[V, T](s: TaggedRanges[V, T]): TaggedRanges[V, T] =
  TaggedRanges[V, T](line: complement(s.line), cofinite: not s.cofinite,
                     tags: s.tags)

proc intersection*[V, T](a, b: TaggedRanges[V, T]): TaggedRanges[V, T] =
  ## Componentwise. On the tag side the four finiteness combinations are:
  ## two finite sets share their common tags, a finite set loses whatever a
  ## cofinite one excludes, and two cofinite sets jointly exclude the union of
  ## their exclusions.
  result.line = intersection(a.line, b.line)
  if not a.cofinite and not b.cofinite:
    for t in a.tags:
      if t in b.tags: result.tags.add t
  elif not a.cofinite:
    for t in a.tags:
      if t notin b.tags: result.tags.add t
  elif not b.cofinite:
    for t in b.tags:
      if t notin a.tags: result.tags.add t
  else:
    result.cofinite = true
    result.tags = dedup(a.tags & b.tags)

proc union*[V, T](a, b: TaggedRanges[V, T]): TaggedRanges[V, T] =
  complement(intersection(complement(a), complement(b)))

proc difference*[V, T](a, b: TaggedRanges[V, T]): TaggedRanges[V, T] =
  intersection(a, complement(b))

proc isSubsetOf*[V, T](a, b: TaggedRanges[V, T]): bool =
  difference(a, b).isEmpty

proc isDisjointFrom*[V, T](a, b: TaggedRanges[V, T]): bool =
  intersection(a, b).isEmpty

proc sameTags[T](a, b: seq[T]): bool =
  ## Set equality over deduplicated sequences, using only `==` on `T`.
  if a.len != b.len: return false
  for t in a:
    if t notin b: return false
  true

proc `==`*[V, T](a, b: TaggedRanges[V, T]): bool =
  a.line == b.line and a.cofinite == b.cofinite and sameTags(a.tags, b.tags)

proc `$`*[V, T](s: TaggedRanges[V, T]): string =
  if s.isEmpty: return "<empty>"
  if s.isFull: return "*"
  var parts: seq[string]
  if not s.line.isEmpty:
    parts.add $s.line
  if s.cofinite:
    if s.tags.len == 0:
      parts.add "<any tag>"
    else:
      var excluded: seq[string]
      for t in s.tags: excluded.add $t
      parts.add "<any tag except " & excluded.join(", ") & ">"
  else:
    for t in s.tags:
      parts.add $t
  parts.join(" | ")
