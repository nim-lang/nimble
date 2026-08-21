{.used.}

import std/unittest
import pubgrub/[ranges, solver]
import ./registry

## The worked examples from PubGrub's own documentation (Dart's
## `doc/solver.md`), which between them exercise every branch of the loop:
## plain propagation, backtracking during decision making, conflict resolution,
## and conflict resolution where the satisfier only partially satisfies the
## term it is resolved against.

suite "solver: no conflicts":
  setup:
    var reg: Registry
    reg.add("root", v(1, 0), dep("foo", caret(1)))
    reg.add("foo", v(1, 0), dep("bar", caret(1)))
    reg.add("bar", v(2, 0))
    reg.add("bar", v(1, 0))

  test "picks the newest version satisfying every constraint":
    let res = solve(reg, "root", v(1, 0))
    check res.solution == @["bar 1.0", "foo 1.0", "root 1.0"]

  test "no backtracking was needed":
    check solve(reg, "root", v(1, 0)).attemptedSolutions == 1

suite "solver: avoiding conflict during decision making":
  setup:
    var reg: Registry
    reg.add("root", v(1, 0), dep("foo", caret(1)), dep("bar", caret(1)))
    reg.add("foo", v(1, 1), dep("bar", caret(2)))
    reg.add("foo", v(1, 0))
    reg.add("bar", v(2, 0))
    reg.add("bar", v(1, 1))
    reg.add("bar", v(1, 0))

  test "backs off foo 1.1 without ever deciding it":
    # foo 1.1 needs bar ^2.0.0, which root forbids. The solver notices while
    # recording foo 1.1's dependencies and simply never makes the decision.
    let res = solve(reg, "root", v(1, 0))
    check res.solution == @["bar 1.1", "foo 1.0", "root 1.0"]

  test "declining to decide is not a new candidate solution":
    check solve(reg, "root", v(1, 0)).attemptedSolutions == 1

suite "solver: performing conflict resolution":
  setup:
    var reg: Registry
    reg.add("root", v(1, 0), dep("foo", atLeast(v(1, 0))))
    reg.add("foo", v(2, 0), dep("bar", caret(1)))
    reg.add("foo", v(1, 0))
    reg.add("bar", v(1, 0), dep("foo", caret(1)))

  test "derives that foo 2.0 is impossible and settles on foo 1.0":
    let res = solve(reg, "root", v(1, 0))
    check res.solution == @["foo 1.0", "root 1.0"]

  test "it took a second attempt":
    check solve(reg, "root", v(1, 0)).attemptedSolutions == 2

suite "solver: conflict resolution with a partial satisfier":
  setup:
    var reg: Registry
    reg.add("root", v(1, 0), dep("foo", caret(1)), dep("target", caret(2)))
    reg.add("foo", v(1, 1), dep("left", caret(1)), dep("right", caret(1)))
    reg.add("foo", v(1, 0))
    reg.add("left", v(1, 0), dep("shared", atLeast(v(1, 0))))
    reg.add("right", v(1, 0), dep("shared", lessThan(v(2, 0))))
    reg.add("shared", v(2, 0))
    reg.add("shared", v(1, 0), dep("target", caret(1)))
    reg.add("target", v(2, 0))
    reg.add("target", v(1, 0))

  test "left and right only pin shared together":
    # Neither `shared >=1.0.0` nor `shared <2.0.0` rules out shared on its
    # own; the conflict only exists because both hold. This is the case that
    # needs the `difference` term in conflict resolution.
    let res = solve(reg, "root", v(1, 0))
    check res.solution == @["foo 1.0", "root 1.0", "target 2.0"]

suite "solver: failure":
  test "reports the root cause when no solution exists":
    var reg: Registry
    reg.add("root", v(1, 0), dep("foo", caret(1)), dep("baz", caret(1)))
    reg.add("foo", v(1, 0), dep("bar", caret(2)))
    reg.add("bar", v(2, 0), dep("baz", caret(3)))
    reg.add("baz", v(3, 0))
    reg.add("baz", v(1, 0))

    let res = solve(reg, "root", v(1, 0))
    check res.outcome == soUnsolvable
    check res.failure.isFailure("root")

  test "a missing package is a failure, not a crash":
    var reg: Registry
    reg.add("root", v(1, 0), dep("nope", caret(1)))

    let res = solve(reg, "root", v(1, 0))
    check res.outcome == soUnsolvable

  test "a dependency on a version that does not exist fails":
    var reg: Registry
    reg.add("root", v(1, 0), dep("foo", caret(2)))
    reg.add("foo", v(1, 0))

    let res = solve(reg, "root", v(1, 0))
    check res.outcome == soUnsolvable

suite "solver: degenerate universes":
  test "a root with no dependencies solves to itself":
    var reg: Registry
    reg.add("root", v(1, 0))
    check solve(reg, "root", v(1, 0)).solution == @["root 1.0"]

  test "a diamond resolves to one shared version":
    var reg: Registry
    reg.add("root", v(1, 0), dep("a", caret(1)), dep("b", caret(1)))
    reg.add("a", v(1, 0), dep("shared", caret(1)))
    reg.add("b", v(1, 0), dep("shared", caret(1)))
    reg.add("shared", v(1, 2))
    reg.add("shared", v(1, 0))
    check solve(reg, "root", v(1, 0)).solution ==
      @["a 1.0", "b 1.0", "root 1.0", "shared 1.2"]

  test "a cycle between two packages is fine":
    var reg: Registry
    reg.add("root", v(1, 0), dep("a", caret(1)))
    reg.add("a", v(1, 0), dep("b", caret(1)))
    reg.add("b", v(1, 0), dep("a", caret(1)))
    check solve(reg, "root", v(1, 0)).solution ==
      @["a 1.0", "b 1.0", "root 1.0"]

  test "an unconstrained dependency takes the newest version":
    var reg: Registry
    reg.add("root", v(1, 0), dep("a", anyVersion()))
    reg.add("a", v(3, 0))
    reg.add("a", v(1, 0))
    check solve(reg, "root", v(1, 0)).solution == @["a 3.0", "root 1.0"]
