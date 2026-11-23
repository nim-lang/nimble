{.used.}

import std/[unittest, strutils, options, tables]
import pubgrub/[ranges, solver, report]
import ./registry

## Golden output for the error-reporting examples in PubGrub's documentation.
##
## The sentences match Dart's, the version syntax does not: `Ranges` prints
## intervals, so `^1.0.0` shows up as `[1.0, 2.0)`. Comparing line by line
## keeps a failure readable and stops trailing whitespace from mattering.

type PerVersion = object
  ## The registry without its `dependencyRangeHook`: each dependency is stated
  ## for the one version it was read from, the way Nimble's provider does.
  reg: Registry

proc chooseVersion(p: PerVersion, package: string,
                   allowed: VerSet): Option[Ver] =
  p.reg.chooseVersion(package, allowed)

proc dependencies(p: PerVersion, package: string, version: Ver): seq[Dep] =
  p.reg.dependencies(package, version)

proc versionCountHook(p: PerVersion, package: string, allowed: VerSet): int =
  p.reg.versionCountHook(package, allowed)

proc explain[Provider](provider: Provider): seq[string] =
  let res = solve(provider, "root", v(1, 0))
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

proc nimPins(fooVersions: openArray[int]): Registry =
  ## root needs nim 3.0 or newer, and the n-th version of foo pins nim n.0, so
  ## every version of foo is ruled out - by a different dependency each.
  result.add("root", v(1, 0), dep("nim", atLeast(v(3, 0))),
             dep("foo", anyVersion()))
  for n in 1 .. 3: result.add("nim", v(n, 0))
  for i, fooVersion in fooVersions:
    result.add("foo", v(fooVersion, 0), dep("nim", exactly(i + 1)))

suite "report: one subject per clause":
  test "two versions with their own dependencies are two facts":
    # Not "foo [2.0, inf) depends on both nim [2.0, 2.0] and nim [1.0, 1.0]",
    # which is false and never names foo 1.0.
    check nimPins([1, 2]).explain == @[
      "Because foo [2.0, inf) depends on nim [2.0, 2.0] and foo (-inf, 2.0) " &
        "depends on nim [1.0, 1.0], every version of foo requires " &
        "nim [1.0, 1.0] | [2.0, 2.0].",
      "So, because root depends on both nim [3.0, inf) and foo *, " &
        "version solving failed."
    ]

  test "the versions a package doesn't have are not a clause of their own":
    # Stated version by version, foo running out of versions is a fact of its
    # own: no versions of foo match the gaps around 10.0 and 20.0. That is how
    # the solver knows there are no more, not something the reader needs -
    # and with foo's versions far from nim's, nim [1.0, 1.0] fits inside
    # those gaps, which once read as "foo 10.0 depends on foo ... which
    # doesn't match any versions".
    check PerVersion(reg: nimPins([10, 20])).explain == @[
      "Because foo [20.0, 20.0] depends on nim [2.0, 2.0] and " &
        "foo [10.0, 10.0] depends on nim [1.0, 1.0], every version of foo " &
        "requires nim [1.0, 1.0] | [2.0, 2.0].",
      "So, because root depends on both nim [3.0, inf) and foo *, " &
        "version solving failed."
    ]

  test "what a dependency allows keeps the versions no one has":
    # Only the versions a package is said to be at lose the gaps. Here a gap
    # is the conflict: the only versions foo and bar both allow, [2.9, 3.0),
    # don't exist.
    var reg: Registry
    reg.add("root", v(1, 0), dep("foo", anyVersion()),
            dep("bar", anyVersion()))
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
      "So, because root depends on both foo * and bar *, version solving " &
        "failed."
    ]

type Listing = object
  ## The registry with a `versionsTextHook`: the versions a package is at are
  ## the ones it has, and what a dependency allows is marked as such.
  reg: Registry

proc chooseVersion(p: Listing, package: string,
                   allowed: VerSet): Option[Ver] =
  p.reg.chooseVersion(package, allowed)

proc dependencies(p: Listing, package: string, version: Ver): seq[Dep] =
  p.reg.dependencies(package, version)

proc dependencyRangeHook(p: Listing, package: string, version: Ver,
                         dependency: Dep): VerSet =
  p.reg.dependencyRangeHook(package, version, dependency)

proc versionsTextHook(p: Listing, package: string, versions: VerSet,
                      positive: bool): string =
  if versions.isFull: return ""
  if not positive: return "in " & $versions
  var listed: seq[string]
  for (version, _) in p.reg.packages[package]:
    if versions.contains(version): listed.add $version
  listed.join(" or ")

suite "report: versions written by the provider":
  test "its hook writes every set, by the side it is on":
    let listing = Listing(reg: nimPins([1, 2]))
    let res = solve(listing, "root", v(1, 0))
    check report(res.failure, "root", listing).splitLines == @[
      "Because foo 1.0 depends on nim in [1.0, 1.0] and foo 2.0 depends on " &
        "nim in [2.0, 2.0], every version of foo requires nim in " &
        "[1.0, 1.0] | [2.0, 2.0].",
      "So, because root depends on both nim in [3.0, inf) and foo, version " &
        "solving failed."
    ]

  test "without the hook, versions are written by `$`":
    let reg = nimPins([1, 2])
    let res = solve(reg, "root", v(1, 0))
    check report(res.failure, "root", reg) == report(res.failure, "root")

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
