{.used.}
import unittest
import testscommon
import std/[tables]
import nimblepkg/[version, nimblesat, options, packageinfotypes]

proc solveWith(pkgVersionTable: Table[string, PackageVersions],
               algorithm: ResolutionAlgorithm): Table[string, Version] =
  ## Build the SAT formula with `algorithm` and return the selected versions.
  var graph = pkgVersionTable.toDepGraph()
  let form = toFormular(graph, algorithm)
  var packages = initTable[string, Version]()
  var output = ""
  check solve(graph, form, packages, output, initOptions())
  result = packages

proc table(root: PackageMinimalInfo,
           deps: varargs[PackageVersions]): Table[string, PackageVersions] =
  result = initTable[string, PackageVersions]()
  result[root.name] = PackageVersions(pkgName: root.name, versions: @[root])
  for d in deps:
    result[d.pkgName] = d

suite "resolution algorithm":
  let root = PackageMinimalInfo(
    name: "a", version: newVersion "1.0.0", isRoot: true,
    requires: @[(name: "b", ver: parseVersionRange ">= 1.0.0")])
  let bVersions = PackageVersions(pkgName: "b", versions: @[
    PackageMinimalInfo(name: "b", version: newVersion "1.0.0"),
    PackageMinimalInfo(name: "b", version: newVersion "1.1.0"),
    PackageMinimalInfo(name: "b", version: newVersion "1.2.0")])

  test "MaxVer selects the newest satisfying version":
    let picked = solveWith(table(root, bVersions), raMaxVer)
    check picked["b"] == newVersion "1.2.0"

  test "MinVer selects the oldest satisfying version":
    let picked = solveWith(table(root, bVersions), raMinVer)
    check picked["b"] == newVersion "1.0.0"

  test "MinVer still respects the lower bound of the range":
    # root requires b >= 1.1.0, so 1.0.0 is out of range; MinVer picks 1.1.0.
    let r = PackageMinimalInfo(
      name: "a", version: newVersion "1.0.0", isRoot: true,
      requires: @[(name: "b", ver: parseVersionRange ">= 1.1.0")])
    let picked = solveWith(table(r, bVersions), raMinVer)
    check picked["b"] == newVersion "1.1.0"

  test "MinVer does not prefer a special (#head) version over a regular one":
    let bWithHead = PackageVersions(pkgName: "b", versions: @[
      PackageMinimalInfo(name: "b", version: newVersion "1.0.0"),
      PackageMinimalInfo(name: "b", version: newVersion "1.1.0"),
      PackageMinimalInfo(name: "b", version: newVersion "#head")])
    let picked = solveWith(table(root, bWithHead), raMinVer)
    check picked["b"] == newVersion "1.0.0"
    check not picked["b"].isSpecial

  test "MinVer picks a #special version when another package requires it":
    let r = PackageMinimalInfo(
      name: "a", version: newVersion "1.0.0", isRoot: true,
      requires: @[
        (name: "b", ver: VersionRange(kind: verAny)),
        (name: "c", ver: parseVersionRange ">= 1.0.0")])
    let bVers = PackageVersions(pkgName: "b", versions: @[
      PackageMinimalInfo(name: "b", version: newVersion "0.1.0"),
      PackageMinimalInfo(name: "b", version: newVersion "0.2.0"),
      PackageMinimalInfo(name: "b", version: newVersion "#head")])
    let cVers = PackageVersions(pkgName: "c", versions: @[
      PackageMinimalInfo(name: "c", version: newVersion "1.0.0",
        requires: @[(name: "b", ver: parseVersionRange "#head")])])
    let picked = solveWith(table(r, bVers, cVers), raMinVer)
    check picked["b"] == newVersion "#head"
    check picked["b"].isSpecial
    check picked["c"] == newVersion "1.0.0"

