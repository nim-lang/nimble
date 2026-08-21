# Copyright (C) 2026 the Nim PubGrub authors. All rights reserved.
# BSD License. Look at license.txt for more info.

## The PubGrub loop: propagate, decide, repeat.
##
## The solver never enumerates candidate solutions. It keeps a set of
## incompatibilities - facts of the form "these terms cannot all hold" - and a
## partial solution. Unit propagation reads off everything the facts force
## given what has been assigned so far. When the facts turn out to contradict
## the partial solution, conflict resolution walks back through the derivations
## that caused it and distils a *new* incompatibility that is both true in
## general and strong enough to rule out the branch just tried. That derived
## fact is what stops the solver from rediscovering the same dead end, and it
## is also what the error report is built from when the derivation bottoms out
## in "the root package cannot be selected".
##
## The version universe is supplied by a *provider*: any type with the two
## procs below acting on it, bound at instantiation - so this module knows
## nothing about registries, files or how versions compare.
##
## ```nim
## proc chooseVersion(p: MyProvider, package: P, allowed: VS): Option[V]
##   ## The version of `package` to try next out of `allowed`, or `none` if the
##   ## set holds nothing. Preferring higher versions gives the usual "newest
##   ## that works" behaviour, but any total preference works.
## proc dependencies(p: MyProvider, package: P, version: V):
##     seq[Dependency[P, VS]]
##   ## What that exact version requires.
## ```
##
## Two further procs are optional hooks, named as such (the same convention as
## the compiler's `writelnHook`). They are matched by their exact signature at
## instantiation; a provider without them gets the default behaviour.
##
## ```nim
## proc dependencyRangeHook(p: MyProvider, package: P, version: V,
##                          dependency: Dependency[P, VS]): VS
##   ## Which versions of `package` declare exactly this dependency. When
##   ## absent, each dependency is stated for the one version it was read
##   ## from, which is always sound but weaker. Widening it to the
##   ## neighbouring versions that agree turns dozens of near-identical facts
##   ## into one and, more visibly, turns "foo 1.0.0 depends on bar ^2.0.0"
##   ## into "every version of foo depends on bar ^2.0.0" in the error report.
##   ## The returned set must contain `version` and must not contain a version
##   ## whose dependency on `dependency.package` differs.
## proc versionCountHook(p: MyProvider, package: P, allowed: VS): int
##   ## How many versions `allowed` admits. When absent, packages are decided
##   ## in the order they were first required. Supplying it lets the solver
##   ## decide the most constrained package first, which is what makes
##   ## conflicts surface early instead of after a deep wrong guess.
## ```

import std/[tables, options]
import ./[term, incompatibility, partialsolution]

export incompatibility, partialsolution, term

when defined(pubgrubDebug):
  ## `-d:pubgrubDebug` traces every fact, derivation, decision and conflict.
  ## The trace is the only practical way to follow a backtracking search, and
  ## it is what a differential test compares against another solver's log.
  template trace(msg: string) = debugEcho msg
else:
  template trace(msg: string) = discard

type
  Dependency*[P, VS] = tuple[package: P, versions: VS]

  SolveOutcome* = enum
    soSolved
    soUnsolvable

  SolveResult*[P, V, VS] = object
    attemptedSolutions*: int
      ## How many candidate solutions were started. 1 means no backtracking.
    case outcome*: SolveOutcome
    of soSolved:
      packages*: seq[tuple[package: P, version: V]]
        ## Every decided package, root included, in decision order.
    of soUnsolvable:
      failure*: Incompatibility[P, VS]
        ## The root cause: an incompatibility saying the root package itself
        ## cannot be selected. Feed it to `report` for the explanation.

  Solver[P, V, VS, DP] = ref object
    provider: DP
    root: P
    incompatibilities: Table[P, seq[Incompatibility[P, VS]]]
      ## Indexed by every package each incompatibility mentions, so
      ## propagation only revisits facts that could have become relevant.
    solution: PartialSolution[P, V, VS]

  PropagationKind = enum
    pkNone      ## Nothing new can be deduced.
    pkChanged   ## A term was derived; the named package needs another look.
    pkConflict  ## The partial solution satisfies the incompatibility.

proc addIncompatibility[P, V, VS, DP](s: Solver[P, V, VS, DP],
                                  inc: Incompatibility[P, VS]) =
  for pt in inc.terms:
    s.incompatibilities.mgetOrPut(pt.package, @[]).add inc

proc addFact[P, V, VS, DP](s: Solver[P, V, VS, DP], inc: Incompatibility[P, VS]):
    Incompatibility[P, VS] =
  ## Stores a fact, or returns the identical one already stored.
  ##
  ## After backtracking the solver re-derives the same dependencies from the
  ## same versions. Without this the incompatibility list would grow on every
  ## revisit and propagation would slow down for no gain. Only facts are
  ## deduplicated: incompatibilities from conflict resolution are distinct
  ## nodes in the derivation graph even when their terms coincide.
  if inc.terms.len > 0:
    for existing in s.incompatibilities.getOrDefault(inc.terms[0].package):
      if sameTerms(existing, inc): return existing
  s.addIncompatibility inc
  trace "fact: " & describe(inc, s.root)
  inc

proc propagateIncompatibility[P, V, VS, DP](s: Solver[P, V, VS, DP],
    inc: Incompatibility[P, VS]): tuple[kind: PropagationKind, package: P] =
  ## Checks one incompatibility against the partial solution.
  ##
  ## If every term is satisfied, the incompatibility is violated - a conflict.
  ## If exactly one term is undecided and the rest are satisfied, that term is
  ## forced false, so its inverse is derived. Anything less is no information:
  ## a contradicted term makes the incompatibility vacuously fine, and two
  ## undecided terms leave a choice.
  var
    unsatisfied: PackageTerm[P, VS]
    found = false
  for pt in inc.terms:
    case s.solution.relation(pt.package, pt.term)
    of srDisjoint:
      return (pkNone, default(P))
    of srOverlapping:
      if found: return (pkNone, default(P))
      unsatisfied = pt
      found = true
    of srSubset:
      discard

  if not found: return (pkConflict, default(P))

  s.solution.derive(unsatisfied.package, unsatisfied.term.versions,
                    not unsatisfied.term.positive, inc)
  trace "derived: " & $unsatisfied.term.inverse & " of " &
    $unsatisfied.package & " from " & describe(inc, s.root)
  (pkChanged, unsatisfied.package)

proc resolveConflict[P, V, VS, DP](s: Solver[P, V, VS, DP],
    incompat: Incompatibility[P, VS]): Incompatibility[P, VS] =
  ## Turns a violated incompatibility into one the solver can act on.
  ##
  ## Repeatedly replaces the term that was satisfied *last* with the terms of
  ## the incompatibility that forced it, which walks the derivation backwards.
  ## The loop stops as soon as the last satisfier is either a decision or the
  ## only assignment at its level: at that point backjumping to the level below
  ## leaves the result unsatisfied, so propagation can immediately derive from
  ## it and the solver is guaranteed to take a different branch. If the walk
  ## instead consumes every term, the conflict is unconditional and the caller
  ## gets a failure incompatibility.
  mixin isEmpty
  var
    inc = incompat
    derivedAny = false
  while not inc.isFailure(s.root):
    var
      mostRecentIndex = -1
      mostRecentSatisfier: Assignment[P, V, VS]
      diff: Term[VS]
      hasDiff = false
      previousSatisfierLevel = 1

    for i, pt in inc.terms:
      let satisfier = s.solution.satisfier(pt.package, pt.term)
      if mostRecentIndex < 0:
        mostRecentIndex = i
        mostRecentSatisfier = satisfier
      elif mostRecentSatisfier.index < satisfier.index:
        previousSatisfierLevel =
          max(previousSatisfierLevel, mostRecentSatisfier.decisionLevel)
        mostRecentIndex = i
        mostRecentSatisfier = satisfier
        hasDiff = false
      else:
        previousSatisfierLevel =
          max(previousSatisfierLevel, satisfier.decisionLevel)

      if mostRecentIndex == i:
        # The satisfier may only satisfy this term together with the
        # assignments before it - `foo ^1.0.0` needs both `foo >=1.0.0` and
        # `foo <2.0.0`. What it allows beyond the term has to be carried into
        # the derived incompatibility, or the conclusion would be too strong.
        diff = difference(mostRecentSatisfier.term, pt.term)
        hasDiff = not diff.versions.isEmpty
        if hasDiff:
          previousSatisfierLevel = max(previousSatisfierLevel,
            s.solution.satisfier(pt.package, diff.inverse).decisionLevel)

    if previousSatisfierLevel < mostRecentSatisfier.decisionLevel or
        mostRecentSatisfier.kind == akDecision:
      s.solution.backtrack(previousSatisfierLevel)
      if derivedAny: s.addIncompatibility inc
      return inc

    var newTerms: seq[PackageTerm[P, VS]]
    for i, pt in inc.terms:
      if i != mostRecentIndex: newTerms.add pt
    for pt in mostRecentSatisfier.cause.terms:
      if pt.package != mostRecentSatisfier.package: newTerms.add pt
    if hasDiff:
      newTerms.add PackageTerm[P, VS](package: mostRecentSatisfier.package,
                                      term: diff.inverse)

    inc = derivedFrom(newTerms, inc, mostRecentSatisfier.cause, s.root)
    derivedAny = true
  inc

proc propagate[P, V, VS, DP](s: Solver[P, V, VS, DP], package: P):
    Incompatibility[P, VS] =
  ## Derives everything the known facts force, starting from `package`.
  ## Returns nil, or the failure incompatibility if the facts are unsatisfiable.
  var changed = @[package]
  while changed.len > 0:
    let pkg = changed[0]
    changed.delete 0
    # A snapshot, not a view: conflict resolution adds to this very list, and
    # the newcomers are handled by the restart below rather than mid-loop.
    # Newest first, because conflict resolution tends to produce more general
    # incompatibilities over time and a more general fact prunes more.
    let known = s.incompatibilities.getOrDefault(pkg)
    for i in countdown(known.high, 0):
      let inc = known[i]
      let res = s.propagateIncompatibility(inc)
      case res.kind
      of pkConflict:
        trace "conflict: " & describe(inc, s.root)
        let rootCause = s.resolveConflict(inc)
        if rootCause.isFailure(s.root): return rootCause
        changed.setLen 0
        let after = s.propagateIncompatibility(rootCause)
        doAssert after.kind == pkChanged,
          "[bug] the root cause of a conflict must be unsatisfied after backjumping"
        changed.add after.package
        break
      of pkChanged:
        if res.package notin changed: changed.add res.package
      of pkNone:
        discard

proc makeDecision[P, V, VS, DP](s: Solver[P, V, VS, DP]): Option[P] =
  ## Picks a required-but-undecided package and a version for it.
  ##
  ## Returns the package that was looked at, or `none` when everything
  ## required has been decided - which is the solver's exit condition. Note it
  ## returns a package even when no version could be picked: that failure is
  ## recorded as a fact, and propagation deals with it on the next pass.
  mixin singleton, chooseVersion, dependencies, versionCountHook,
        dependencyRangeHook
  var
    best: P
    bestVersions: VS
    bestCount = 0
    found = false
  for (pkg, versions) in s.solution.unsatisfied:
    let count =
      when compiles(s.provider.versionCountHook(pkg, versions)):
        s.provider.versionCountHook(pkg, versions)
      else: 0
    if not found or count < bestCount:
      best = pkg
      bestVersions = versions
      bestCount = count
      found = true
  if not found: return none(P)

  let chosen = s.provider.chooseVersion(best, bestVersions)
  if chosen.isNone:
    discard s.addFact(newIncompatibility(
      @[positiveTerm(best, bestVersions)], ckNoVersions))
    return some(best)

  let
    version = chosen.get
    exact = singleton(version)

  # Record the dependencies before deciding. If one of them is already ruled
  # out by the partial solution, deciding would immediately conflict; leaving
  # the decision unmade lets propagation derive the narrower constraint and
  # pick a different version instead.
  var conflict = false
  for dep in s.provider.dependencies(best, version):
    let subject =
      when compiles(s.provider.dependencyRangeHook(best, version, dep)):
        s.provider.dependencyRangeHook(best, version, dep)
      else: exact
    let inc = s.addFact(newIncompatibility(
      @[positiveTerm(best, subject), negativeTerm(dep.package, dep.versions)],
      ckFromDependencyOf))
    if not conflict:
      var allSatisfied = true
      for pt in inc.terms:
        if pt.package != best and not s.solution.satisfies(pt.package, pt.term):
          allSatisfied = false
          break
      conflict = allSatisfied

  if not conflict:
    trace "decided: " & $best & " " & $version
    s.solution.decide(best, version, exact)
  else:
    trace "declined to decide: " & $best & " " & $version
  some(best)

proc solve*[P, V, DP](provider: DP, root: P, rootVersion: V): auto =
  ## Resolves `root` at `rootVersion` against `provider` - any type with
  ## `chooseVersion` and `dependencies` procs acting on it (see the module
  ## docs). Returns a `SolveResult`; the version-set type is taken from what
  ## the provider's `dependencies` returns.
  ##
  ## The root is entered as the incompatibility "root is *not* at
  ## rootVersion", which propagation immediately contradicts - that is how the
  ## root becomes required without being a special case anywhere else.
  mixin singleton, dependencies
  type VS = typeof(provider.dependencies(root, rootVersion)[0].versions)
  var s = Solver[P, V, VS, DP](provider: provider, root: root,
                               solution: initPartialSolution[P, V, VS]())
  s.addIncompatibility newIncompatibility(
    @[negativeTerm(root, singleton(rootVersion))], ckNotRoot)

  var next = some(root)
  while next.isSome:
    let failure = s.propagate(next.get)
    if failure != nil:
      return SolveResult[P, V, VS](outcome: soUnsolvable, failure: failure,
                                   attemptedSolutions: s.solution.attemptedSolutions)
    next = s.makeDecision()

  SolveResult[P, V, VS](outcome: soSolved, packages: s.solution.solution,
                        attemptedSolutions: s.solution.attemptedSolutions)
