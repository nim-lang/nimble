# Copyright (C) 2026 the Nim PubGrub authors. All rights reserved.
# BSD License. Look at license.txt for more info.

## Turning a failure into an explanation.
##
## The failure incompatibility is the root of a DAG: each derived
## incompatibility points at the two it was resolved from, down to the facts
## the provider stated. Printed naively that DAG is unreadable - the same node
## appears many times and the leaves are far from the conclusion. So the
## report does three things.
##
## It walks the graph depth-first and emits one sentence per derivation, so
## each line follows from lines above it. It numbers only the derivations that
## are referred to more than once, and cross-references them by number instead
## of restating them. And it collapses chains that would otherwise waste a line
## on an intermediate step nobody asked about, folding "A depends on B" and "B
## depends on C" into "A depends on B which depends on C".
##
## The phrasing helpers exist for the same reason: a reader should see
## "foo 1.0.0 depends on both bar and baz", not two separate statements they
## have to combine themselves.
##
## Before any of that, the versions that don't exist are taken out. Running
## out of a package's versions is a fact of its own, "no versions of foo match
## <every gap between its versions>", and conflict resolution unions that set
## into whatever it derives about foo. Printed as is, every later line about
## foo would spell out those gaps, and the step that took them in would read
## as a premise restated. So the set of versions a term says a package is at
## is shown without the ones the provider said it doesn't have, and a step
## that, without them, only restates one of its premises is skipped. What a
## dependency allows is left as stated: there, a set holding no version can
## be the very reason two requirements conflict.

import std/[options, strutils]
import ./[term, incompatibility]

type
  Reporter[P, VS] = object
    root: P
    writeVersions: VersionsWriter[P, VS]
      ## How versions are written; `$` when nil.
    gaps: seq[tuple[package: P, versions: VS]]
      ## Per package, every version the provider said it has none of: the
      ## union of its `ckNoVersions` facts in the graph.
    shown: seq[tuple[stated, shown: Incompatibility[P, VS]]]
      ## Each incompatibility of the graph and the one printed in its place,
      ## without the gaps (`tidy`). By identity, like `derivations`.
    failure: Incompatibility[P, VS]
      ## The top of the graph. Only its line gets "So," - every other line is
      ## a step along the way, not the conclusion.
    derivations: seq[tuple[inc: Incompatibility[P, VS], count: int]]
      ## How many times each incompatibility is used as a cause. More than
      ## once means it earns a line number. An association list rather than a
      ## table: incompatibilities are compared by identity, the graph holds a
      ## few dozen nodes, and a hash over addresses would make the report
      ## depend on allocation order.
    lineNumbers: seq[tuple[inc: Incompatibility[P, VS], line: int]]
    lines: seq[tuple[text: string, number: int]]  ## number 0 means unnumbered

proc isDerived[P, VS](inc: Incompatibility[P, VS]): bool =
  inc.cause == ckDerivedFrom

proc derivationCount[P, VS](r: Reporter[P, VS],
                            inc: Incompatibility[P, VS]): int =
  for entry in r.derivations:
    if entry.inc == inc: return entry.count

proc lineNumber[P, VS](r: Reporter[P, VS],
                       inc: Incompatibility[P, VS]): int =
  ## 0 when this incompatibility has not been given a line of its own.
  for entry in r.lineNumbers:
    if entry.inc == inc: return entry.line

proc countDerivations[P, VS](r: var Reporter[P, VS],
                             inc: Incompatibility[P, VS]) =
  for i in 0 ..< r.derivations.len:
    if r.derivations[i].inc == inc:
      inc r.derivations[i].count
      return
  r.derivations.add (inc, 1)
  if inc.isDerived:
    r.countDerivations inc.conflict
    r.countDerivations inc.other

proc collectGaps[P, VS](r: var Reporter[P, VS], inc: Incompatibility[P, VS],
                        seen: var seq[Incompatibility[P, VS]]) =
  mixin union
  if inc in seen: return
  seen.add inc
  if inc.cause == ckNoVersions and inc.terms.len == 1:
    let t = inc.terms[0]
    for gap in r.gaps.mitems:
      if gap.package == t.package:
        gap.versions = union(gap.versions, t.term.versions)
        return
    r.gaps.add (t.package, t.term.versions)
  elif inc.isDerived:
    r.collectGaps(inc.conflict, seen)
    r.collectGaps(inc.other, seen)

proc withoutGaps[P, VS](r: Reporter[P, VS],
                        pt: PackageTerm[P, VS]): PackageTerm[P, VS] =
  ## `pt` as the report shows it. A positive term loses the versions its
  ## package doesn't have - and covers every version if those are all it
  ## leaves out - unless they are all it holds. A negative term is what some
  ## dependency allows, and stays as stated.
  mixin union, difference, isFull, isEmpty
  result = pt
  if not pt.term.positive: return
  for gap in r.gaps:
    if gap.package == pt.package:
      let every = union(pt.term.versions, gap.versions)
      if every.isFull:
        result.term.versions = every
      else:
        let existing = difference(pt.term.versions, gap.versions)
        if not existing.isEmpty: result.term.versions = existing
      return

proc sameTermsInAnyOrder[P, VS](a, b: seq[PackageTerm[P, VS]]): bool =
  if a.len != b.len: return false
  for pt in a:
    if pt notin b: return false
  true

proc tidy[P, VS](r: var Reporter[P, VS],
                 inc: Incompatibility[P, VS]): Incompatibility[P, VS] =
  ## The incompatibility printed in place of `inc`: its terms without the gaps,
  ## or, for a step that without them concludes what one of its premises
  ## already says, that premise. The provider's statements about what it
  ## doesn't have are printed as stated.
  for entry in r.shown:
    if entry.stated == inc: return entry.shown
  var terms: seq[PackageTerm[P, VS]]
  for pt in inc.terms: terms.add r.withoutGaps(pt)
  case inc.cause
  of ckNoVersions, ckNotFound, ckNotRoot:
    result = inc
  of ckFromDependencyOf:
    result =
      if terms == inc.terms: inc
      else: Incompatibility[P, VS](terms: terms, cause: ckFromDependencyOf)
  of ckDerivedFrom:
    let
      conflict = r.tidy(inc.conflict)
      other = r.tidy(inc.other)
    result =
      if sameTermsInAnyOrder(terms, conflict.terms): conflict
      elif sameTermsInAnyOrder(terms, other.terms): other
      elif terms == inc.terms and conflict == inc.conflict and
          other == inc.other: inc
      else: Incompatibility[P, VS](terms: terms, cause: ckDerivedFrom,
                                   conflict: conflict, other: other)
  r.shown.add (inc, result)

proc covers[P, VS](r: Reporter[P, VS], allowed, subject: PackageTerm[P, VS]):
    bool =
  ## Whether every version the dependency `allowed` (a negative term) admits,
  ## of those that exist, is one `subject` is about. The package too, not just
  ## the versions: `satisfies` compares sets only.
  allowed.package == subject.package and
    r.withoutGaps(PackageTerm[P, VS](package: allowed.package,
                                     term: allowed.term.inverse))
      .term.satisfies(subject.term)

proc singleTerm[P, VS](inc: Incompatibility[P, VS], positive: bool):
    Option[PackageTerm[P, VS]] =
  ## The one term of the given sign, if there is exactly one.
  for pt in inc.terms:
    if pt.term.positive == positive:
      if result.isSome: return none(PackageTerm[P, VS])
      result = some(pt)

proc termsOfSign[P, VS](r: Reporter[P, VS], inc: Incompatibility[P, VS],
                        positive: bool, sep = " or "): string =
  var parts: seq[string]
  for pt in inc.terms:
    if pt.term.positive == positive:
      parts.add terse(pt, r.root, write = r.writeVersions)
  parts.join(sep)

proc countOfSign[P, VS](inc: Incompatibility[P, VS], positive: bool): int =
  for pt in inc.terms:
    if pt.term.positive == positive: inc result

proc reference(line: int): string =
  if line == 0: "" else: " (" & $line & ")"

proc tryRequiresBoth[P, VS](r: Reporter[P, VS], a, b: Incompatibility[P, VS],
                            aLine, bLine: int): string =
  ## "foo depends on both bar and baz" - both incompatibilities constrain the
  ## same versions of the same package, so the reader should see one subject,
  ## not two sentences.
  if a.terms.len == 1 or b.terms.len == 1: return ""
  let
    aPositive = a.singleTerm(true)
    bPositive = b.singleTerm(true)
  if aPositive.isNone or bPositive.isNone: return ""
  # The versions too, not just the package: "foo 1.0 depends on bar" and
  # "foo 2.0 depends on baz" do not make "foo 2.0 depends on both bar and baz".
  if aPositive.get != bPositive.get: return ""

  let verb =
    if a.cause == ckFromDependencyOf and b.cause == ckFromDependencyOf:
      "depends on"
    else:
      "requires"
  terse(aPositive.get, r.root, allowEvery = true, r.writeVersions) & " " &
    verb & " both " & r.termsOfSign(a, false) & reference(aLine) & " and " &
    r.termsOfSign(b, false) & reference(bLine)

proc tryRequiresThrough[P, VS](r: Reporter[P, VS], a, b: Incompatibility[P, VS],
                               aLine, bLine: int): string =
  ## "foo depends on bar which depends on baz" - one incompatibility's
  ## conclusion is the other's subject, so they chain into a single clause.
  if a.terms.len == 1 or b.terms.len == 1: return ""
  let
    aNegative = a.singleTerm(false)
    bNegative = b.singleTerm(false)
  if aNegative.isNone and bNegative.isNone: return ""
  let
    aPositive = a.singleTerm(true)
    bPositive = b.singleTerm(true)

  var
    prior, latter: Incompatibility[P, VS]
    priorNegative: PackageTerm[P, VS]
    priorLine, latterLine: int
  if aNegative.isSome and bPositive.isSome and
      r.covers(aNegative.get, bPositive.get):
    prior = a; priorNegative = aNegative.get; priorLine = aLine
    latter = b; latterLine = bLine
  elif bNegative.isSome and aPositive.isSome and
      r.covers(bNegative.get, aPositive.get):
    prior = b; priorNegative = bNegative.get; priorLine = bLine
    latter = a; latterLine = aLine
  else:
    return ""

  if prior.countOfSign(true) > 1:
    result = "if " & r.termsOfSign(prior, true) & " then "
  else:
    let subject = prior.singleTerm(true)
    if subject.isNone: return ""
    let verb = if prior.cause == ckFromDependencyOf: " depends on " else: " requires "
    result = terse(subject.get, r.root, allowEvery = true, r.writeVersions) &
      verb

  result.add terse(priorNegative, r.root, write = r.writeVersions) &
    reference(priorLine) & " which "
  result.add(if latter.cause == ckFromDependencyOf: "depends on " else: "requires ")
  result.add r.termsOfSign(latter, false) & reference(latterLine)

proc tryRequiresForbidden[P, VS](r: Reporter[P, VS],
                                 a, b: Incompatibility[P, VS],
                                 aLine, bLine: int): string =
  ## "foo depends on bar which couldn't be found" - the second incompatibility
  ## is a single-term dead end, which reads better inline than as its own line.
  if a.terms.len != 1 and b.terms.len != 1: return ""
  var
    prior, latter: Incompatibility[P, VS]
    priorLine, latterLine: int
  if a.terms.len == 1:
    prior = b; priorLine = bLine
    latter = a; latterLine = aLine
  else:
    prior = a; priorLine = aLine
    latter = b; latterLine = bLine

  let negative = prior.singleTerm(false)
  if negative.isNone: return ""
  # The package too: "foo 1.0 depends on bar" and "no versions of foo match
  # ..." do not make "foo 1.0 depends on foo ... which doesn't match any
  # versions".
  if not r.covers(negative.get, latter.terms[0]): return ""
  if prior.countOfSign(true) == 0: return ""

  if prior.countOfSign(true) > 1:
    result = "if " & r.termsOfSign(prior, true) & " then "
  else:
    let subject = prior.singleTerm(true)
    if subject.isNone: return ""
    result = terse(subject.get, r.root, allowEvery = true, r.writeVersions)
    result.add(if prior.cause == ckFromDependencyOf: " depends on " else: " requires ")

  if latter.cause == ckNotFound:
    # No version set: the package itself is unknown, so the constraint that
    # was asked of it is beside the point.
    result.add $latter.terms[0].package & " which couldn't be found"
  elif latter.cause == ckNoVersions:
    result.add terse(latter.terms[0], r.root, write = r.writeVersions) &
      " which doesn't match any versions"
  else:
    result.add terse(latter.terms[0], r.root, write = r.writeVersions) &
      " which is forbidden"
  result.add reference(priorLine) & reference(latterLine)

proc andToString[P, VS](r: Reporter[P, VS], a, b: Incompatibility[P, VS],
                        aLine = 0, bLine = 0): string =
  ## Two incompatibilities as one clause, phrased specially when they fit a
  ## recognisable shape and joined with a plain "and" otherwise.
  result = r.tryRequiresBoth(a, b, aLine, bLine)
  if result.len > 0: return
  result = r.tryRequiresThrough(a, b, aLine, bLine)
  if result.len > 0: return
  result = r.tryRequiresForbidden(a, b, aLine, bLine)
  if result.len > 0: return
  return describe(a, r.root, r.writeVersions) & reference(aLine) & " and " &
    describe(b, r.root, r.writeVersions) & reference(bLine)

proc write[P, VS](r: var Reporter[P, VS], inc: Incompatibility[P, VS],
                  message: string, numbered = false) =
  if numbered:
    let number = r.lineNumbers.len + 1
    r.lineNumbers.add (inc, number)
    r.lines.add (message, number)
  else:
    r.lines.add (message, 0)

proc isSingleLine[P, VS](inc: Incompatibility[P, VS]): bool =
  ## Whether explaining `inc` takes one sentence: both its causes are facts.
  not inc.conflict.isDerived and not inc.other.isDerived

proc isCollapsible[P, VS](r: Reporter[P, VS],
                          inc: Incompatibility[P, VS]): bool =
  ## Whether `inc` can be folded into the sentence that uses it.
  ##
  ## Only worth doing for the one shape that stays readable: exactly one
  ## derived cause and one stated fact, where the derived cause is not
  ## referenced elsewhere. Two derived causes carry too much history to inline;
  ## two facts already fit on their own line.
  if r.derivationCount(inc) > 1: return false
  let
    conflictDerived = inc.conflict.isDerived
    otherDerived = inc.other.isDerived
  if conflictDerived and otherDerived: return false
  if not conflictDerived and not otherDerived: return false
  let complex = if conflictDerived: inc.conflict else: inc.other
  r.lineNumber(complex) == 0

proc visit[P, VS](r: var Reporter[P, VS], inc: Incompatibility[P, VS],
                  isConclusion = false) =
  ## Emits the lines explaining `inc`, deepest premise first.
  let
    numbered = isConclusion or r.derivationCount(inc) > 1
    conjunction = if isConclusion or inc == r.failure: "So," else: "And"
    conclusion = describe(inc, r.root, r.writeVersions)
    conflict = inc.conflict
    other = inc.other

  if conflict.isDerived and other.isDerived:
    let
      conflictLine = r.lineNumber(conflict)
      otherLine = r.lineNumber(other)
    if conflictLine != 0 and otherLine != 0:
      # Both premises are already on the page; refer to them and conclude.
      r.write(inc, "Because " &
        r.andToString(conflict, other, conflictLine, otherLine) & ", " &
        conclusion & ".", numbered)
    elif conflictLine != 0 or otherLine != 0:
      let
        withLine = if conflictLine != 0: conflict else: other
        withoutLine = if conflictLine != 0: other else: conflict
        line = if conflictLine != 0: conflictLine else: otherLine
      r.visit withoutLine
      r.write(inc, conjunction & " because " &
        describe(withLine, r.root, r.writeVersions) & " (" & $line & "), " &
        conclusion & ".", numbered)
    elif conflict.isSingleLine or other.isSingleLine:
      # Explaining the one-liner second keeps it next to the conclusion it
      # feeds, so the reader does not have to hold it in mind.
      let
        first = if other.isSingleLine: conflict else: other
        second = if other.isSingleLine: other else: conflict
      r.visit first
      r.visit second
      r.write(inc, "Thus, " & conclusion & ".", numbered)
    else:
      # Two deep premises: give the first its own paragraph and a conclusion
      # of its own, then start over for the second.
      r.visit(conflict, isConclusion = true)
      r.lines.add ("", 0)
      r.visit other
      r.write(inc, conjunction & " " & conclusion & ".", numbered)
  elif conflict.isDerived or other.isDerived:
    let
      derived = if conflict.isDerived: conflict else: other
      fact = if conflict.isDerived: other else: conflict
      derivedLine = r.lineNumber(derived)
    if derivedLine != 0:
      r.write(inc, "Because " &
        r.andToString(fact, derived, 0, derivedLine) & ", " & conclusion & ".",
        numbered)
    elif r.isCollapsible(derived):
      # Skip the intermediate conclusion and chain straight through it.
      let
        collapsedDerived =
          if derived.conflict.isDerived: derived.conflict else: derived.other
        collapsedFact =
          if derived.conflict.isDerived: derived.other else: derived.conflict
      r.visit collapsedDerived
      r.write(inc, conjunction & " because " &
        r.andToString(collapsedFact, fact) & ", " & conclusion & ".", numbered)
    else:
      r.visit derived
      r.write(inc, conjunction & " because " &
        describe(fact, r.root, r.writeVersions) & ", " & conclusion & ".",
        numbered)
  else:
    r.write(inc, "Because " & r.andToString(conflict, other) & ", " &
      conclusion & ".", numbered)

proc explain[P, VS](failure: Incompatibility[P, VS], root: P,
                    writeVersions: VersionsWriter[P, VS]): string =
  if not failure.isDerived:
    # Nothing was derived - the very first fact the solver stated already
    # ruled the root package out.
    return "Because " & describe(failure, root, writeVersions) &
      ", version solving failed."

  var r = Reporter[P, VS](root: root, writeVersions: writeVersions)
  var seen: seq[Incompatibility[P, VS]]
  r.collectGaps(failure, seen)
  r.failure = r.tidy(failure)
  r.countDerivations r.failure
  r.visit r.failure

  var padding = 0
  if r.lineNumbers.len > 0:
    padding = ("(" & $r.lineNumbers.len & ") ").len

  var lastWasBlank = true
  for line in r.lines:
    if line.text.len == 0:
      if not lastWasBlank: result.add "\n"
      lastWasBlank = true
      continue
    lastWasBlank = false
    if line.number != 0:
      result.add alignLeft("(" & $line.number & ") ", padding)
    else:
      result.add spaces(padding)
    result.add line.text
    result.add "\n"
  result.setLen max(result.len - 1, 0)

proc report*[P, VS](failure: Incompatibility[P, VS], root: P): string =
  ## The human-readable explanation of why solving failed, with versions
  ## written by `$`.
  ##
  ## `failure` is the incompatibility from an unsolvable `SolveResult`; `root`
  ## is the package solving started from.
  explain(failure, root, nil)

proc report*[P, VS, DP](failure: Incompatibility[P, VS], root: P,
                        provider: DP): string =
  ## The same explanation, with versions written by the provider the solve ran
  ## against, when it has the optional hook
  ##
  ## ```nim
  ## proc versionsTextHook(p: MyProvider, package: P, versions: VS,
  ##                       positive: bool): string
  ##   ## How the report writes `versions` of `package` (a `VersionsWriter`).
  ##   ## The provider knows what the solver doesn't - which versions there
  ##   ## are, and how its users write requirements - so it can name the
  ##   ## versions a set holds instead of the bounds the solver keeps.
  ## ```
  ##
  ## matched by its exact signature at instantiation, like the solver's hooks.
  ## Without it, versions are written by `$`.
  mixin versionsTextHook
  when compiles(provider.versionsTextHook(root, default(VS), true)):
    explain(failure, root,
      proc (package: P, versions: VS, positive: bool): string =
        provider.versionsTextHook(package, versions, positive))
  else:
    explain(failure, root, nil)
