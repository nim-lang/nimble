{.used.}

# Copyright (C) the Nimble contributors. All rights reserved.
# BSD License. Look at license.txt for more info.

## The `requires` → PubGrub translation (`nimblepkg/pubgrubexplain`), tested
## in terms of Nimble requirement strings - never PubGrub terms - because the
## thing under test is equivalence with the SAT solver's reading of the same
## requirement:
##
## - a membership oracle: for every requirement string and every candidate
##   version, `satisfiesConstraint(v, range) == translated.contains(v)`,
##   with `satisfiesConstraint` (the strict SAT-side matcher, not the lenient
##   `withinRange`) as the reference;
## - solver-level scenarios whose universes are declared entirely as
##   requires strings, ending in `explainSolveFailure`'s report.

import std/[unittest, options, tables, strutils]
import nimblepkg/version
import nimblepkg/packageinfotypes
import nimblepkg/pubgrubexplain
import nimblepkg/nimblesat
import nimblepkg/options as nimbleopts
import nimblepkg/cli
import pubgrub

proc sv(spe: string, semver = ""): Version =
  ## A special version, optionally carrying the semantic version it resolved
  ## to after download (`speSemanticVersion`).
  result = newVersion(spe)
  doAssert result.isSpecial
  if semver.len > 0:
    result.speSemanticVersion = some(semver)

let candidates = @[
  newVersion("0.9.0"), newVersion("1.0.0"), newVersion("1.2.0"),
  newVersion("1.2.3"), newVersion("1.3.9"), newVersion("1.4.0"),
  newVersion("2.0.0"), newVersion("3.1.2"),
  sv("#head"),                    # no semantic version: never matches ranges
  sv("#f1a2b3c", "1.2.5"),        # commit pin that resolved inside 1.x
  sv("#0e6bdc3", "9.9.9"),        # commit pin that resolved outside
  sv("#devel")
]

proc oracle(requirement: string) =
  ## The equivalence that phase 1 rests on, per requirement string.
  let ran = parseVersionRange(requirement)
  let vs = toVersionSet(ran, candidates)
  for v in candidates:
    checkpoint requirement & " vs " & $v
    check satisfiesConstraint(v, ran) == vs.contains(toTaggedVersion(v))

suite "translation: membership oracle over requires strings":
  test "single comparison operators":
    for req in [">= 1.2.0", "> 1.2.0", "<= 1.2.3", "< 1.4.0", "1.2.3"]:
      oracle req

  test "compound, tilde and caret":
    for req in [">= 1.2 & < 1.4", "~= 1.2", "^= 1.2", "~= 1", "^= 0.9"]:
      oracle req

  test "any":
    oracle ""            # parseVersionRange("") is verAny
    check parseRequires("foo").ver.kind == verAny

  test "special requirements match exactly one tag":
    for req in ["#head", "#f1a2b3c", "#devel", "#HEAD"]:
      oracle req

  test "boundary versions sit exactly where satisfiesConstraint puts them":
    for req in [">= 1.2.3", "< 1.2.3", "<= 1.2.3", "> 1.2.3"]:
      oracle req

suite "translation: structure":
  test "a special requirement admits nothing on the line":
    let vs = toVersionSet(parseVersionRange("#head"), candidates)
    for v in candidates:
      if not v.isSpecial:
        check not vs.contains(toTaggedVersion(v))

  test "tag comparison is case-insensitive like Version.==":
    let vs = toVersionSet(parseVersionRange("#HEAD"), candidates)
    check vs.contains(toTaggedVersion(sv("#head")))

  test "an ordinary range admits only universe specials that resolved into it":
    let vs = toVersionSet(parseVersionRange(">= 1.0 & < 2.0"), candidates)
    check vs.contains(toTaggedVersion(sv("#f1a2b3c", "1.2.5")))
    check not vs.contains(toTaggedVersion(sv("#0e6bdc3", "9.9.9")))
    check not vs.contains(toTaggedVersion(sv("#head")))

# ------------------------------------------------------------------ solving

proc addPkg(t: var Table[string, PackageVersions], name, version: string,
            requires: openArray[string] = [], isRoot = false) =
  ## Declares one package version, its requirements written exactly as they
  ## would be in a .nimble file.
  var mi = PackageMinimalInfo(name: name, version: newVersion(version),
                              isRoot: isRoot)
  for r in requires:
    mi.requires.add parseRequires(r)
  t.mgetOrPut(name, PackageVersions(pkgName: name)).versions.add mi

proc addPkg(t: var Table[string, PackageVersions], name: string,
            version: Version, requires: openArray[string] = []) =
  var mi = PackageMinimalInfo(name: name, version: version)
  for r in requires:
    mi.requires.add parseRequires(r)
  t.mgetOrPut(name, PackageVersions(pkgName: name)).versions.add mi

suite "translation: solving universes declared as requires strings":
  test "a solvable universe is reported as a solver disagreement":
    var t: Table[string, PackageVersions]
    t.addPkg("myapp", "0.1.0", ["foo >= 1.0"], isRoot = true)
    t.addPkg("foo", "1.2.0")
    let (foundSolution, explanation) = explainSolveFailure(t)
    check foundSolution
    check explanation == ""

  test "disjoint constraints on a shared dependency":
    var t: Table[string, PackageVersions]
    t.addPkg("myapp", "0.1.0", ["foo >= 1.0", "bar >= 1.0"], isRoot = true)
    t.addPkg("foo", "1.0.0", ["shared >= 2.0 & < 3.0"])
    t.addPkg("bar", "1.0.0", ["shared >= 4.0"])
    t.addPkg("shared", "2.5.0")
    t.addPkg("shared", "4.1.0")
    let (foundSolution, explanation) = explainSolveFailure(t)
    check not foundSolution
    check "version solving failed" in explanation
    check "foo" in explanation and "bar" in explanation

  test "conflicting commit pins - the asynctools shape":
    var t: Table[string, PackageVersions]
    t.addPkg("myapp", "0.1.0", ["jester", "httpbeast"], isRoot = true)
    t.addPkg("jester", "0.5.0", ["asynctools#pr_fix_compilation"])
    t.addPkg("httpbeast", "0.4.0", ["asynctools#0e6bdc3"])
    t.addPkg("asynctools", sv("#pr_fix_compilation"))
    t.addPkg("asynctools", sv("#0e6bdc3"))
    let (foundSolution, explanation) = explainSolveFailure(t)
    check not foundSolution
    check "incompatible" in explanation
    check "#pr_fix_compilation" in explanation
    check "#0e6bdc3" in explanation

  test "a commit pin can coexist with a range via its semantic version":
    var t: Table[string, PackageVersions]
    t.addPkg("myapp", "0.1.0", ["dep#f1a2b3c", "consumer"], isRoot = true)
    t.addPkg("consumer", "1.0.0", ["dep >= 1.0"])
    t.addPkg("dep", sv("#f1a2b3c", "1.2.5"))
    let (foundSolution, explanation) = explainSolveFailure(t)
    check foundSolution      # solvable: the pin satisfies the range too
    check explanation == ""

  test "package names are matched case-insensitively":
    var t: Table[string, PackageVersions]
    t.addPkg("myapp", "0.1.0", ["Foo >= 1.0"], isRoot = true)
    t.addPkg("foo", "1.2.0")
    check explainSolveFailure(t).foundSolution

  test "a requirement no version can meet is explained":
    var t: Table[string, PackageVersions]
    t.addPkg("myapp", "0.1.0", ["foo >= 2.0"], isRoot = true)
    t.addPkg("foo", "1.2.0")
    let (foundSolution, explanation) = explainSolveFailure(t)
    check not foundSolution
    check "doesn't match any versions" in explanation

# ------------------------------------------------------------------ UX

proc explain(t: Table[string, PackageVersions]): seq[string] =
  ## The exact prose a user sees, line by line.
  let (foundSolution, explanation) = explainSolveFailure(t)
  doAssert not foundSolution, "expected an unsolvable universe"
  explanation.splitLines()

suite "translation: failure report UX":
  ## Goldens on the exact user-facing text, one per failure shape Nimble
  ## users actually hit. If a change makes one of these fail, read the new
  ## text as a user before updating the golden.

  test "a requirement newer than anything published":
    var t: Table[string, PackageVersions]
    t.addPkg("myapp", "0.1.0", ["foo >= 2.0"], isRoot = true)
    t.addPkg("foo", "1.2.0")
    check explain(t) == @[
      "Because myapp depends on foo [2.0, inf) which doesn't match any versions, version solving failed."
    ]

  test "a dependency that does not exist at all":
    var t: Table[string, PackageVersions]
    t.addPkg("myapp", "0.1.0", ["notthere >= 1.0"], isRoot = true)
    check explain(t) == @[
      "Because myapp depends on notthere which doesn't exist, version solving failed."
    ]

  test "two libraries with disjoint ranges on a shared dependency":
    var t: Table[string, PackageVersions]
    t.addPkg("myapp", "0.1.0", ["alib", "blib"], isRoot = true)
    t.addPkg("alib", "1.0.0", ["shared >= 2.0 & < 3.0"])
    t.addPkg("blib", "1.0.0", ["shared >= 4.0"])
    t.addPkg("shared", "4.1.0")
    t.addPkg("shared", "2.5.0")
    check explain(t) == @[
      "Because every version of blib depends on shared [4.0, inf) and every version of alib depends on shared [2.0, 3.0), blib is incompatible with alib.",
      "So, because myapp depends on both alib * and blib *, version solving failed."
    ]

  test "two exact pins that cannot both hold":
    var t: Table[string, PackageVersions]
    t.addPkg("myapp", "0.1.0", ["alib", "blib"], isRoot = true)
    t.addPkg("alib", "1.0.0", ["shared 1.0.0"])
    t.addPkg("blib", "1.0.0", ["shared 2.0.0"])
    t.addPkg("shared", "2.0.0")
    t.addPkg("shared", "1.0.0")
    check explain(t) == @[
      "Because every version of blib depends on shared [2.0.0, 2.0.0] and every version of alib depends on shared [1.0.0, 1.0.0], blib is incompatible with alib.",
      "So, because myapp depends on both alib * and blib *, version solving failed."
    ]

  test "conflicting commit pins on the same dependency":
    var t: Table[string, PackageVersions]
    t.addPkg("myapp", "0.1.0", ["jester", "httpbeast"], isRoot = true)
    t.addPkg("jester", "0.5.0", ["asynctools#pr_fix_compilation"])
    t.addPkg("httpbeast", "0.4.0", ["asynctools#0e6bdc3"])
    t.addPkg("asynctools", sv("#pr_fix_compilation"))
    t.addPkg("asynctools", sv("#0e6bdc3"))
    check explain(t) == @[
      "Because every version of httpbeast depends on asynctools #0e6bdc3 and every version of jester depends on asynctools #pr_fix_compilation, httpbeast is incompatible with jester.",
      "So, because myapp depends on both jester * and httpbeast *, version solving failed."
    ]

  test "a commit pin against a version range":
    var t: Table[string, PackageVersions]
    t.addPkg("jsonrpc", "0.6.1", ["websock >= 0.2.1 & < 0.5.0",
                                  "asyncchannels"], isRoot = true)
    t.addPkg("websock", "0.4.0", ["chronos >= 4.2.0 & < 4.4.0"])
    t.addPkg("asyncchannels", "0.1.0", ["chronos#b71392a"])
    t.addPkg("chronos", sv("#b71392a", "4.4.0"))
    t.addPkg("chronos", "4.2.2")
    check explain(t) == @[
      "Because every version of asyncchannels depends on chronos #b71392a (4.4.0) and every version of websock depends on chronos [4.2.0, 4.4.0), asyncchannels is incompatible with websock.",
      "So, because jsonrpc depends on both websock [0.2.1, 0.5.0) and asyncchannels *, version solving failed."
    ]

  test "a conflict two hops away is collapsed into one sentence":
    var t: Table[string, PackageVersions]
    t.addPkg("myapp", "0.1.0", ["mylib >= 1.0"], isRoot = true)
    t.addPkg("mylib", "1.4.0", ["helper ^= 1.0"])
    t.addPkg("helper", "1.2.0", ["base >= 3.0"])
    t.addPkg("base", "2.9.0")
    check explain(t) == @[
      "Because every version of mylib depends on helper [1.0, 2.0.0) which depends on base [3.0, inf), every version of mylib requires base [3.0, inf).",
      "So, because no versions of base match [3.0, inf) and myapp depends on mylib [1.0, inf), version solving failed."
    ]

  test "requiring #head of a package that only has releases":
    var t: Table[string, PackageVersions]
    t.addPkg("myapp", "0.1.0", ["foo#head"], isRoot = true)
    t.addPkg("foo", "1.2.0")
    t.addPkg("foo", "1.1.0")
    check explain(t) == @[
      "Because myapp depends on foo #head which doesn't match any versions, version solving failed."
    ]

  test "every version of a dependency fails for a different reason":
    var t: Table[string, PackageVersions]
    t.addPkg("myapp", "0.1.0", ["foo >= 1.0 & < 2.0"], isRoot = true)
    t.addPkg("foo", "1.1.0", ["x ^= 1.0", "y ^= 1.0"])
    t.addPkg("foo", "1.0.0", ["a ^= 1.0", "b ^= 1.0"])
    t.addPkg("a", "1.0.0", ["b ^= 2.0"])
    t.addPkg("b", "2.0.0")
    t.addPkg("b", "1.0.0")
    t.addPkg("x", "1.0.0", ["y ^= 2.0"])
    t.addPkg("y", "2.0.0")
    t.addPkg("y", "1.0.0")
    check explain(t) == @[
      "    Because foo [1.0.0, 1.0.0] depends on a [1.0, 2.0.0) which depends on b [2.0, 3.0.0), foo [1.0.0, 1.0.0] requires b [2.0, 3.0.0).",
      "(1) So, because foo [1.0.0, 1.0.0] depends on b [1.0, 2.0.0) and no versions of foo match (1.0.0, 1.1.0) | (1.1.0, 2.0), foo [1.0.0, 1.1.0) | (1.1.0, 2.0) is forbidden.",
      "",
      "    Because foo [1.1.0, 1.1.0] depends on x [1.0, 2.0.0) which depends on y [2.0, 3.0.0), foo [1.1.0, 1.1.0] requires y [2.0, 3.0.0).",
      "    And because foo [1.1.0, 1.1.0] depends on y [1.0, 2.0.0), foo [1.1.0, 1.1.0] is forbidden.",
      "    And foo [1.0.0, 2.0) is forbidden.",
      "    So, because myapp depends on foo [1.0, 2.0), version solving failed."
    ]

  test "nim itself is just another package in the explanation":
    var t: Table[string, PackageVersions]
    t.addPkg("myapp", "0.1.0", ["nim >= 2.0.0"], isRoot = true)
    t.addPkg("nim", "1.6.20")
    check explain(t) == @[
      "Because myapp depends on nim [2.0.0, inf) which doesn't match any versions, version solving failed."
    ]

suite "translation: the explanation reaches getSolvedPackages' output":
  test "SAT failure output ends with the PubGrub report":
    # The real-world shape from tsat's #generateUnsatisfiableMessage
    # regression: websock wants chronos < 4.4.0 while asyncchannels pins a
    # commit whose semantic version is 4.4.0 - disjoint, unsolvable.
    var t: Table[string, PackageVersions]
    t.addPkg("jsonrpc", "0.6.1", ["websock >= 0.2.1 & < 0.5.0",
                                  "asyncchannels"], isRoot = true)
    t.addPkg("websock", "0.4.0", ["chronos >= 4.2.0 & < 4.4.0"])
    t.addPkg("asyncchannels", "0.1.0", ["chronos#b71392a"])
    t.addPkg("chronos", sv("#b71392a", "4.4.0"))
    t.addPkg("chronos", "4.2.2")

    var output = ""
    var opts = initOptions()
    let solved = getSolvedPackages(t, output, opts)
    check solved.len == 0
    # At normal verbosity the explanation IS the whole error - none of the
    # SAT search dump ("No version selected!", "could not be satisfied", ...).
    check output.splitLines == @[
      "Dependency resolution failed:",
      "Because every version of asyncchannels depends on chronos #b71392a (4.4.0) " &
        "and every version of websock depends on chronos [4.2.0, 4.4.0), " &
        "asyncchannels is incompatible with websock.",
      "So, because jsonrpc depends on both websock [0.2.1, 0.5.0) and " &
        "asyncchannels *, version solving failed.",
      ""
    ]

  test "--verbose keeps the SAT search dump above the explanation":
    var t: Table[string, PackageVersions]
    t.addPkg("jsonrpc", "0.6.1", ["websock >= 0.2.1 & < 0.5.0",
                                  "asyncchannels"], isRoot = true)
    t.addPkg("websock", "0.4.0", ["chronos >= 4.2.0 & < 4.4.0"])
    t.addPkg("asyncchannels", "0.1.0", ["chronos#b71392a"])
    t.addPkg("chronos", sv("#b71392a", "4.4.0"))
    t.addPkg("chronos", "4.2.2")

    var output = ""
    var opts = initOptions()
    opts.verbosity = LowPriority
    discard getSolvedPackages(t, output, opts)
    check "version solving failed" in output
    check "Failed to find satisfiable solution" in output

  test "a package that does not exist is explained, not dumped":
    # `nimble add <nonexistent>`: the requirement is reachable but absent from
    # the table. This path returns before the SAT solve, and used to print
    # "Missing dependencies:" followed by every cached package and its
    # requires - pages of noise for a one-line problem.
    var t: Table[string, PackageVersions]
    t.addPkg("ne2", "0.1.0", ["nimbus_eth2"], isRoot = true)
    # Unrelated packages that happen to sit in the cache, as in the report.
    t.addPkg("serialization", "0.5.3", ["faststreams", "unittest2", "stew"])
    t.addPkg("faststreams", "0.3.0")
    t.addPkg("unittest2", "0.2.0")
    t.addPkg("stew", "0.1.0")

    var output = ""
    var opts = initOptions()
    let solved = getSolvedPackages(t, output, opts)
    check solved.len == 0
    check output.splitLines == @[
      "Dependency resolution failed:",
      "Because ne2 depends on nimbus_eth2 which doesn't exist, version " &
        "solving failed.",
      ""
    ]
    # None of the old noise.
    check "Missing dependencies:" notin output
    check "Package serialization" notin output

  test "--verbose still dumps the table for a missing package":
    var t: Table[string, PackageVersions]
    t.addPkg("ne2", "0.1.0", ["nimbus_eth2"], isRoot = true)
    t.addPkg("serialization", "0.5.3", ["faststreams"])
    t.addPkg("faststreams", "0.3.0")

    var output = ""
    var opts = initOptions()
    opts.verbosity = LowPriority
    discard getSolvedPackages(t, output, opts)
    check "Missing dependencies: nimbus_eth2" in output
    check "Package serialization" in output
    check "doesn't exist" in output

  test "a disagreement is flagged as a solver bug, not silence":
    # explainSolveFailure's contract when PubGrub *can* solve what SAT could
    # not: foundSolution=true and no explanation, which getSolvedPackages
    # turns into the report-a-bug note.
    var t: Table[string, PackageVersions]
    t.addPkg("myapp", "0.1.0", ["foo >= 1.0"], isRoot = true)
    t.addPkg("foo", "1.2.0")
    let (foundSolution, explanation) = explainSolveFailure(t)
    check foundSolution and explanation.len == 0
