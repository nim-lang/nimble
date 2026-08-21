# Copyright (C) 2026 the Nim PubGrub authors. All rights reserved.
# BSD License. Look at license.txt for more info.

## The solver's working state: an ordered list of assignments, plus the
## per-package summary of what they add up to.
##
## An assignment is either a *decision* - "I picked foo 1.2.0" - or a
## *derivation* - "some incompatibility forces foo into this set". Both are
## just terms; the difference is that a decision has no cause and so ends
## conflict resolution, while a derivation can be explained further.
##
## Two things make this more than a list. `positive`/`negative` cache the
## running intersection per package so `relation` is a lookup rather than a
## fold, and every assignment records the decision level it was made at so
## `backtrack` can undo an entire speculative branch at once.

import std/[tables, options]
import ./[term, incompatibility]

type
  AssignmentKind* = enum
    akDecision    ## A version was chosen. Has no cause.
    akDerivation  ## Forced by an incompatibility.

  Assignment*[P, V, VS] = object
    package*: P
    term*: Term[VS]
    decisionLevel*: int
      ## How many decisions had been made when this was assigned. Everything
      ## at a level above the one we backjump to is speculative and goes away.
    index*: int
      ## Position in `assignments`. Conflict resolution orders satisfiers by
      ## this to find the one that came last.
    case kind*: AssignmentKind
    of akDecision:
      version*: V
    of akDerivation:
      cause*: Incompatibility[P, VS]

  PartialSolution*[P, V, VS] = object
    assignments*: seq[Assignment[P, V, VS]]
    decisions*: OrderedTable[P, V]
    positive: OrderedTable[P, Term[VS]]
      ## Per package, the intersection of every positive assignment. Ordered so
      ## that decision making visits candidate packages deterministically.
    negative: Table[P, Term[VS]]
      ## Same, for packages that only have negative assignments so far. A
      ## package is in exactly one of the two tables, never both.
    attemptedSolutions*: int
      ## How many distinct candidate solutions have been started. Only useful
      ## as a progress signal.
    backtracking: bool

proc initPartialSolution*[P, V, VS](): PartialSolution[P, V, VS] =
  ## The empty solution. It already counts as one attempted solution: the
  ## counter answers "how many candidates did this take", and the first one
  ## starts here rather than at the first backtrack.
  PartialSolution[P, V, VS](attemptedSolutions: 1)

proc decisionLevel*[P, V, VS](s: PartialSolution[P, V, VS]): int =
  s.decisions.len

proc register[P, V, VS](s: var PartialSolution[P, V, VS],
                        a: Assignment[P, V, VS]) =
  ## Folds `a` into the per-package summary.
  ##
  ## Once a package has a positive term it stays positive: intersecting a
  ## positive with anything can only narrow it. A package with only negatives
  ## flips over as soon as an assignment makes the intersection positive.
  if s.positive.hasKey(a.package):
    s.positive[a.package] = intersect(s.positive[a.package], a.term)
    return
  let t =
    if s.negative.hasKey(a.package): intersect(a.term, s.negative[a.package])
    else: a.term
  if t.positive:
    s.negative.del a.package
    s.positive[a.package] = t
  else:
    s.negative[a.package] = t

proc assign[P, V, VS](s: var PartialSolution[P, V, VS],
                      a: Assignment[P, V, VS]) =
  s.assignments.add a
  s.register a

proc decide*[P, V, VS](s: var PartialSolution[P, V, VS], package: P, version: V,
                       versions: VS) =
  ## Records a choice. `versions` is the singleton set holding `version`; the
  ## solver builds it because only it knows how `VS` is constructed.
  ##
  ## A decision made straight after backtracking starts a new candidate
  ## solution. Consecutive backtracks without a decision in between are still
  ## the same candidate, hence the flag rather than a counter.
  if s.backtracking: inc s.attemptedSolutions
  s.backtracking = false
  s.decisions[package] = version
  s.assign Assignment[P, V, VS](
    package: package, term: positiveTerm(versions),
    decisionLevel: s.decisionLevel, index: s.assignments.len,
    kind: akDecision, version: version)

proc derive*[P, V, VS](s: var PartialSolution[P, V, VS], package: P,
                       versions: VS, positive: bool,
                       cause: Incompatibility[P, VS]) =
  s.assign Assignment[P, V, VS](
    package: package,
    term: Term[VS](positive: positive, versions: versions),
    decisionLevel: s.decisionLevel, index: s.assignments.len,
    kind: akDerivation, cause: cause)

proc backtrack*[P, V, VS](s: var PartialSolution[P, V, VS], level: int) =
  ## Undoes every assignment made above `level`.
  ##
  ## The summary tables cannot be un-intersected, so the affected packages are
  ## dropped and rebuilt from the assignments that survive. Only those packages
  ## are touched - the rest of the solution is untouched by the backjump.
  s.backtracking = true
  var touched: seq[P]
  while s.assignments.len > 0 and s.assignments[^1].decisionLevel > level:
    let removed = s.assignments.pop()
    if removed.package notin touched: touched.add removed.package
    if removed.kind == akDecision:
      s.decisions.del removed.package

  for p in touched:
    s.positive.del p
    s.negative.del p
  for a in s.assignments:
    if a.package in touched:
      s.register a

proc summary*[P, V, VS](s: PartialSolution[P, V, VS],
                        package: P): Option[Term[VS]] =
  ## Everything the solution says about `package` so far, if anything.
  if s.positive.hasKey(package): some(s.positive[package])
  elif s.negative.hasKey(package): some(s.negative[package])
  else: none(Term[VS])

proc relation*[P, V, VS](s: PartialSolution[P, V, VS], package: P,
                         t: Term[VS]): SetRelation =
  ## How the solution stands to `t`. A package nothing is known about is
  ## overlapping: it neither forces nor rules out anything.
  let known = s.summary(package)
  if known.isNone: srOverlapping
  else: relation(known.get, t)

proc satisfies*[P, V, VS](s: PartialSolution[P, V, VS], package: P,
                          t: Term[VS]): bool =
  s.relation(package, t) == srSubset

proc satisfier*[P, V, VS](s: PartialSolution[P, V, VS], package: P,
                          t: Term[VS]): Assignment[P, V, VS] =
  ## The earliest assignment such that the solution up to and including it
  ## already satisfies `t`.
  ##
  ## Not necessarily one that satisfies `t` by itself: `foo ^1.0.0` can be
  ## satisfied by `foo >=1.0.0` and `foo <2.0.0` together, in which case the
  ## satisfier is the second of the two.
  var acc: Option[Term[VS]]
  for a in s.assignments:
    if a.package != package: continue
    acc = some(if acc.isNone: a.term else: intersect(acc.get, a.term))
    if acc.get.satisfies(t): return a
  raise newException(ValueError,
    "[bug] the partial solution does not satisfy " & $t)

iterator unsatisfied*[P, V, VS](s: PartialSolution[P, V, VS]):
    tuple[package: P, versions: VS] =
  ## Packages the solution requires but has not decided on yet, in the order
  ## they were first required. These are exactly the candidates for the next
  ## decision.
  # Qualified: inside a generic iterator Nim binds overloaded symbols at the
  # instantiation site, and the module instantiating `solve` need not import
  # `std/tables` at all.
  for p, t in tables.pairs(s.positive):
    if not s.decisions.hasKey(p):
      yield (p, t.versions)

proc solution*[P, V, VS](s: PartialSolution[P, V, VS]):
    seq[tuple[package: P, version: V]] =
  for p, v in tables.pairs(s.decisions):
    result.add (p, v)
