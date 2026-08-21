{.used.}

import std/[unittest, options, sequtils, tables]
import pubgrub/[ranges, term, incompatibility, partialsolution]

type
  V = int
  R = Ranges[V]
  Solution = PartialSolution[string, V, R]

## A cause has to be *something* for a derivation to record; nothing here
## inspects it, so one shared stand-in is enough.
let anyCause = newIncompatibility(
  @[positiveTerm("x", fullRange[V]())], ckNoVersions)

proc newSolution(): Solution = initPartialSolution[string, V, R]()

suite "partial solution: assignments":
  test "an empty solution knows nothing about anything":
    let s = newSolution()
    check s.summary("foo").isNone
    check s.relation("foo", positiveTerm(between(1, 5))) == srOverlapping
    check s.decisionLevel == 0

  test "a derivation records what is required":
    var s = newSolution()
    s.derive("foo", between(1, 5), positive = true, anyCause)
    check s.summary("foo").get == positiveTerm(between(1, 5))
    check s.satisfies("foo", positiveTerm(between(1, 10)))
    check not s.satisfies("foo", positiveTerm(between(2, 3)))

  test "derivations about one package accumulate by intersection":
    var s = newSolution()
    s.derive("foo", atLeast(1), positive = true, anyCause)
    s.derive("foo", lessThan(5), positive = true, anyCause)
    check s.summary("foo").get == positiveTerm(between(1, 5))

  test "a package with only negative derivations stays negative":
    var s = newSolution()
    s.derive("foo", between(1, 5), positive = false, anyCause)
    check not s.summary("foo").get.positive

  test "a negative package flips positive when a derivation makes it so":
    var s = newSolution()
    s.derive("foo", between(4, 6), positive = false, anyCause)
    s.derive("foo", between(1, 10), positive = true, anyCause)
    let t = s.summary("foo").get
    check t.positive
    check t.versions == difference(between(1, 10), between(4, 6))

  test "a decision raises the decision level":
    var s = newSolution()
    s.decide("foo", 3, singleton(3))
    check s.decisionLevel == 1
    check s.decisions["foo"] == 3
    s.decide("bar", 1, singleton(1))
    check s.decisionLevel == 2

suite "partial solution: unsatisfied":
  test "a required package is unsatisfied until it is decided":
    var s = newSolution()
    s.derive("foo", between(1, 5), positive = true, anyCause)
    check toSeq(s.unsatisfied).mapIt(it.package) == @["foo"]
    s.decide("foo", 2, singleton(2))
    check toSeq(s.unsatisfied).len == 0

  test "a negatively constrained package is not required":
    var s = newSolution()
    s.derive("foo", between(1, 5), positive = false, anyCause)
    check toSeq(s.unsatisfied).len == 0

  test "candidates come out in the order they were first required":
    var s = newSolution()
    s.derive("b", between(1, 5), positive = true, anyCause)
    s.derive("a", between(1, 5), positive = true, anyCause)
    s.derive("b", between(2, 4), positive = true, anyCause)
    check toSeq(s.unsatisfied).mapIt(it.package) == @["b", "a"]

  test "the reported set is what has accumulated, not the first derivation":
    var s = newSolution()
    s.derive("foo", atLeast(1), positive = true, anyCause)
    s.derive("foo", lessThan(5), positive = true, anyCause)
    check toSeq(s.unsatisfied)[0].versions == between(1, 5)

suite "partial solution: satisfier":
  test "the satisfier is the assignment that tips the balance":
    var s = newSolution()
    s.derive("foo", atLeast(1), positive = true, anyCause)
    s.derive("foo", lessThan(5), positive = true, anyCause)
    # Neither bound satisfies `[1, 5)` alone; the second one completes it.
    let a = s.satisfier("foo", positiveTerm(between(1, 5)))
    check a.index == 1

  test "an assignment that satisfies on its own is its own satisfier":
    var s = newSolution()
    s.derive("foo", between(2, 3), positive = true, anyCause)
    s.derive("foo", between(2, 3), positive = true, anyCause)
    check s.satisfier("foo", positiveTerm(between(1, 5))).index == 0

  test "assignments about other packages are skipped":
    var s = newSolution()
    s.derive("bar", between(1, 5), positive = true, anyCause)
    s.derive("foo", between(1, 5), positive = true, anyCause)
    check s.satisfier("foo", positiveTerm(between(1, 5))).package == "foo"

  test "asking for something unsatisfied is a bug, and says so":
    var s = newSolution()
    s.derive("foo", between(1, 10), positive = true, anyCause)
    expect ValueError:
      discard s.satisfier("foo", positiveTerm(between(1, 2)))

suite "partial solution: backtracking":
  setup:
    var s = newSolution()
    s.derive("foo", between(1, 5), positive = true, anyCause)  # level 0
    s.decide("foo", 2, singleton(2))                           # level 1
    s.derive("bar", between(1, 5), positive = true, anyCause)  # level 1
    s.decide("bar", 3, singleton(3))                           # level 2
    s.derive("baz", between(1, 5), positive = true, anyCause)  # level 2

  test "backtracking undoes everything above the given level":
    s.backtrack(1)
    check s.decisionLevel == 1
    check s.decisions.hasKey("foo")
    check not s.decisions.hasKey("bar")
    check s.summary("baz").isNone

  test "assignments at or below the level are untouched":
    s.backtrack(1)
    check s.summary("foo").get.versions == singleton(2)
    check s.summary("bar").get == positiveTerm(between(1, 5))

  test "backtracking to zero leaves only the level zero derivations":
    s.backtrack(0)
    check s.decisionLevel == 0
    check s.summary("foo").get == positiveTerm(between(1, 5))
    check s.summary("bar").isNone

  test "backtracking to the current level changes nothing":
    let before = s.assignments.len
    s.backtrack(2)
    check s.assignments.len == before

  test "a decision after backtracking counts as a new attempt":
    check s.attemptedSolutions == 1
    s.backtrack(1)
    s.decide("bar", 1, singleton(1))
    check s.attemptedSolutions == 2

  test "backtracking twice in a row is still one new attempt":
    s.backtrack(1)
    s.backtrack(0)
    s.decide("foo", 1, singleton(1))
    check s.attemptedSolutions == 2

suite "partial solution: result":
  test "the solution is the decisions in the order they were made":
    var s = newSolution()
    s.decide("root", 1, singleton(1))
    s.decide("foo", 2, singleton(2))
    check s.solution == @[(package: "root", version: 1),
                          (package: "foo", version: 2)]
