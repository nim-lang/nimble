{.used.}
# Resolver tests for #1814: discovery range pruning.
#
# Two layers:
#   - Discovery tests run collectAllVersions against a data-driven mock and
#     assert which versions get DISCOVERED/processed (range pruning, failedReqs).
#   - Solver tests build a version table directly and run the SAT solver,
#     asserting which versions get SELECTED (multiple packages requiring the same
#     dependency, fallback to older versions, max/min resolution).
#
# All tests are offline (mock-based).

import unittest
import std/[tables, sequtils, options]
import chronos
import nimblepkg/[version, nimblesat, options, packageinfotypes, versiondiscovery]
from nimblepkg/common import NimbleError

let nimBin = some("nim")

type
  MockVersion = object
    version: string
    requires: seq[PkgTuple]

var mockSpec {.threadvar.}: Table[string, seq[MockVersion]]

proc genericMock(pv: PkgTuple, options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
  ## Returns the versions declared in `mockSpec` for a package; anything else
  ## (e.g. a deleted/renamed repo) fails like an unresolvable URL.
  if pv.name in mockSpec:
    for mv in mockSpec[pv.name]:
      result.add PackageMinimalInfo(
        name: pv.name, version: newVersion(mv.version), requires: mv.requires)
  else:
    raise newException(NimbleError, "Unable to identify url: " & pv.name)

proc collect(root: PackageMinimalInfo, options: var Options): TableRef[string, PackageVersions] =
  options.parallelDiscovery = false
  result = waitFor collectAllVersions(root, options, genericMock, nimBin = nimBin)

proc discoveredVersions(table: TableRef[string, PackageVersions], name: string): seq[string] =
  if table.hasKey(name):
    result = table[name].versions.mapIt($it.version)

proc rootPkg(requires: seq[PkgTuple]): PackageMinimalInfo =
  PackageMinimalInfo(name: "root", version: newVersion("1.0.0"), isRoot: true,
                     requires: requires)

proc pkg(name: string, version: string, requires: seq[PkgTuple] = @[]): PackageMinimalInfo =
  PackageMinimalInfo(name: name, version: newVersion(version), requires: requires)

proc vers(name: string, versions: seq[PackageMinimalInfo]): PackageVersions =
  PackageVersions(pkgName: name, versions: versions)

proc req(name: string, rng = ""): PkgTuple =
  (name: name, ver: parseVersionRange(rng))

proc solved(root: PackageMinimalInfo, options: Options, pkgs: varargs[PackageVersions]): Table[string, Version] =
  ## Runs the SAT solver over `root` + `pkgs` and returns name -> selected version.
  var table = initTable[string, PackageVersions]()
  table[root.name] = PackageVersions(pkgName: root.name, versions: @[root])
  for p in pkgs:
    table[p.pkgName] = p
  var output = ""
  for s in table.getSolvedPackages(output, options):
    result[s.pkgName] = s.version

proc solveDiscovered(root: PackageMinimalInfo, options: var Options): seq[SolvedPackage] =
  ## Runs discovery (via the mock) then solves, returning the solved packages.
  let table = collect(root, options)
  table["root"] = PackageVersions(pkgName: "root", versions: @[root])
  var output = ""
  result = table[].getSolvedPackages(output, options)

suite "issue1814: discovery range pruning and resolution":
  test "only versions within the requested range are discovered (>=)":
    mockSpec = {"dep": @[
      MockVersion(version: "0.1.4"),
      MockVersion(version: "0.1.5"),
      MockVersion(version: "0.1.6")]}.toTable
    var options = initOptions()
    let table = collect(rootPkg(@[req("dep", ">= 0.1.5")]), options)
    check discoveredVersions(table, "dep") == @["0.1.5", "0.1.6"]

  test "only versions below the upper bound are discovered (<)":
    mockSpec = {"dep": @[
      MockVersion(version: "0.1.4"),
      MockVersion(version: "0.1.5")]}.toTable
    var options = initOptions()
    let table = collect(rootPkg(@[req("dep", "< 0.1.5")]), options)
    check discoveredVersions(table, "dep") == @["0.1.4"]

  test "only the exact version is discovered (==)":
    mockSpec = {"dep": @[
      MockVersion(version: "0.1.4"),
      MockVersion(version: "0.1.5"),
      MockVersion(version: "0.1.6")]}.toTable
    var options = initOptions()
    let table = collect(rootPkg(@[req("dep", "== 0.1.5")]), options)
    check discoveredVersions(table, "dep") == @["0.1.5"]

  test "exclusive intersection keeps only in-range versions (> X & < Y)":
    mockSpec = {"dep": @[
      MockVersion(version: "0.1.4"),
      MockVersion(version: "0.1.5"),
      MockVersion(version: "0.1.6")]}.toTable
    var options = initOptions()
    let table = collect(rootPkg(@[req("dep", "> 0.1.4 & < 0.1.6")]), options)
    check discoveredVersions(table, "dep") == @["0.1.5"]

  test "caret range prunes to >= major and < next major (^=)":
    mockSpec = {"dep": @[
      MockVersion(version: "0.9.0"),
      MockVersion(version: "1.0.0"),
      MockVersion(version: "1.5.0"),
      MockVersion(version: "2.0.0")]}.toTable
    var options = initOptions()
    let table = collect(rootPkg(@[req("dep", "^= 1.0.0")]), options)
    check discoveredVersions(table, "dep") == @["1.0.0", "1.5.0"]

  test "tilde range prunes to the compatible patch range (~=)":
    # nimble's ~= bumps the second-to-last given component: ~= 1.2.5 => < 1.3.0.
    mockSpec = {"dep": @[
      MockVersion(version: "1.2.5"),
      MockVersion(version: "1.2.9"),
      MockVersion(version: "1.3.0")]}.toTable
    var options = initOptions()
    let table = collect(rootPkg(@[req("dep", "~= 1.2.5")]), options)
    check discoveredVersions(table, "dep") == @["1.2.5", "1.2.9"]

  test "no range discovers every version (any)":
    mockSpec = {"dep": @[
      MockVersion(version: "0.1.4"),
      MockVersion(version: "0.1.5")]}.toTable
    var options = initOptions()
    let table = collect(rootPkg(@[req("dep")]), options)
    check discoveredVersions(table, "dep") == @["0.1.4", "0.1.5"]

  test "a version outside every branch's range is never processed":
    mockSpec = {
      "a": @[MockVersion(version: "1.0.0", requires: @[req("dep", ">= 0.1.5")])],
      "b": @[MockVersion(version: "1.0.0", requires: @[req("dep", ">= 0.1.6")])],
      "dep": @[
        MockVersion(version: "0.1.4"),
        MockVersion(version: "0.1.5"),
        MockVersion(version: "0.1.6")]}.toTable
    var options = initOptions()
    let table = collect(rootPkg(@[req("a", ">= 1.0.0"), req("b", ">= 1.0.0")]), options)
    # 0.1.4 satisfies neither branch; only in-range versions are discovered.
    check discoveredVersions(table, "dep") == @["0.1.5", "0.1.6"]

  test "a version whose dependency fails to resolve is excluded, the clean one is selected":
    mockSpec = {"dep": @[
      MockVersion(version: "0.1.4", requires: @[req("https://github.com/example/dead-url")]),
      MockVersion(version: "0.1.5")]}.toTable
    var options = initOptions()
    let table = collect(rootPkg(@[req("dep", ">= 0.1.4")]), options)
    check discoveredVersions(table, "dep") == @["0.1.5"]

  test "when every candidate version is unresolvable, none is available":
    mockSpec = {"dep": @[
      MockVersion(version: "0.1.4", requires: @[req("https://github.com/example/dead-url")]),
      MockVersion(version: "0.1.5", requires: @[req("https://github.com/example/dead-url")])]}.toTable
    var options = initOptions()
    let table = collect(rootPkg(@[req("dep", ">= 0.1.4")]), options)
    check not table.hasKey("dep")

  test "a failed dependency doesn't remove other versions of the same package":
    mockSpec = {"parent": @[
      MockVersion(version: "1.0.0", requires: @[req("https://github.com/example/dead-url")]),
      MockVersion(version: "1.0.1")]}.toTable
    var options = initOptions()
    let table = collect(rootPkg(@[req("parent", ">= 1.0.0")]), options)
    check discoveredVersions(table, "parent") == @["1.0.1"]

  test "two packages requiring different >= bounds pick the max":
    let root = rootPkg(@[req("a", ">= 1.0.0"), req("b", ">= 1.0.0")])
    let res = solved(root, initOptions(),
      vers("a", @[pkg("a", "1.0.0", @[req("x", ">= 0.1.4")])]),
      vers("b", @[pkg("b", "1.0.0", @[req("x", ">= 0.1.5")])]),
      vers("x", @[pkg("x", "0.1.4"), pkg("x", "0.1.5")]))
    check res["x"] == newVersion("0.1.5")

  test "conflicting requirements are unsatisfiable (>= and <= don't overlap)":
    let root = rootPkg(@[req("a", ">= 1.0.0"), req("b", ">= 1.0.0")])
    let res = solved(root, initOptions(),
      vers("a", @[pkg("a", "1.0.0", @[req("x", ">= 0.1.5")])]),
      vers("b", @[pkg("b", "1.0.0", @[req("x", "<= 0.1.4")])]),
      vers("x", @[pkg("x", "0.1.4"), pkg("x", "0.1.5")]))
    check res.len == 0

  test "an exact requirement narrows a range to that version":
    let root = rootPkg(@[req("a", ">= 1.0.0"), req("b", ">= 1.0.0")])
    let res = solved(root, initOptions(),
      vers("a", @[pkg("a", "1.0.0", @[req("x", ">= 0.1.4")])]),
      vers("b", @[pkg("b", "1.0.0", @[req("x", "== 0.1.4")])]),
      vers("x", @[pkg("x", "0.1.4"), pkg("x", "0.1.5")]))
    check res["x"] == newVersion("0.1.4")

  test "an upper bound narrows the selection":
    let root = rootPkg(@[req("a", ">= 1.0.0"), req("b", ">= 1.0.0")])
    let res = solved(root, initOptions(),
      vers("a", @[pkg("a", "1.0.0", @[req("x", ">= 0.1.4")])]),
      vers("b", @[pkg("b", "1.0.0", @[req("x", "< 0.1.5")])]),
      vers("x", @[pkg("x", "0.1.4"), pkg("x", "0.1.5")]))
    check res["x"] == newVersion("0.1.4")

  test "three packages select the newest version in the common overlap":
    let root = rootPkg(@[req("a", ">= 1.0.0"), req("b", ">= 1.0.0"), req("c", ">= 1.0.0")])
    let res = solved(root, initOptions(),
      vers("a", @[pkg("a", "1.0.0", @[req("x", ">= 0.1.4")])]),
      vers("b", @[pkg("b", "1.0.0", @[req("x", ">= 0.1.5")])]),
      vers("c", @[pkg("c", "1.0.0", @[req("x", "< 0.1.6")])]),
      vers("x", @[pkg("x", "0.1.4"), pkg("x", "0.1.5"), pkg("x", "0.1.6")]))
    check res["x"] == newVersion("0.1.5")

  test "a diamond dependency resolves consistently":
    let root = rootPkg(@[req("a", ">= 1.0.0"), req("b", ">= 1.0.0")])
    let res = solved(root, initOptions(),
      vers("a", @[pkg("a", "1.0.0", @[req("x", ">= 0.1.4")])]),
      vers("b", @[pkg("b", "1.0.0", @[req("x", ">= 0.1.5")])]),
      vers("x", @[pkg("x", "0.1.4"), pkg("x", "0.1.5")]))
    check res["a"] == newVersion("1.0.0")
    check res["b"] == newVersion("1.0.0")
    check res["x"] == newVersion("0.1.5")

  test "solver falls back to an older dependency when the newer one is unsolvable":
    # parent 1.0.0 requires dep >= 0.1.4; parent 1.0.1 requires dep >= 0.1.5.
    # dep 0.1.5 is unsolvable, so the solver must fall back to parent 1.0.0 + dep 0.1.4.
    mockSpec = {
      "parent": @[
        MockVersion(version: "1.0.0", requires: @[req("dep", ">= 0.1.4")]),
        MockVersion(version: "1.0.1", requires: @[req("dep", ">= 0.1.5")])],
      "dep": @[
        MockVersion(version: "0.1.4"),
        MockVersion(version: "0.1.5", requires: @[req("https://github.com/example/dead-url")])]}.toTable
    var options = initOptions()
    let solvedPkgs = solveDiscovered(rootPkg(@[req("parent", ">= 1.0.0")]), options)
    let solvedParent = solvedPkgs.filterIt(it.pkgName == "parent")[0]
    let solvedDep = solvedPkgs.filterIt(it.pkgName == "dep")[0]
    check solvedParent.version == newVersion("1.0.0")
    check solvedDep.version == newVersion("0.1.4")

  test "fallback works regardless of the order requirements are collected":
    # Same as above but the version with the looser requirement is collected second.
    mockSpec = {
      "parent": @[
        MockVersion(version: "1.0.1", requires: @[req("dep", ">= 0.1.5")]),
        MockVersion(version: "1.0.0", requires: @[req("dep", ">= 0.1.4")])],
      "dep": @[
        MockVersion(version: "0.1.4"),
        MockVersion(version: "0.1.5", requires: @[req("https://github.com/example/dead-url")])]}.toTable
    var options = initOptions()
    let solvedPkgs = solveDiscovered(rootPkg(@[req("parent", ">= 1.0.0")]), options)
    let solvedParent = solvedPkgs.filterIt(it.pkgName == "parent")[0]
    let solvedDep = solvedPkgs.filterIt(it.pkgName == "dep")[0]
    check solvedParent.version == newVersion("1.0.0")
    check solvedDep.version == newVersion("0.1.4")

  test "multi-level fallback to an older transitive dependency":
    mockSpec = {
      "a": @[
        MockVersion(version: "1.0.0", requires: @[req("b", ">= 0.1.4")]),
        MockVersion(version: "1.0.1", requires: @[req("b", ">= 0.1.5")])],
      "b": @[
        MockVersion(version: "0.1.4"),
        MockVersion(version: "0.1.5", requires: @[req("https://github.com/example/dead-url")])]}.toTable
    var options = initOptions()
    let solvedPkgs = solveDiscovered(rootPkg(@[req("a", ">= 1.0.0")]), options)
    let solvedA = solvedPkgs.filterIt(it.pkgName == "a")[0]
    let solvedB = solvedPkgs.filterIt(it.pkgName == "b")[0]
    check solvedA.version == newVersion("1.0.0")
    check solvedB.version == newVersion("0.1.4")

  test "a broken newest version of a direct dependency falls back to an older one":
    mockSpec = {"a": @[
      MockVersion(version: "1.0.0"),
      MockVersion(version: "1.0.1", requires: @[req("https://github.com/example/dead-url")])]}.toTable
    var options = initOptions()
    let solvedPkgs = solveDiscovered(rootPkg(@[req("a", ">= 1.0.0")]), options)
    let solvedA = solvedPkgs.filterIt(it.pkgName == "a")[0]
    check solvedA.version == newVersion("1.0.0")

  test "max resolution (default) selects the newest satisfying version":
    let root = rootPkg(@[req("x", ">= 0.1.4")])
    let res = solved(root, initOptions(),
      vers("x", @[pkg("x", "0.1.4"), pkg("x", "0.1.5")]))
    check res["x"] == newVersion("0.1.5")

  test "min resolution selects the oldest satisfying version":
    let root = rootPkg(@[req("x", ">= 0.1.4")])
    var options = initOptions()
    options.resolutionAlgorithm = raMinVer
    let res = solved(root, options,
      vers("x", @[pkg("x", "0.1.4"), pkg("x", "0.1.5")]))
    check res["x"] == newVersion("0.1.4")
