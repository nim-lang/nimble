# Copyright (C) 2026 the Nim PubGrub authors. All rights reserved.
# BSD License. Look at license.txt for more info.

## The battle-tested part of the battery: scenarios re-expressed from the
## solver tests of Dart's `pub` (`test/version_solver_test.dart`, BSD-3) - the
## graphs, the expected resolutions, and the expected failure reports. Only the
## groups that exercise the *ported* library are here: basic graphs,
## unsolvable universes, backtracking, and the regression cases. The lockfile,
## override, dev-dependency and SDK groups are provider policy and wait for the
## Nimble integration; the pre-release group needs a version type with
## pre-release ordering, which `registry.Ver` deliberately does not have yet.
##
## Cases already covered verbatim by `tsolver`/`treport` (no dependencies,
## circular dependency, backjumps after a partial satisfier, branching error
## reporting) are not repeated.
##
## `attemptedSolutions` is asserted where Dart asserts `tries:` and the two
## solvers agree on the count; where they differ the solution alone is the
## contract.

import std/[unittest, strutils]
import pubgrub/[ranges, solver, report]
import ./registry

proc explain(reg: Registry): seq[string] =
  let res = solve(reg, "root", v(1, 0))
  doAssert res.outcome == soUnsolvable, "expected solving to fail"
  report(res.failure, "root").splitLines()

suite "upstream: basic graph":
  test "simple dependency tree":
    var reg: Registry
    reg.add("root", v(1, 0), dep("a", exactly(1)), dep("b", exactly(1)))
    reg.add("a", v(1, 0), dep("aa", exactly(1)), dep("ab", exactly(1)))
    reg.add("aa", v(1, 0))
    reg.add("ab", v(1, 0))
    reg.add("b", v(1, 0), dep("ba", exactly(1)), dep("bb", exactly(1)))
    reg.add("ba", v(1, 0))
    reg.add("bb", v(1, 0))
    check solve(reg, "root", v(1, 0)).solution ==
      @["a 1.0", "aa 1.0", "ab 1.0", "b 1.0", "ba 1.0", "bb 1.0", "root 1.0"]

  test "shared dependency with overlapping constraints":
    var reg: Registry
    reg.add("root", v(1, 0), dep("a", exactly(1)), dep("b", exactly(1)))
    reg.add("a", v(1, 0), dep("shared", between(v(2), v(4))))
    reg.add("b", v(1, 0), dep("shared", between(v(3), v(5))))
    reg.add("shared", v(5, 0))
    reg.add("shared", v(4, 0))
    reg.add("shared", v(3, 6, 9))
    reg.add("shared", v(3, 0))
    reg.add("shared", v(2, 0))
    check solve(reg, "root", v(1, 0)).solution ==
      @["a 1.0", "b 1.0", "root 1.0", "shared 3.6.9"]

  test "shared dependency where the dependent version affects other deps":
    var reg: Registry
    reg.add("root", v(1, 0), dep("foo", atMost(v(1, 0, 2))),
            dep("bar", exactly(1)))
    reg.add("foo", v(1, 0, 3), dep("zoop", exactly(1)))
    reg.add("foo", v(1, 0, 2), dep("whoop", exactly(1)))
    reg.add("foo", v(1, 0, 1), dep("bang", exactly(1)))
    reg.add("foo", v(1, 0))
    reg.add("bar", v(1, 0), dep("foo", atMost(v(1, 0, 1))))
    reg.add("bang", v(1, 0))
    reg.add("whoop", v(1, 0))
    reg.add("zoop", v(1, 0))
    check solve(reg, "root", v(1, 0)).solution ==
      @["bang 1.0", "bar 1.0", "foo 1.0.1", "root 1.0"]

  test "removed dependency":
    # bar 2.0 drags in baz, which needs the foo the root forbids; the solver
    # falls back to bar 1.0, whose newer self has the extra dependency.
    var reg: Registry
    reg.add("root", v(1, 0), dep("foo", exactly(1)), dep("bar", anyVersion()))
    reg.add("foo", v(2, 0))
    reg.add("foo", v(1, 0))
    reg.add("bar", v(2, 0), dep("baz", exactly(1)))
    reg.add("bar", v(1, 0))
    reg.add("baz", v(1, 0), dep("foo", exactly(2)))
    let res = solve(reg, "root", v(1, 0))
    check res.solution == @["bar 1.0", "foo 1.0", "root 1.0"]
    check res.attemptedSolutions == 2

suite "upstream: unsolvable":
  test "no version that matches a combined constraint":
    var reg: Registry
    reg.add("root", v(1, 0), dep("foo", exactly(1)), dep("bar", exactly(1)))
    reg.add("foo", v(1, 0), dep("shared", between(v(2), v(3))))
    reg.add("bar", v(1, 0), dep("shared", between(v(2, 9), v(4))))
    reg.add("shared", v(3, 5))
    reg.add("shared", v(2, 5))
    check reg.explain == @[
      "Because every version of foo depends on shared [2.0, 3.0) and no " &
        "versions of shared match [2.9, 3.0), every version of foo requires " &
        "shared [2.0, 2.9).",
      "And because every version of bar depends on shared [2.9, 4.0), bar " &
        "is incompatible with foo.",
      "So, because root depends on both foo [1.0, 1.0] and bar [1.0, 1.0], " &
        "version solving failed."
    ]

  test "disjoint constraints":
    var reg: Registry
    reg.add("root", v(1, 0), dep("foo", exactly(1)), dep("bar", exactly(1)))
    reg.add("foo", v(1, 0), dep("shared", atMost(v(2, 0))))
    reg.add("bar", v(1, 0), dep("shared", greaterThan(v(3, 0))))
    reg.add("shared", v(4, 0))
    reg.add("shared", v(2, 0))
    check reg.explain == @[
      "Because every version of bar depends on shared (3.0, inf) and every " &
        "version of foo depends on shared (-inf, 2.0], bar is incompatible " &
        "with foo.",
      "So, because root depends on both foo [1.0, 1.0] and bar [1.0, 1.0], " &
        "version solving failed."
    ]

  test "no valid solution when two packages pin each other crosswise":
    var reg: Registry
    reg.add("root", v(1, 0), dep("a", anyVersion()), dep("b", anyVersion()))
    reg.add("a", v(2, 0), dep("b", exactly(2)))
    reg.add("a", v(1, 0), dep("b", exactly(1)))
    reg.add("b", v(2, 0), dep("a", exactly(1)))
    reg.add("b", v(1, 0), dep("a", exactly(2)))
    check reg.explain == @[
      "Because b (-inf, 2.0) depends on a [2.0, 2.0] which depends on " &
        "b [2.0, 2.0], b (-inf, 2.0) is forbidden.",
      "Because b [2.0, inf) depends on a [1.0, 1.0] which depends on " &
        "b [1.0, 1.0], b [2.0, inf) is forbidden.",
      "Thus, every version of b is forbidden.",
      "So, because root depends on b *, version solving failed."
    ]

  test "no version that matches while backtracking (pub #15550)":
    var reg: Registry
    reg.add("root", v(1, 0), dep("a", anyVersion()),
            dep("b", greaterThan(v(1, 0))))
    reg.add("a", v(1, 0))
    reg.add("b", v(1, 0))
    check reg.explain == @[
      "Because root depends on b (1.0, inf) which doesn't match any " &
        "versions, version solving failed."
    ]

  test "a chain collapses across a package no version can anchor (pub #18300)":
    var reg: Registry
    reg.add("root", v(1, 0), dep("angular", anyVersion()),
            dep("collection", anyVersion()))
    reg.add("analyzer", v(0, 12, 2))
    reg.add("angular", v(0, 10),
            dep("di", between(v(0, 0, 32), v(0, 1))),
            dep("collection", between(v(0, 9, 1), v(1, 0))))
    reg.add("angular", v(0, 9, 11),
            dep("di", between(v(0, 0, 32), v(0, 1))),
            dep("collection", between(v(0, 9, 1), v(1, 0))))
    reg.add("angular", v(0, 9, 10),
            dep("di", between(v(0, 0, 32), v(0, 1))),
            dep("collection", between(v(0, 9, 1), v(1, 0))))
    reg.add("collection", v(0, 9, 1))
    reg.add("collection", v(0, 9))
    reg.add("di", v(0, 0, 37), dep("analyzer", between(v(0, 13), v(0, 14))))
    reg.add("di", v(0, 0, 36), dep("analyzer", between(v(0, 13), v(0, 14))))
    check reg.explain == @[
      "Because every version of angular depends on di [0.0.32, 0.1) which " &
        "depends on analyzer [0.13, 0.14), every version of angular " &
        "requires analyzer [0.13, 0.14).",
      "So, because no versions of analyzer match [0.13, 0.14) and root " &
        "depends on angular *, version solving failed."
    ]

suite "upstream: backtracking":
  test "circular dependency on an older version":
    var reg: Registry
    reg.add("root", v(1, 0), dep("a", atLeast(v(1, 0))))
    reg.add("a", v(2, 0), dep("b", exactly(1)))
    reg.add("a", v(1, 0))
    reg.add("b", v(1, 0), dep("a", exactly(1)))
    let res = solve(reg, "root", v(1, 0))
    check res.solution == @["a 1.0", "root 1.0"]
    check res.attemptedSolutions == 2

  test "diamond dependency graph":
    var reg: Registry
    reg.add("root", v(1, 0), dep("a", anyVersion()), dep("b", anyVersion()))
    reg.add("a", v(2, 0), dep("c", caret(1)))
    reg.add("a", v(1, 0))
    reg.add("b", v(2, 0), dep("c", caret(3)))
    reg.add("b", v(1, 0), dep("c", caret(2)))
    reg.add("c", v(3, 0))
    reg.add("c", v(2, 0))
    reg.add("c", v(1, 0))
    check solve(reg, "root", v(1, 0)).solution ==
      @["a 1.0", "b 2.0", "c 3.0", "root 1.0"]

  test "rolls back leaf versions first":
    # a and b's newest versions disagree on c; b, the leafier one, is the one
    # that must be downgraded.
    var reg: Registry
    reg.add("root", v(1, 0), dep("a", anyVersion()))
    reg.add("a", v(2, 0), dep("b", anyVersion()), dep("c", exactly(2)))
    reg.add("a", v(1, 0), dep("b", anyVersion()))
    reg.add("b", v(2, 0), dep("c", exactly(1)))
    reg.add("b", v(1, 0))
    reg.add("c", v(2, 0))
    reg.add("c", v(1, 0))
    check solve(reg, "root", v(1, 0)).solution ==
      @["a 2.0", "b 1.0", "c 2.0", "root 1.0"]

  test "simple transitive - downgrade until the only baz fits":
    var reg: Registry
    reg.add("root", v(1, 0), dep("foo", anyVersion()))
    reg.add("foo", v(3, 0), dep("bar", exactly(3)))
    reg.add("foo", v(2, 0), dep("bar", exactly(2)))
    reg.add("foo", v(1, 0), dep("bar", exactly(1)))
    reg.add("bar", v(3, 0), dep("baz", exactly(3)))
    reg.add("bar", v(2, 0), dep("baz", exactly(2)))
    reg.add("bar", v(1, 0), dep("baz", anyVersion()))
    reg.add("baz", v(1, 0))
    let res = solve(reg, "root", v(1, 0))
    check res.solution == @["bar 1.0", "baz 1.0", "foo 1.0", "root 1.0"]
    check res.attemptedSolutions == 3

  test "backjump to the nearer unsatisfied package":
    # a 2.0 needs a c that does not exist; the solver must not exhaustively
    # walk b's versions to find that out.
    var reg: Registry
    reg.add("root", v(1, 0), dep("a", anyVersion()), dep("b", anyVersion()))
    reg.add("a", v(2, 0), dep("c", exactly(9, 9)))
    reg.add("a", v(1, 0), dep("c", exactly(1)))
    reg.add("b", v(3, 0))
    reg.add("b", v(2, 0))
    reg.add("b", v(1, 0))
    reg.add("c", v(1, 0))
    let res = solve(reg, "root", v(1, 0))
    check res.solution == @["a 1.0", "b 3.0", "c 1.0", "root 1.0"]
    check res.attemptedSolutions == 2

  test "traverses into the package with fewer versions first":
    var reg: Registry
    for i in 1 .. 4:
      reg.add("a", v(i, 0), dep("c", anyVersion()))
    reg.add("a", v(5, 0), dep("c", exactly(1)))
    for i in 1 .. 3:
      reg.add("b", v(i, 0), dep("c", anyVersion()))
    reg.add("b", v(4, 0), dep("c", exactly(2)))
    reg.add("c", v(2, 0))
    reg.add("c", v(1, 0))
    reg.add("root", v(1, 0), dep("a", anyVersion()), dep("b", anyVersion()))
    let res = solve(reg, "root", v(1, 0))
    check res.solution == @["a 4.0", "b 4.0", "c 2.0", "root 1.0"]
    check res.attemptedSolutions == 1

  test "complex backtrack across a hundred versions each":
    # foo i.j needs baz i.0 and bar i.j needs baz 0.j; only baz 0.0 exists,
    # so foo must land on major 0 and bar on minor 0.
    var reg: Registry
    reg.add("root", v(1, 0), dep("foo", anyVersion()), dep("bar", anyVersion()))
    reg.add("baz", v(0, 0))
    for i in 0 .. 9:
      for j in 0 .. 9:
        reg.add("foo", v(i, j), dep("baz", exactly(i)))
        reg.add("bar", v(i, j), dep("baz", exactly(0, j)))
    let res = solve(reg, "root", v(1, 0))
    check res.solution == @["bar 9.0", "baz 0.0", "foo 0.9", "root 1.0"]
    check res.attemptedSolutions == 10

  test "backjumps past a failed package on a disjoint constraint":
    # a 2.0's constraint on foo is disjoint with the root's, so trying other
    # versions of foo is pointless; the solver must go straight back to a.
    var reg: Registry
    reg.add("root", v(1, 0), dep("a", anyVersion()),
            dep("foo", greaterThan(v(2, 0))))
    reg.add("a", v(2, 0), dep("foo", lessThan(v(1, 0))))
    reg.add("a", v(1, 0), dep("foo", anyVersion()))
    reg.add("foo", v(2, 0, 4))
    reg.add("foo", v(2, 0, 3))
    reg.add("foo", v(2, 0, 2))
    reg.add("foo", v(2, 0, 1))
    reg.add("foo", v(2, 0))
    check solve(reg, "root", v(1, 0)).solution ==
      @["a 1.0", "foo 2.0.4", "root 1.0"]

  test "a dependency back onto the root is honoured (pub #18666)":
    # d's versions constrain the root itself. d 1.0 forbids root 1.0, so d 2.0
    # must win, and the failure on the way there must not be forgotten.
    var reg: Registry
    reg.add("root", v(1, 0), dep("a", anyVersion()), dep("c", anyVersion()),
            dep("d", anyVersion()))
    reg.add("a", v(2, 0))
    reg.add("a", v(1, 0))
    reg.add("b", v(1, 0), dep("a", exactly(1)))
    reg.add("c", v(1, 0), dep("b", anyVersion()))
    reg.add("d", v(2, 0), dep("root", anyVersion()))
    reg.add("d", v(1, 0), dep("root", lessThan(v(1, 0))))
    check solve(reg, "root", v(1, 0)).solution ==
      @["a 1.0", "b 1.0", "c 1.0", "d 2.0", "root 1.0"]

suite "upstream: regressions":
  test "every version of b fails for a different reason (pub #3057)":
    # This graph made pub's solver loop forever. The pre-release version in
    # the original (0.9.0-1) is expressed as a plain 0.9.0 here; the loop it
    # provoked was in conflict resolution, not in version ordering.
    var reg: Registry
    reg.add("root", v(1, 0), dep("a", exactly(0, 12)), dep("b", anyVersion()))
    reg.add("a", v(0, 12))
    reg.add("b", v(0, 17), dep("a", exactly(1)))
    reg.add("b", v(0, 10), dep("a", exactly(1)))
    reg.add("b", v(0, 9), dep("c", between(v(1, 6), v(2, 0))))
    reg.add("b", v(0, 1), dep("c", exactly(2)))
    reg.add("c", v(2, 0, 1))
    let res = solve(reg, "root", v(1, 0))
    check res.outcome == soUnsolvable
    check report(res.failure, "root").splitLines == @[
      "Because b (-inf, 0.9) depends on c [2.0, 2.0] which doesn't match " &
        "any versions, b (-inf, 0.9) is forbidden.",
      "And because b [0.10, inf) depends on a [1.0, 1.0], " &
        "b (-inf, 0.9) | [0.10, inf) requires a [1.0, 1.0].",
      "And because b [0.9, 0.10) depends on c [1.6, 2.0) which doesn't " &
        "match any versions, every version of b requires a [1.0, 1.0].",
      "So, because root depends on both a [0.12, 0.12] and b *, version " &
        "solving failed."
    ]
