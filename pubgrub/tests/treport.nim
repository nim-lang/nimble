import std/[unittest, strutils]
import pubgrub/[ranges, solver, report]
import ./registry

## Golden output for the error-reporting examples in PubGrub's documentation.
##
## The sentences match Dart's, the version syntax does not: `Ranges` prints
## intervals, so `^1.0.0` shows up as `[1.0, 2.0)`. Comparing line by line
## keeps a failure readable and stops trailing whitespace from mattering.

proc explain(reg: Registry): seq[string] =
  let res = solve(reg, "root", v(1, 0))
  doAssert res.outcome == soUnsolvable, "expected solving to fail"
  report(res.failure, "root").splitLines()

suite "report: linear chain":
  setup:
    var reg: Registry
    reg.add("root", v(1, 0), dep("foo", caret(1)), dep("baz", caret(1)))
    reg.add("foo", v(1, 0), dep("bar", caret(2)))
    reg.add("bar", v(2, 0), dep("baz", caret(3)))
    reg.add("baz", v(3, 0))
    reg.add("baz", v(1, 0))

  test "collapses the chain into two sentences":
    check reg.explain == @[
      "Because every version of foo depends on bar [2.0, 3.0) which depends " &
        "on baz [3.0, 4.0), every version of foo requires baz [3.0, 4.0).",
      "So, because root depends on both foo [1.0, 2.0) and baz [1.0, 2.0), " &
        "version solving failed."
    ]

  test "the intermediate step is never stated on its own":
    # `bar ^2.0.0 depends on baz ^3.0.0` is folded into the first sentence
    # rather than given a line, which is the whole point of collapsing.
    for line in reg.explain:
      check not line.startsWith("Because every version of bar")

suite "report: branching":
  setup:
    var reg: Registry
    reg.add("root", v(1, 0), dep("foo", caret(1)))
    reg.add("foo", v(1, 1), dep("x", caret(1)), dep("y", caret(1)))
    reg.add("foo", v(1, 0), dep("a", caret(1)), dep("b", caret(1)))
    reg.add("a", v(1, 0), dep("b", caret(2)))
    reg.add("b", v(2, 0))
    reg.add("b", v(1, 0))
    reg.add("x", v(1, 0), dep("y", caret(2)))
    reg.add("y", v(2, 0))
    reg.add("y", v(1, 0))

  test "each branch gets its own paragraph":
    check reg.explain == @[
      "    Because foo (-inf, 1.1) depends on a [1.0, 2.0) which depends on " &
        "b [2.0, 3.0), foo (-inf, 1.1) requires b [2.0, 3.0).",
      "(1) So, because foo (-inf, 1.1) depends on b [1.0, 2.0), " &
        "foo (-inf, 1.1) is forbidden.",
      "",
      "    Because foo [1.1, inf) depends on x [1.0, 2.0) which depends on " &
        "y [2.0, 3.0), foo [1.1, inf) requires y [2.0, 3.0).",
      "    And because foo [1.1, inf) depends on y [1.0, 2.0), " &
        "foo [1.1, inf) is forbidden.",
      "    And every version of foo is forbidden.",
      "    So, because root depends on foo [1.0, 2.0), version solving failed."
    ]

  test "numbered lines are padded so the prose stays aligned":
    let lines = reg.explain
    check lines[0].startsWith("    ")
    check lines[1].startsWith("(1) ")

suite "report: dead ends":
  test "a package the provider has never heard of":
    var reg: Registry
    reg.add("root", v(1, 0), dep("nope", caret(1)))
    check reg.explain == @[
      "Because root depends on nope [1.0, 2.0) which doesn't match any " &
        "versions, version solving failed."
    ]

  test "a package that exists but has no matching version":
    var reg: Registry
    reg.add("root", v(1, 0), dep("foo", caret(2)))
    reg.add("foo", v(1, 0))
    check reg.explain == @[
      "Because root depends on foo [2.0, 3.0) which doesn't match any " &
        "versions, version solving failed."
    ]

suite "report: two roots of the same conflict":
  test "states both dependencies and the incompatibility between them":
    var reg: Registry
    reg.add("root", v(1, 0), dep("a", caret(1)), dep("b", caret(1)))
    reg.add("a", v(1, 0), dep("shared", caret(1)))
    reg.add("b", v(1, 0), dep("shared", caret(2)))
    reg.add("shared", v(2, 0))
    reg.add("shared", v(1, 0))
    check reg.explain == @[
      "Because every version of b depends on shared [2.0, 3.0) and every " &
        "version of a depends on shared [1.0, 2.0), b is incompatible with a.",
      "So, because root depends on both a [1.0, 2.0) and b [1.0, 2.0), " &
        "version solving failed."
    ]

suite "report: properties":
  setup:
    var reg: Registry
    reg.add("root", v(1, 0), dep("foo", caret(1)), dep("baz", caret(1)))
    reg.add("foo", v(1, 0), dep("bar", caret(2)))
    reg.add("bar", v(2, 0), dep("baz", caret(3)))
    reg.add("baz", v(3, 0))
    reg.add("baz", v(1, 0))

  test "the report is deterministic":
    # Nothing in the walk depends on hashing or allocation order, so two runs
    # of the same universe have to produce the same text.
    check reg.explain == reg.explain

  test "the last line always states the failure":
    check reg.explain[^1].endsWith("version solving failed.")

  test "no line mentions an incompatibility as a negation":
    # Every sentence is phrased as something that is true, never as "these
    # terms cannot all hold".
    for line in reg.explain:
      check "cannot all" notin line
