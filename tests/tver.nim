{.used.}
import unittest
import testscommon
import std/[tables, sequtils]
import nimblepkg/[version, download]

suite "semver version ordering":
  test "a pre-release ranks below its final release":
    check newVersion("1.0.0-rc1") < newVersion("1.0.0")
    check newVersion("0.1-rc1") < newVersion("0.1")
    check newVersion("0.1-rc1") < newVersion("0.2")
    check newVersion("1.0.0-rc1") != newVersion("1.0.0")
    check not (newVersion("1.0.0") < newVersion("1.0.0-rc1"))

  test "full semver pre-release ladder (semver §11)":
    check newVersion("1.0.0-alpha")      < newVersion("1.0.0-alpha.1")
    check newVersion("1.0.0-alpha.1")    < newVersion("1.0.0-alpha.beta")
    check newVersion("1.0.0-alpha.beta") < newVersion("1.0.0-beta")
    check newVersion("1.0.0-beta")       < newVersion("1.0.0-beta.2")
    check newVersion("1.0.0-beta.2")     < newVersion("1.0.0-beta.11")
    check newVersion("1.0.0-beta.11")    < newVersion("1.0.0-rc.1")
    check newVersion("1.0.0-rc.1")       < newVersion("1.0.0")

  test "numeric pre-release identifiers rank below alphanumeric ones":
    check newVersion("1.0.0-1") < newVersion("1.0.0-alpha")
    # numeric identifiers compare numerically, not lexically
    check newVersion("1.0.0-2") < newVersion("1.0.0-11")

  test "build metadata is ignored for precedence":
    check newVersion("1.0.0+build.1") == newVersion("1.0.0+build.2")
    check newVersion("1.0.0+build.1") == newVersion("1.0.0")

  test "plain numeric ordering is unchanged (regression guard)":
    check newVersion("1.0") < newVersion("1.4")
    check newVersion("1.0.1") > newVersion("1.0")
    check newVersion("1") == newVersion("1.0")
    check not (newVersion("0.1.0") < newVersion("0.1"))
    check not (newVersion("0.1.0") > newVersion("0.1"))

  test "special #head still outranks pre-releases and finals":
    check newVersion("1.0.0-rc1") < newVersion("#head")
    check newVersion("1.0.0")     < newVersion("#head")

suite "semver version parsing contexts":
  test "a package version literal accepts a pre-release suffix":
    let v = newVersion("1.0.0-rc1")
    check not v.isSpecial
    check $v == "1.0.0-rc1"

  test "requires version ranges accept a pre-release suffix":
    let r1 = parseVersionRange(">= 1.0.0-rc1")
    check r1.kind == verEqLater
    check r1.ver == newVersion("1.0.0-rc1")

    let r2 = parseVersionRange("1.0.0-rc1")
    check r2.kind == verEq
    check r2.ver == newVersion("1.0.0-rc1")

    let r3 = parseVersionRange("== 1.0.0-rc1")
    check r3.kind == verEq
    check r3.ver == newVersion("1.0.0-rc1")

  test "pre-release constraints order pre-releases correctly":
    check newVersion("1.0.0-rc2") in parseVersionRange(">= 1.0.0-rc1")
    check newVersion("1.0.0")     in parseVersionRange(">= 1.0.0-rc1")
    check newVersion("1.0.0-rc1") notin parseVersionRange("> 1.0.0-rc1")
    check newVersion("0.9.0")     notin parseVersionRange(">= 1.0.0-rc1")

  test "pre-release suffix works inside an intersection range":
    let r = parseVersionRange(">= 1.0.0-rc1 & < 2.0.0")
    check r.kind == verIntersect
    check newVersion("1.0.0-rc1") in r
    check newVersion("1.5.0") in r
    check newVersion("2.0.0") notin r

suite "git tag version ordering":
  test "isReleaseVersionTag keeps pre-release tags":
    check isReleaseVersionTag("v1.0.0-rc1")
    check isReleaseVersionTag("v23.2.0-rc1")

  test "pre-release git tags are ordered below their final release":
    # getVersionList returns versions in descending order.
    let vers = getVersionList(@["v1.0.0", "v1.0.0-rc1", "v1.0.0-rc2", "v0.9.0"])
    check toSeq(vers.keys) == @[
      newVersion("1.0.0"), newVersion("1.0.0-rc2"),
      newVersion("1.0.0-rc1"), newVersion("0.9.0")]

# Migrated from src/nimblepkg/version.nim's `when isMainModule` block, which was
suite "version":
  setup:
    let versionRange1 {.used.} = parseVersionRange(">= 1.0 & <= 1.5")
    let versionRange2 {.used.} = parseVersionRange("1.0")

  test "versions comparison":
    check newVersion("1.0") < newVersion("1.4")
    check newVersion("1.0.1") > newVersion("1.0")
    check newVersion("1.0.6") <= newVersion("1.0.6")
    check not (newVersion("0.1.0") < newVersion("0.1"))
    check not (newVersion("0.1.0") > newVersion("0.1"))
    check newVersion("0.1.0") < newVersion("0.1.0.0.1")
    check newVersion("0.1.0") <= newVersion("0.1")
    check newVersion("1") == newVersion("1")
    check newVersion("1.0.2.4.6.1.2.123") == newVersion("1.0.2.4.6.1.2.123")
    check newVersion("1.0.2") != newVersion("1.0.2.4.6.1.2.123")
    check newVersion("1.0.3") != newVersion("1.0.2")
    check newVersion("1") == newVersion("1.0")

  test "version comparison with empty version":
    check not (newVersion("") < newVersion("0.0.0"))
    check newVersion("") < newVersion("1.0.0")
    check newVersion("") < newVersion("0.1.0")

  test "comparison of Nimble special versions":
    check newVersion("#ab26sgdt362") != newVersion("#qwersaggdt362")
    check newVersion("#ab26saggdt362") == newVersion("#ab26saggdt362")
    check newVersion("#head") == newVersion("#HEAD")
    check newVersion("#head") == newVersion("#head")

  test "#head is bigger than any other version":
    check newVersion("#head") > newVersion("0.1.0")
    check not (newVersion("#head") > newVersion("#head"))
    check withinRange(newVersion("#head"), parseVersionRange(">= 0.5.0"))
    check newVersion("#a111") < newVersion("#head")

  test "all special versions except #head are smaller than normal versions":
    doAssert newVersion("#a111") < newVersion("1.1")

  test "parse version range":
    check parseVersionRange("== 3.4.2") == parseVersionRange("3.4.2")

  test "correct version range kinds":
    check versionRange1.kind == verIntersect
    check versionRange2.kind == verEq
    # An empty version range should give verAny
    doAssert parseVersionRange("").kind == verAny

  test "version is within range":
    let version1 = newVersion("0.1.0")
    let version2 = newVersion("1.5.1")
    let version3 = newVersion("1.0.2.3.4.5.6.7.8.9.10.11.12")
    let versionRange = parseVersionRange("> 0.1")
    check not withinRange(version1, versionRange)
    check not withinRange(version2, versionRange1)
    check withinRange(version3, versionRange1)

  test "in and notin operators":
    let versionRange = parseVersionRange("#ab26sgdt362")
    check newVersion("#ab26sgdt362") in versionRange
    check newVersion("#ab26saggdt362") notin versionRange
    check newVersion("#head") in parseVersionRange("#head")

  test "find latest version":
    let versions = toOrderedTable[Version, string]({
      newVersion("0.0.1"): "v0.0.1",
      newVersion("0.0.2"): "v0.0.2",
      newVersion("0.1.1"): "v0.1.1",
      newVersion("0.2.2"): "v0.2.2",
      newVersion("0.2.3"): "v0.2.3",
      newVersion("0.5"): "v0.5",
      newVersion("1.2"): "v1.2",
      newVersion("2.2.2"): "v2.2.2",
      newVersion("2.2.3"): "v2.2.3",
      newVersion("2.3.2"): "v2.3.2",
      newVersion("3.2"): "v3.2",
      newVersion("3.3.2"): "v3.3.2"
    })
    check findLatest(parseVersionRange(">= 0.1 & <= 0.4"), versions) ==
        (newVersion("0.2.3"), "v0.2.3")
    check findLatest(parseVersionRange("^= 0.1"), versions) ==
        (newVersion("0.1.1"), "v0.1.1")
    check findLatest(parseVersionRange("^= 0"), versions) ==
        (newVersion("0.5"), "v0.5")
    check findLatest(parseVersionRange("~= 2"), versions) ==
        (newVersion("2.3.2"), "v2.3.2")
    check findLatest(parseVersionRange("^= 0.0.1"), versions) ==
        (newVersion("0.0.1"), "v0.0.1")
    check findLatest(parseVersionRange("^= 2.2.2"), versions) ==
        (newVersion("2.3.2"), "v2.3.2")
    check findLatest(parseVersionRange("^= 2.1.1.1"), versions) ==
        (newVersion("2.3.2"), "v2.3.2")
    check findLatest(parseVersionRange("~= 2.2"), versions) ==
        (newVersion("2.3.2"), "v2.3.2")
    check findLatest(parseVersionRange("~= 0.2.2"), versions) ==
        (newVersion("0.2.3"), "v0.2.3")

  test "convert version to version range":
    check toVersionRange(newVersion("#head")).kind == verSpecial
    check toVersionRange(newVersion("0.2.0")).kind == verEq

