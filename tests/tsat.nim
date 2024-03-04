{.used.}
import unittest, os
import testscommon
from nimblepkg/common import cd
import std/[tables]
import nimblepkg/[version, sha1hashes, packageinfotypes, nimblesat, sat]


let allPackages: seq[PackageBasicInfo] = @[
  (name: "a", version: newVersion "3.0", checksum: Sha1Hash()),
  (name: "a", version: newVersion "4.0", checksum: Sha1Hash()),
  (name: "b", version: newVersion "0.1.0", checksum: Sha1Hash()),
  (name: "b", version: newVersion "0.5", checksum: Sha1Hash()),
  (name: "c", version: newVersion "0.1.0", checksum: Sha1Hash()),
  (name: "c", version: newVersion "0.2.1", checksum: Sha1Hash())
]

suite "SAT solver":
  test "can solve simple SAT":
    let constraintA = parseVersionRange(">= 2.0")
    let constraintB = parseVersionRange("< 1.0")
    let form = toFormular(@[("a", constraintA), ("b", constraintB)], allPackages)
    var s = createSolution(form.f)
    check satisfiable(form.f, s)
    let packages = getPackageVersions(form, s)
    check packages.len == 2
    check packages["a"] == newVersion("4.0")
    check packages["b"] == newVersion("0.5")

  test "solves 'Conflicting dependency resolution' #1162":
    let constraintC = parseVersionRange(">= 0.0.5 & <= 0.1.0")
    let constraintB = parseVersionRange(">= 0.1.4")
    let constraintBC = VersionRange(kind: verAny)
    let constraints = @[("c", constraintC), ("b", constraintB), ("b", constraintBC)]

    let form = toFormular(constraints, allPackages)
    var s = createSolution(form.f)
    check satisfiable(form.f, s)
    let packages = getPackageVersions(form, s)
    check packages.len == 2
    check packages["c"] == newVersion("0.1.0")
    check packages["b"] == newVersion("0.5")

  test "dont solve unsatisfable":
    let constraintA = parseVersionRange(">= 5.0")
    let form = toFormular(@[("a", constraintA)], allPackages)
    var s = createSolution(form.f)
    check not satisfiable(form.f, s)
    let packages = getPackageVersions(form, s)
    check packages.len == 0
  
  test "issue #1162":
    cd "conflictingdepres":
      #integration version of the test above
      #TODO document folder structure setup so others know how to run similar tests
      let (output, exitCode) = execNimble("install", "-l")
      check exitCode == QuitSuccess

    
