# Copyright (C) 2026 the Nim PubGrub authors. All rights reserved.
# BSD License. Look at license.txt for more info.

## A statement about one package: it is at some version in this set, or it is
## not.
##
## Terms are the atoms the solver reasons with. Which package a term is about
## is not stored here - incompatibilities key terms by package - so everything
## in this module is pure set algebra plus a sign.
##
## `VS` is any version set. It must provide `intersection`, `union`,
## `complement`, `difference` and `isEmpty`; `ranges.Ranges[V]` does. Keeping
## the solver generic over the *set* rather than over the version is what later
## allows a version type whose values do not all sit on one ordered line.

type
  Term*[VS] = object
    ## `positive`: the package is at a version in `versions`.
    ## not `positive`: the package is at a version outside `versions`, which
    ## includes not being selected at all.
    positive*: bool
    versions*: VS

  SetRelation* = enum
    srDisjoint     ## No assignment can satisfy both.
    srOverlapping  ## Neither implies nor contradicts the other.
    srSubset       ## Satisfying the first always satisfies the second.

proc positiveTerm*[VS](versions: VS): Term[VS] =
  Term[VS](positive: true, versions: versions)

proc negativeTerm*[VS](versions: VS): Term[VS] =
  Term[VS](positive: false, versions: versions)

proc allowed*[VS](t: Term[VS]): VS =
  ## The *versions* this term permits. A negative term permits everything its
  ## set excludes.
  ##
  ## Not the whole story: a negative term is also satisfied by the package not
  ## being selected at all, and that possibility has no version to name, so it
  ## cannot appear here. `relation` and `satisfies` account for it; comparing
  ## `allowed` sets directly does not.
  mixin complement
  if t.positive: t.versions else: complement(t.versions)

proc inverse*[VS](t: Term[VS]): Term[VS] =
  ## The term that is satisfied exactly when this one is not.
  Term[VS](positive: not t.positive, versions: t.versions)

proc isEmpty*[VS](t: Term[VS]): bool =
  ## Whether no assignment at all can satisfy this term.
  ##
  ## Only a positive term can be unsatisfiable. However much a negative term
  ## excludes, leaving the package out always satisfies it.
  mixin isEmpty
  t.positive and t.versions.isEmpty

proc intersect*[VS](a, b: Term[VS]): Term[VS] =
  ## The term satisfied exactly when both are.
  ##
  ## Two negatives stay negative - "not in a and not in b" is "not in a union
  ## b" - which keeps the term in the form the report will want to phrase it
  ## in. Any other combination collapses to a positive term.
  mixin intersection, union, difference
  if a.positive and b.positive:
    positiveTerm(intersection(a.versions, b.versions))
  elif not a.positive and not b.positive:
    negativeTerm(union(a.versions, b.versions))
  elif a.positive:
    positiveTerm(difference(a.versions, b.versions))
  else:
    positiveTerm(difference(b.versions, a.versions))

proc difference*[VS](a, b: Term[VS]): Term[VS] =
  ## The term satisfied when `a` is and `b` is not.
  intersect(a, b.inverse)

proc relation*[VS](a, b: Term[VS]): SetRelation =
  ## How `a` stands to `b`. This is the test unit propagation runs on every
  ## term of every incompatibility, so it is worth reading as the three
  ## questions it answers: does `a` force `b`, rule `b` out, or neither?
  ##
  ## The four sign combinations are spelled out rather than derived from
  ## `allowed`, because two of them turn on the possibility of the package
  ## being absent. A negative term admits absence and a positive one never
  ## does, so a negative term can never imply a positive one however much of
  ## the version line it covers - and two negative terms always share absence,
  ## so they are never disjoint.
  mixin isSubsetOf, isDisjointFrom
  if b.positive:
    if a.positive:
      if a.versions.isSubsetOf(b.versions): srSubset
      elif a.versions.isDisjointFrom(b.versions): srDisjoint
      else: srOverlapping
    else:
      if b.versions.isSubsetOf(a.versions): srDisjoint
      else: srOverlapping
  else:
    if a.positive:
      if a.versions.isDisjointFrom(b.versions): srSubset
      elif a.versions.isSubsetOf(b.versions): srDisjoint
      else: srOverlapping
    else:
      if b.versions.isSubsetOf(a.versions): srSubset
      else: srOverlapping

proc satisfies*[VS](a, b: Term[VS]): bool =
  ## Whether every assignment satisfying `a` also satisfies `b`.
  relation(a, b) == srSubset

proc `==`*[VS](a, b: Term[VS]): bool =
  a.positive == b.positive and a.versions == b.versions

proc `$`*[VS](t: Term[VS]): string =
  if t.positive: $t.versions else: "not " & $t.versions
