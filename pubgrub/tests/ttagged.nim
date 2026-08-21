# Copyright (C) 2026 the Nim PubGrub authors. All rights reserved.
# BSD License. Look at license.txt for more info.

## `TaggedRanges`: the version set for universes where some versions are tags
## (branch heads, commit pins) with identity but no order.
##
## The solver scenarios mirror the shape Nimble hits in the wild: two packages
## pinning *different* commits of the same dependency, and a pin conflicting
## with an ordinary range. Those are exactly the graphs a purely ordered
## version set cannot even represent.

import std/[unittest, options, algorithm, tables, strutils]
import pubgrub
import ./registry

type
  TV = TaggedVersion[Ver, string]
  TVS = TaggedRanges[Ver, string]
  TDep = Dependency[string, TVS]

proc lv(major: int; minor = 0): TV = lineVersion[Ver, string](v(major, minor))
proc tv(t: string): TV = tagVersion[Ver, string](t)
proc tag(t: string): TVS = onlyTags[Ver, string](@[t])
proc line(s: VerSet): TVS = tagged[Ver, string](s)
proc anyAtAll(): TVS = taggedFull[Ver, string]()
proc nothing(): TVS = taggedEmpty[Ver, string]()

suite "tagged: algebra":
  test "a tag is not on the line and the line holds no tags":
    check tag("#head").contains(tv("#head"))
    check not tag("#head").contains(lv(1))
    check not line(anyVersion()).contains(tv("#head"))
    check line(caret(1)).contains(lv(1, 5))

  test "singleton works for both kinds of version":
    check singleton(lv(1, 2)) == line(exactly(1, 2))
    check singleton(tv("#head")) == tag("#head")

  test "complement flips both dimensions":
    let c = complement(tag("#head"))
    check c.contains(lv(1))
    check c.contains(tv("#abc123"))
    check not c.contains(tv("#head"))
    check complement(c) == tag("#head")

  test "empty and full":
    check nothing().isEmpty
    check anyAtAll().isFull
    check complement(nothing()) == anyAtAll()
    check not tag("#head").isEmpty
    check not line(anyVersion()).isFull

  test "intersection across the four finiteness combinations":
    let two = onlyTags[Ver, string](@["#a", "#b"])
    check intersection(two, tag("#a")) == tag("#a")
    check intersection(two, complement(tag("#a"))) == tag("#b")
    check intersection(complement(tag("#a")), two) == tag("#b")
    check intersection(complement(tag("#a")), complement(tag("#b"))) ==
      complement(onlyTags[Ver, string](@["#a", "#b"]))

  test "union joins line and tags independently":
    let mixed = union(line(caret(1)), tag("#head"))
    check mixed.contains(lv(1, 9))
    check mixed.contains(tv("#head"))
    check not mixed.contains(lv(2))
    check not mixed.contains(tv("#abc123"))
    check union(tag("#a"), tag("#b")) == onlyTags[Ver, string](@["#a", "#b"])

  test "difference and subset/disjoint":
    let mixed = union(line(caret(1)), tag("#head"))
    check difference(mixed, tag("#head")) == line(caret(1))
    check tag("#head").isSubsetOf(mixed)
    check line(caret(1)).isSubsetOf(mixed)
    check not mixed.isSubsetOf(tag("#head"))
    check tag("#a").isDisjointFrom(tag("#b"))
    check line(anyVersion()).isDisjointFrom(tag("#head"))

  test "equality is set equality, not representation equality":
    check onlyTags[Ver, string](@["#a", "#b"]) ==
      onlyTags[Ver, string](@["#b", "#a", "#a"])
    check onlyTags[Ver, string](@["#a"]) != onlyTags[Ver, string](@["#b"])
    check tag("#a") != complement(tag("#a"))

  test "rendering":
    check $nothing() == "<empty>"
    check $anyAtAll() == "*"
    check $tag("#head") == "#head"
    check $union(line(caret(1)), tag("#head")) == "[1.0, 2.0) | #head"
    check $complement(tag("#head")) == "* | <any tag except #head>"

suite "tagged: terms":
  test "two different pins are disjoint, so both cannot hold":
    check relation(positiveTerm(tag("#a")), positiveTerm(tag("#b"))) ==
      srDisjoint

  test "a pin does not satisfy a range and a range does not satisfy a pin":
    check relation(positiveTerm(tag("#head")),
                   positiveTerm(line(caret(1)))) == srDisjoint
    check relation(positiveTerm(line(caret(1))),
                   positiveTerm(tag("#head"))) == srDisjoint

  test "a pin satisfies a translated set that includes it":
    let widened = union(line(caret(1)), tag("#head"))
    check satisfies(positiveTerm(tag("#head")), positiveTerm(widened))

# ------------------------------------------------------------------ solving

type TaggedRegistry = object
  ## Versions are kept in the order they are added; `chooseVersion` prefers
  ## the earliest listed, so tests control preference by listing order.
  packages: OrderedTable[string, seq[tuple[version: TV, deps: seq[TDep]]]]

proc add(reg: var TaggedRegistry, name: string, version: TV,
         deps: varargs[TDep]) =
  reg.packages.mgetOrPut(name, @[]).add (version, @deps)

proc chooseVersion(reg: TaggedRegistry, package: string,
                   allowed: TVS): Option[TV] =
  if package notin reg.packages: return none(TV)
  for (ver, _) in reg.packages[package]:
    if allowed.contains(ver): return some(ver)

proc dependencies(reg: TaggedRegistry, package: string,
                  version: TV): seq[TDep] =
  for (ver, deps) in reg.packages[package]:
    if ver == version: return deps

proc dependencyRangeHook(reg: TaggedRegistry, package: string, version: TV,
                         dependency: TDep): TVS =
  ## Tagged versions have no order to widen along, so the only widening that
  ## is both sound and simple: if every version of the package declares this
  ## exact constraint, state it for all of them; otherwise state it for the
  ## one version it was read from.
  for (_, deps) in reg.packages[package]:
    var declares = false
    for d in deps:
      if d.package == dependency.package and d.versions == dependency.versions:
        declares = true
        break
    if not declares: return singleton(version)
  taggedFull[Ver, string]()

proc versionCountHook(reg: TaggedRegistry, package: string,
                      allowed: TVS): int =
  if package notin reg.packages: return 0
  for (ver, _) in reg.packages[package]:
    if allowed.contains(ver): inc result

proc solution(res: SolveResult[string, TV, TVS]): seq[string] =
  doAssert res.outcome == soSolved, "expected a solution, got a failure"
  for (package, version) in res.packages:
    result.add package & " " & $version
  sort result

suite "tagged: solving":
  test "a pinned branch resolves alongside ordinary ranges":
    var reg: TaggedRegistry
    reg.add "root", lv(1),
      (package: "foo", versions: tag("#head")),
      (package: "bar", versions: line(caret(1)))
    reg.add "foo", tv("#head"), (package: "bar", versions: line(caret(1)))
    reg.add "bar", lv(1, 2)

    check solution(solve(reg, "root", lv(1))) ==
      @["bar 1.2", "foo #head", "root 1.0"]

  test "a set widened by translation lets the pin win over the range":
    # The translation policy from the module docs: a requirement that should
    # admit a pin alongside a range is written as their union. Listing order
    # makes the provider prefer the pin.
    var reg: TaggedRegistry
    reg.add "root", lv(1),
      (package: "foo", versions: union(line(caret(1)), tag("#head")))
    reg.add "foo", tv("#head")
    reg.add "foo", lv(1, 5)

    check solution(solve(reg, "root", lv(1))) ==
      @["foo #head", "root 1.0"]

  test "two packages pinning different commits of one dependency conflict":
    # The asynctools shape: jester wants one fork's commit, httpbeast wants
    # another, and no version of asynctools is both.
    var reg: TaggedRegistry
    reg.add "root", lv(1),
      (package: "jester", versions: anyAtAll()),
      (package: "httpbeast", versions: anyAtAll())
    reg.add "jester", lv(1),
      (package: "asynctools", versions: tag("#pr_fix_compilation"))
    reg.add "httpbeast", lv(1),
      (package: "asynctools", versions: tag("#0e6bdc3"))
    reg.add "asynctools", tv("#pr_fix_compilation")
    reg.add "asynctools", tv("#0e6bdc3")

    let res = solve(reg, "root", lv(1))
    check res.outcome == soUnsolvable
    check report(res.failure, "root").splitLines == @[
      "Because every version of httpbeast depends on asynctools #0e6bdc3 " &
        "and every version of jester depends on asynctools " &
        "#pr_fix_compilation, httpbeast is incompatible with jester.",
      "So, because root depends on both jester * and httpbeast *, " &
        "version solving failed."
    ]

  test "a pin that satisfies no available version is explained":
    var reg: TaggedRegistry
    reg.add "root", lv(1), (package: "foo", versions: tag("#head"))
    reg.add "foo", lv(1, 5)

    let res = solve(reg, "root", lv(1))
    check res.outcome == soUnsolvable
    check report(res.failure, "root").splitLines == @[
      "Because root depends on foo #head which doesn't match any versions, " &
        "version solving failed."
    ]
