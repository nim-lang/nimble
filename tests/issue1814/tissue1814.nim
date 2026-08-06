{.used.}
# Tests for #1814: version discovery must not resurrect stale dependencies
# from old git tags (which caused nimble to prompt for GitHub credentials for
# packages that are no longer required). All tests are offline (mock-based).

import unittest, os
import std/[tables, sequtils, options]
import chronos
import nimblepkg/[version, options, packageinfotypes, versiondiscovery]
from nimblepkg/common import NimbleError

let nimBin = some("nim")

proc collect(root: PackageMinimalInfo, mock: GetPackageMinimal): TableRef[string, PackageVersions] =
  ## Runs version discovery with `mock` as the package source.
  var options = initOptions()
  options.parallelDiscovery = false
  result = waitFor collectAllVersions(root, options, mock, nimBin = nimBin)

suite "issue1814: version discovery must not resurrect stale deps from old git tags":
  test "intersectVersionRanges keeps the max lower bound (satisfied)":
    # Two branches require `ozark >= 0.1.4` and `>= 0.1.5`; the effective
    # requirement is the intersection `>= 0.1.5`.
    let r = intersectVersionRanges(
      parseVersionRange(">= 0.1.4"), parseVersionRange(">= 0.1.5"))
    check r.isSome
    check newVersion("0.1.5").withinRange(r.get)
    check not newVersion("0.1.4").withinRange(r.get)

  test "intersectVersionRanges handles any, exact and bounded ranges (satisfied)":
    # any ∩ >= 0.1.4 => >= 0.1.4
    let anyR = intersectVersionRanges(VersionRange(kind: verAny), parseVersionRange(">= 0.1.4"))
    check anyR.isSome and newVersion("0.1.4").withinRange(anyR.get)
    # == 1.0.0 ∩ >= 0.1.5 => == 1.0.0
    let eqR = intersectVersionRanges(parseVersionRange("== 1.0.0"), parseVersionRange(">= 0.1.5"))
    check eqR.isSome
    check newVersion("1.0.0").withinRange(eqR.get)
    check not newVersion("1.0.1").withinRange(eqR.get)
    # >= 0.1.5 ∩ < 0.2.0 keeps both bounds
    let boundedR = intersectVersionRanges(parseVersionRange(">= 0.1.5"), parseVersionRange("< 0.2.0"))
    check boundedR.isSome
    check newVersion("0.1.6").withinRange(boundedR.get)
    check not newVersion("0.2.0").withinRange(boundedR.get)
    check not newVersion("0.1.4").withinRange(boundedR.get)

  test "intersectVersionRanges reports empty/unsupported intersections (unsatisfied)":
    # == 1.0.0 ∩ >= 2.0.0 has no common version.
    check intersectVersionRanges(parseVersionRange("== 1.0.0"), parseVersionRange(">= 2.0.0")).isNone
    # <= 0.1.4 ∩ >= 0.1.5 is an empty range.
    check intersectVersionRanges(parseVersionRange("<= 0.1.4"), parseVersionRange(">= 0.1.5")).isNone
    # Special versions can't be intersected with plain ranges; both are kept.
    check intersectVersionRanges(parseVersionRange(">= 0.1.4"), parseVersionRange("#head")).isNone

  test "conflicting range requirements merge to the intersection, so lower versions are never discovered":
    # `parent` 1.0.0 requires `dep >= 0.1.4` while 1.0.1 requires `>= 0.1.5`.
    # The effective requirement is `>= 0.1.5`, so dep 0.1.4 — and any dead deps
    # it carried — must never be discovered/processed.
    var depCalls = 0
    proc mock(pv: PkgTuple, options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
      case pv.name
      of "parent":
        return @[
          PackageMinimalInfo(name: "parent", version: newVersion("1.0.0"), requires: @[
            (name: "dep", ver: parseVersionRange(">= 0.1.4"))]),
          PackageMinimalInfo(name: "parent", version: newVersion("1.0.1"), requires: @[
            (name: "dep", ver: parseVersionRange(">= 0.1.5"))])
        ]
      of "dep":
        inc depCalls
        return @[
          PackageMinimalInfo(name: "dep", version: newVersion("0.1.4")),
          PackageMinimalInfo(name: "dep", version: newVersion("0.1.5"))
        ]
      else:
        return @[]

    let root = PackageMinimalInfo(
      name: "root", version: newVersion("1.0.0"), isRoot: true,
      requires: @[(name: "parent", ver: parseVersionRange(">= 1.0.0"))])
    let table = collect(root, mock)

    # dep is requested exactly once (the two requirements merged into one), and
    # the mock offers 0.1.4 + 0.1.5 — so the table containing only 0.1.5 proves
    # discovery ran with the intersection `>= 0.1.5`, never with `>= 0.1.4`.
    check depCalls == 1
    check table["dep"].versions.mapIt($it.version) == @["0.1.5"]

  test "a candidate version whose dependency fails to resolve is excluded (satisfied)":
    # dep 0.1.4 requires a dead URL; dep 0.1.5 is clean. The broken version must
    # be excluded via failedReqs and the clean one selected.
    var deadCalls = 0
    proc mock(pv: PkgTuple, options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
      case pv.name
      of "dep":
        return @[
          PackageMinimalInfo(name: "dep", version: newVersion("0.1.4"), requires: @[
            (name: "https://github.com/example/dead-url", ver: VersionRange(kind: verAny))]),
          PackageMinimalInfo(name: "dep", version: newVersion("0.1.5"))
        ]
      of "https://github.com/example/dead-url":
        inc deadCalls
        raise newException(NimbleError, "Unable to identify url: https://github.com/example/dead-url")
      else:
        return @[]

    let root = PackageMinimalInfo(
      name: "root", version: newVersion("1.0.0"), isRoot: true,
      requires: @[(name: "dep", ver: parseVersionRange(">= 0.1.4"))])
    let table = collect(root, mock)

    check deadCalls >= 1
    check table["dep"].versions.mapIt($it.version) == @["0.1.5"]

  test "when every candidate version is unresolvable, none is available (unsatisfied)":
    # Both dep versions require the dead URL, so no viable version exists.
    proc mock(pv: PkgTuple, options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
      case pv.name
      of "dep":
        return @[
          PackageMinimalInfo(name: "dep", version: newVersion("0.1.4"), requires: @[
            (name: "https://github.com/example/dead-url", ver: VersionRange(kind: verAny))]),
          PackageMinimalInfo(name: "dep", version: newVersion("0.1.5"), requires: @[
            (name: "https://github.com/example/dead-url", ver: VersionRange(kind: verAny))])
        ]
      of "https://github.com/example/dead-url":
        raise newException(NimbleError, "Unable to identify url: https://github.com/example/dead-url")
      else:
        return @[]

    let root = PackageMinimalInfo(
      name: "root", version: newVersion("1.0.0"), isRoot: true,
      requires: @[(name: "dep", ver: parseVersionRange(">= 0.1.4"))])
    let table = collect(root, mock)

    check "dep" notin table

  test "discovery forces GIT_TERMINAL_PROMPT=0 and restores it afterwards":
    # Dead URLs must fail fast during discovery instead of prompting; the value
    # must be forced even when the user set GIT_TERMINAL_PROMPT, and restored
    # afterwards so actual installs keep interactive prompts.
    var promptTotal = 0
    var promptSeenZero = 0
    proc mock(pv: PkgTuple, options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
      inc promptTotal
      if getEnv("GIT_TERMINAL_PROMPT") == "0":
        inc promptSeenZero
      return @[PackageMinimalInfo(name: "dep", version: newVersion("1.0.0"))]

    let root = PackageMinimalInfo(
      name: "root", version: newVersion("1.0.0"), isRoot: true,
      requires: @[(name: "dep", ver: VersionRange(kind: verAny))])

    putEnv("GIT_TERMINAL_PROMPT", "1")
    discard collect(root, mock)
    check promptTotal > 0
    check promptSeenZero == promptTotal
    check getEnv("GIT_TERMINAL_PROMPT") == "1"

    # When it wasn't set before, it's removed again afterwards.
    delEnv("GIT_TERMINAL_PROMPT")
    promptTotal = 0
    promptSeenZero = 0
    discard collect(root, mock)
    check promptSeenZero == promptTotal
    check not existsEnv("GIT_TERMINAL_PROMPT")
