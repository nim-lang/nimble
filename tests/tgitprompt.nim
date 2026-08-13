{.used.}
# Tests for: git credential prompts are suppressed during version discovery.
#
# Version discovery probes many candidate URLs, including historical ones whose
# repos may be deleted or renamed. For those, git would otherwise block on an
# interactive `Username for 'https://github.com':` prompt. Discovery must never
# prompt: dead URLs should fail fast so the version gets excluded. Actual
# installs run outside discovery and keep interactive prompts for private
# repositories.

import unittest, os
import std/[tables, options]
import chronos
import nimblepkg/[version, options, packageinfotypes, versiondiscovery]

let nimBin = some("nim")

proc collect(root: PackageMinimalInfo, mock: GetPackageMinimal): TableRef[string, PackageVersions] =
  var options = initOptions()
  options.parallelDiscovery = false
  result = waitFor collectAllVersions(root, options, mock, nimBin = nimBin)

suite "git credential prompts are suppressed during discovery":
  test "discovery sets GIT_TERMINAL_PROMPT=0 only when the user didn't set it":
    # An explicit user-set value is respected: discovery must not override it,
    # and it must be restored afterwards so actual installs keep interactive
    # prompts for private repositories.
    var promptTotal = 0
    var promptSeenZero = 0      # discovery forced non-interactive
    var promptSeenUser = 0      # discovery kept the user's value
    proc mock(pv: PkgTuple, options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
      inc promptTotal
      case getEnv("GIT_TERMINAL_PROMPT")
      of "0": inc promptSeenZero
      of "1": inc promptSeenUser
      else: discard
      return @[PackageMinimalInfo(name: "dep", version: newVersion("1.0.0"))]

    let root = PackageMinimalInfo(
      name: "root", version: newVersion("1.0.0"), isRoot: true,
      requires: @[(name: "dep", ver: VersionRange(kind: verAny))])

    # User set GIT_TERMINAL_PROMPT=1: it is respected, not overridden.
    putEnv("GIT_TERMINAL_PROMPT", "1")
    discard collect(root, mock)
    check promptTotal > 0
    check promptSeenUser == promptTotal
    check promptSeenZero == 0
    check getEnv("GIT_TERMINAL_PROMPT") == "1"

    # When it wasn't set, discovery forces 0 and removes it afterwards.
    delEnv("GIT_TERMINAL_PROMPT")
    promptTotal = 0
    promptSeenZero = 0
    promptSeenUser = 0
    discard collect(root, mock)
    check promptSeenZero == promptTotal
    check promptSeenUser == 0
    check not existsEnv("GIT_TERMINAL_PROMPT")
