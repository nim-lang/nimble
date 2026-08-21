# Copyright (C) 2026 the Nim PubGrub authors. All rights reserved.
# BSD License. Look at license.txt for more info.

## A set of terms that can never all hold at once.
##
## Incompatibilities are the only facts the solver stores. A dependency
## "foo 1.0.0 needs bar ^2.0.0" is recorded as `{foo 1.0.0, not bar ^2.0.0}`:
## there is no world where foo is at 1.0.0 *and* bar is outside ^2.0.0. Stating
## everything in this one shape is what lets unit propagation and conflict
## resolution treat dependencies, missing versions and derived conclusions
## uniformly.
##
## Every incompatibility remembers where it came from. For the facts that is a
## `CauseKind`; for the ones conflict resolution derives it is the pair of
## incompatibilities they were resolved from, which turns the whole set into a
## DAG - the derivation graph the error report walks.
##
## At most one term per package: terms about the same package are intersected
## on construction, so `terms` is effectively a map keyed by package.

import ./term

type
  CauseKind* = enum
    ckNotRoot           ## The root package must be part of every solution.
    ckNoVersions        ## The provider offers no version inside the term's set.
    ckFromDependencyOf  ## The first term's package declares the second.
    ckDerivedFrom       ## Conflict resolution produced this from two others.

  PackageTerm*[P, VS] = object
    ## A `Term` plus the package it talks about.
    package*: P
    term*: Term[VS]

  Incompatibility*[P, VS] = ref object
    ## Reference semantics on purpose: the report identifies incompatibilities
    ## by identity when it decides which ones to number and cross-reference.
    terms*: seq[PackageTerm[P, VS]]
    case cause*: CauseKind
    of ckDerivedFrom:
      conflict*, other*: Incompatibility[P, VS]
    else: discard

proc positiveTerm*[P, VS](package: P, versions: VS): PackageTerm[P, VS] =
  ## "`package` is at some version in `versions`".
  PackageTerm[P, VS](package: package, term: positiveTerm(versions))

proc negativeTerm*[P, VS](package: P, versions: VS): PackageTerm[P, VS] =
  ## "`package` is at some version outside `versions`", which includes not
  ## being selected at all.
  PackageTerm[P, VS](package: package, term: negativeTerm(versions))

proc `==`*[P, VS](a, b: PackageTerm[P, VS]): bool =
  a.package == b.package and a.term == b.term

proc `$`*[P, VS](pt: PackageTerm[P, VS]): string =
  if pt.term.positive: $pt.package & " " & $pt.term.versions
  else: "not " & $pt.package & " " & $pt.term.versions

proc mergeSamePackage[P, VS](terms: seq[PackageTerm[P, VS]]):
    seq[PackageTerm[P, VS]] =
  ## Collapses terms about the same package into their intersection, keeping
  ## first-seen order. Incompatibilities hold a handful of terms at most, so
  ## the quadratic scan is cheaper than hashing and needs only `==` on `P`.
  for t in terms:
    var merged = false
    for i in 0 ..< result.len:
      if result[i].package == t.package:
        result[i].term = intersect(result[i].term, t.term)
        merged = true
        break
    if not merged:
      result.add t

proc newIncompatibility*[P, VS](terms: seq[PackageTerm[P, VS]],
                                cause: CauseKind): Incompatibility[P, VS] =
  ## A fact stated directly by the provider or by the solver's setup.
  doAssert cause != ckDerivedFrom,
    "use `derivedFrom` for incompatibilities produced by conflict resolution"
  Incompatibility[P, VS](terms: mergeSamePackage(terms), cause: cause)

proc derivedFrom*[P, VS](terms: seq[PackageTerm[P, VS]],
                         conflict, other: Incompatibility[P, VS],
                         root: P): Incompatibility[P, VS] =
  ## The conclusion conflict resolution draws from `conflict` and `other`.
  ##
  ## A positive term about the root package carries no information here - the
  ## root is in every solution by construction - so it is dropped, which is
  ## what lets resolution eventually reach the empty (failure) incompatibility
  ## instead of stalling on `{root 1.0.0}`.
  var kept = terms
  if kept.len != 1:
    var stripped: seq[PackageTerm[P, VS]]
    for t in kept:
      if not (t.term.positive and t.package == root):
        stripped.add t
    kept = stripped
  Incompatibility[P, VS](terms: mergeSamePackage(kept), cause: ckDerivedFrom,
                         conflict: conflict, other: other)

proc isFailure*[P, VS](inc: Incompatibility[P, VS], root: P): bool =
  ## Whether this incompatibility says the root package itself cannot be
  ## selected - the terminal state of conflict resolution.
  if inc.terms.len == 0: return true
  inc.terms.len == 1 and inc.terms[0].term.positive and
    inc.terms[0].package == root

proc sameTerms*[P, VS](a, b: Incompatibility[P, VS]): bool =
  ## Structural equality, used to avoid restating a fact the solver already
  ## knows when it revisits a version after backtracking.
  if a.cause != b.cause or a.terms.len != b.terms.len: return false
  for i in 0 ..< a.terms.len:
    if a.terms[i] != b.terms[i]: return false
  true

proc terse[P, VS](pt: PackageTerm[P, VS], root: P,
                  allowEvery = false): string =
  ## The root package is named bare: it is at one version by definition, so
  ## printing that version is noise in every sentence it appears in.
  mixin isFull
  if pt.package == root:
    $pt.package
  elif allowEvery and pt.term.versions.isFull:
    "every version of " & $pt.package
  else:
    $pt.package & " " & $pt.term.versions

proc describe*[P, VS](inc: Incompatibility[P, VS], root: P): string =
  ## The one-clause English rendering the report is built out of.
  ##
  ## Phrasing is chosen so that the sentence reads as a statement of fact
  ## rather than as the negation an incompatibility literally is: the reader
  ## should never have to think in terms of "these cannot all hold".
  mixin isFull
  case inc.cause
  of ckFromDependencyOf:
    if inc.terms.len == 2:
      return terse(inc.terms[0], root, allowEvery = true) & " depends on " &
        terse(inc.terms[1], root)
  of ckNoVersions:
    if inc.terms.len == 1:
      return "no versions of " & $inc.terms[0].package & " match " &
        $inc.terms[0].term.versions
  of ckNotRoot:
    if inc.terms.len == 1:
      return $inc.terms[0].package & " is " & $inc.terms[0].term.versions
  of ckDerivedFrom:
    discard

  if inc.isFailure(root): return "version solving failed"

  if inc.terms.len == 1:
    let t = inc.terms[0]
    let verb = if t.term.positive: " is forbidden" else: " is required"
    return terse(t, root, allowEvery = t.term.versions.isFull) & verb

  if inc.terms.len == 2 and
      inc.terms[0].term.positive == inc.terms[1].term.positive:
    if inc.terms[0].term.positive:
      let
        a = if inc.terms[0].term.versions.isFull: $inc.terms[0].package
            else: terse(inc.terms[0], root)
        b = if inc.terms[1].term.versions.isFull: $inc.terms[1].package
            else: terse(inc.terms[1], root)
      return a & " is incompatible with " & b
    else:
      return "either " & terse(inc.terms[0], root) & " or " & terse(inc.terms[1], root)

  var positive, negative: seq[string]
  for t in inc.terms:
    if t.term.positive: positive.add terse(t, root)
    else: negative.add terse(t, root)

  proc joined(parts: seq[string], sep: string): string =
    for i, p in parts:
      if i > 0: result.add sep
      result.add p

  if positive.len > 0 and negative.len > 0:
    if positive.len == 1:
      for t in inc.terms:
        if t.term.positive:
          return terse(t, root, allowEvery = true) & " requires " &
            joined(negative, " or ")
    return "if " & joined(positive, " and ") & " then " &
      joined(negative, " or ")
  elif positive.len > 0:
    return "one of " & joined(positive, " or ") & " must be false"
  else:
    return "one of " & joined(negative, " or ") & " must be true"
