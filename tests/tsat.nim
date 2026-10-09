{.used.}
import unittest, os, osproc
import testscommon
# from nimblepkg/common import cd, NimbleError Used in the commented tests
import std/[tables, json, jsonutils, strutils, sequtils, options, algorithm]
import chronos
import nimblepkg/[version, nimblesat, nimblesolver, options, packageinfotypes, urls, download]
from nimblepkg/common import cd, NimbleError

proc fromJsonHook(pv: var PkgTuple, jsonNode: JsonNode, opt = Joptions()) =
  if jsonNode.kind == Jstring:
    pv = parseRequires(jsonNode.getStr())
  else:
    raise newException(ValueError, "Expected a string for PkgTuple found: " & $jsonNode.kind & " val: " & $jsonNode)

# proc fromJsonHook(pm: var PackageMinimalInfo, jsonNode: JsonNode, opt = Joptions()) =
#   pm.name = jsonNode["name"].getStr().toLower
#   pm.version = newVersion(jsonNode["version"].getStr())
#   for req in jsonNode["requires"]:
#     var pv: PkgTuple
#     fromJson(pv, req)
#     pm.requires.add((name: pv.name, ver: pv.ver))
#   pm.isRoot = jsonNode["isRoot"].getBool()


suite "SAT solver":
  test "a search that exceeds its iteration budget is not reported unsatisfiable":
    # Regression test for the Aug 2026 CI breakage: this recorded real-world
    # nimlangserver table IS satisfiable (verified independently), but the
    # DPLL search overflows its iteration budget under the natural node
    # order. The overflow must not be conflated with "unsatisfiable";
    # solve retries under rotated node orders, which decide this instance in
    # milliseconds.
    var pkgVersionTable = parseJson(readFile("packageMinimal" / "nimlangserver.json")).jsonTo(Table[string, PackageVersions], Joptions(allowMissingKeys: true))
    pkgVersionTable.normalizeRequirements(initOptions())
    var graph = pkgVersionTable.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    var output = ""
    check solve(graph, form, packages, output, initOptions())
    check packages.len > 0

  test "findMinimalFailingSet separates implicated deps from unaffected ones":
    # The conflict is alpha (needs common >= 2.0) vs pin (needs common < 2.0):
    # removing either of them resolves it, removing filler does not. The
    # fallback retry pins implicated packages, so the split matters: pinning
    # a package whose removal changes nothing (like filler, or nim in the
    # libp2p/quic case) can never fix the solve.
    var t = {
      "root": PackageVersions(pkgName: "root", versions: @[
        PackageMinimalInfo(name: "root", version: newVersion "0.1.0", requires: @[
          (name: "filler", ver: VersionRange(kind: verAny)),
          (name: "alpha", ver: VersionRange(kind: verAny)),
          (name: "pin", ver: parseVersionRange "#abc")], isRoot: true)]),
      "filler": PackageVersions(pkgName: "filler", versions: @[
        PackageMinimalInfo(name: "filler", version: newVersion "1.0")]),
      "alpha": PackageVersions(pkgName: "alpha", versions: @[
        PackageMinimalInfo(name: "alpha", version: newVersion "2.0", requires: @[
          (name: "common", ver: parseVersionRange ">= 2.0")])]),
      "pin": PackageVersions(pkgName: "pin", versions: @[
        PackageMinimalInfo(name: "pin", version: newVersion "#abc", requires: @[
          (name: "common", ver: parseVersionRange "< 2.0")])]),
      "common": PackageVersions(pkgName: "common", versions: @[
        PackageMinimalInfo(name: "common", version: newVersion "1.0"),
        PackageMinimalInfo(name: "common", version: newVersion "2.0")]),
    }.toTable()

    var graph = t.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    var output = ""
    check not solve(graph, form, packages, output, initOptions())

    var g2 = t.toDepGraph()
    let (failingSet, implicated, _) = findMinimalFailingSet(g2)
    check implicated.mapIt(it.name).sorted() == @["alpha", "pin"]
    check failingSet.mapIt(it.name) == @["filler"]

  test "lenient resolves conflicting special versions with warning":
    proc initConflictingSpecialVersionsTable(): Table[string, PackageVersions] =
      {
        "root": PackageVersions(pkgName: "root", versions: @[
          PackageMinimalInfo(name: "root", version: newVersion "1.0", requires: @[
            (name: "a", ver: parseVersionRange ">= 1.0"),
            (name: "b", ver: parseVersionRange ">= 1.0"),
          ], isRoot: true),
        ]),
        "a": PackageVersions(pkgName: "a", versions: @[
          PackageMinimalInfo(name: "a", version: newVersion "1.0", requires: @[
            (name: "dep", ver: parseVersionRange "#commit_a"),
          ]),
        ]),
        "b": PackageVersions(pkgName: "b", versions: @[
          PackageMinimalInfo(name: "b", version: newVersion "1.0", requires: @[
            (name: "dep", ver: parseVersionRange "#commit_b"),
          ]),
        ]),
        "dep": PackageVersions(pkgName: "dep", versions: @[
          PackageMinimalInfo(name: "dep", version: newVersion "#commit_a"),
          PackageMinimalInfo(name: "dep", version: newVersion "#commit_b"),
        ]),
      }.toTable()

    var options = initOptions()

    # lenient=true: should succeed, picking #commit_a
    options.lenient = true
    var pkgVersionTable = initConflictingSpecialVersionsTable()
    pkgVersionTable.normalizeSpecialVersions(options)
    check pkgVersionTable["dep"].versions.len == 1
    check pkgVersionTable["dep"].versions[0].version == newVersion "#commit_a"
    check pkgVersionTable["b"].versions[0].requires[0].ver.kind == verSpecial
    check $pkgVersionTable["b"].versions[0].requires[0].ver.spe == "#commit_a"

    # lenient=false: should raise
    options.lenient = false
    var pkgVersionTable2 = initConflictingSpecialVersionsTable()
    expect NimbleError:
      pkgVersionTable2.normalizeSpecialVersions(options)

  test "identical special versions are not a false conflict (#1785)":
    # A single special version of 'dep' (e.g. chronos#ebc2d239) is reached via
    # two requirement paths and lands in the table as two entries carrying the
    # SAME special version. This must NOT be treated as a conflict: there is
    # nothing to disambiguate. Counting occurrences instead of distinct values
    # makes normalizeSpecialVersions report "using #commit_a, ignoring #commit_a"
    # (lenient) or raise (non-lenient) over a version conflicting with itself.
    proc initSameSpecialVersionTable(): Table[string, PackageVersions] =
      {
        "root": PackageVersions(pkgName: "root", versions: @[
          PackageMinimalInfo(name: "root", version: newVersion "1.0", requires: @[
            (name: "a", ver: parseVersionRange ">= 1.0"),
            (name: "b", ver: parseVersionRange ">= 1.0"),
          ], isRoot: true),
        ]),
        "a": PackageVersions(pkgName: "a", versions: @[
          PackageMinimalInfo(name: "a", version: newVersion "1.0", requires: @[
            (name: "dep", ver: parseVersionRange "#commit_a"),
          ]),
        ]),
        "b": PackageVersions(pkgName: "b", versions: @[
          PackageMinimalInfo(name: "b", version: newVersion "1.0", requires: @[
            (name: "dep", ver: parseVersionRange "#commit_a"),
          ]),
        ]),
        "dep": PackageVersions(pkgName: "dep", versions: @[
          PackageMinimalInfo(name: "dep", version: newVersion "#commit_a"),
          PackageMinimalInfo(name: "dep", version: newVersion "#commit_a"),
        ]),
      }.toTable()

    # lenient=true: succeeds, the single special version survives untouched
    var options = initOptions()
    options.lenient = true
    var pkgVersionTable = initSameSpecialVersionTable()
    pkgVersionTable.normalizeSpecialVersions(options)
    check pkgVersionTable["dep"].versions.allIt(it.version == newVersion "#commit_a")
    check $pkgVersionTable["a"].versions[0].requires[0].ver.spe == "#commit_a"
    check $pkgVersionTable["b"].versions[0].requires[0].ver.spe == "#commit_a"

    # lenient=false: must NOT raise — a version does not conflict with itself
    options.lenient = false
    var pkgVersionTable2 = initSameSpecialVersionTable()
    pkgVersionTable2.normalizeSpecialVersions(options)
    check pkgVersionTable2["dep"].versions.allIt(it.version == newVersion "#commit_a")

  test "root's pinned special version wins a genuine conflict (#1785)":
    # Reproduces the libp2p failure: the root explicitly pins boringssl to a
    # commit (#commit_root, whose real version is 0.0.8) while a transitive dep
    # pulls a different special version (#commit_dep, version 0.0.4). Another dep
    # requires `dep >= 0.0.8`. "First-#-wins" is traversal-order dependent: if it
    # discards the root's pin and keeps #commit_dep (0.0.4), the `>= 0.0.8`
    # constraint can no longer be met and resolution fails — nondeterministically
    # across platforms. The root's authoritative pin must win.
    proc initRootPinnedConflictTable(): Table[string, PackageVersions] =
      {
        "root": PackageVersions(pkgName: "root", versions: @[
          PackageMinimalInfo(name: "root", version: newVersion "1.0", requires: @[
            (name: "dep", ver: parseVersionRange "#commit_root"),
            (name: "a", ver: parseVersionRange ">= 1.0"),
          ], isRoot: true),
        ]),
        "a": PackageVersions(pkgName: "a", versions: @[
          PackageMinimalInfo(name: "a", version: newVersion "1.0", requires: @[
            (name: "dep", ver: parseVersionRange "#commit_dep"),
          ]),
        ]),
        # Order matters: #commit_dep is first, so plain first-#-wins would keep
        # the transitive version and drop the root's pin.
        "dep": PackageVersions(pkgName: "dep", versions: @[
          PackageMinimalInfo(name: "dep", version: newVersion "#commit_dep"),
          PackageMinimalInfo(name: "dep", version: newVersion "#commit_root"),
        ]),
      }.toTable()

    var options = initOptions()
    options.lenient = true
    var pkgVersionTable = initRootPinnedConflictTable()
    pkgVersionTable.normalizeSpecialVersions(options)
    # The surviving special version must be the one the ROOT pinned.
    check pkgVersionTable["dep"].versions.len == 1
    check pkgVersionTable["dep"].versions[0].version == newVersion "#commit_root"
    # ...and the transitive requirement is rewritten to the root's pin.
    check $pkgVersionTable["a"].versions[0].requires[0].ver.spe == "#commit_root"

  #Desactivate tests as it goes against local deps mode by default. Need to be redone
  # test "should not use the global tagged cache when in local but a local one":
  #   cd "localdeps":
  #     var options = initOptions()
  #     options.localDeps = true
  #     options.maxTaggedVersions = 0 #all
  #     options.nimBin = some options.makeNimBin("nim")    
  #     options.config.packageLists["official"] = PackageList(name: "Official", urls: @[
  #     "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
  #     "https://nim-lang.org/nimble/packages.json"
  #     ])
  #     options.setNimbleDir()
  #     for dir in walkDir(".", true):
  #       if dir.kind == PathComponent.pcDir and dir.path.startsWith("githubcom_vegansknimfp"):
  #         echo "Removing dir", dir.path
  #         removeDir(dir.path)
      
  #     let pvPrev = parseRequires("nimfp >= 0.3.4")
  #     let downloadResPrev = pvPrev.downloadPkgFromUrl(options)[0]
  #     let repoDirPrev = downloadResPrev.dir
  #     discard getPackageMinimalVersionsFromRepo(repoDirPrev, pvPrev, downloadResPrev.version,  DownloadMethod.git, options)
  #     check not fileExists(repoDirPrev / TaggedVersionsFileName)

  #     check fileExists("nimbledeps" / "pkgcache" / "tagged" / "nimfp.json")

  #disabled for being too slow. TODO replace with one from the cached pkgtable similar to nwaku
  # test "should be able to solve complex dep graphs":
  #   cd "sattests" / "mgtest":
  #     removeDir("nimbledeps")
  #     let (_, exitCode) = execNimbleYes("install", "-l")
  #     check exitCode == QuitSuccess

  test "normalizeRequirements resolves URL via canonical url field":
    # Name-based discovery now sets the canonical url field on versions
    # (from packages.json). This lets normalizeRequirements match URL-based
    # requirements even when the URL differs from the discovery URL.
    var pkgVersionTable = {
      "root": PackageVersions(pkgName: "root", versions: @[
        PackageMinimalInfo(name: "root", version: newVersion "1.0", requires: @[
          (name: "https://github.com/status-im/nim-chronos", ver: parseVersionRange(">= 4.0")),
        ], isRoot: true),
      ]),
      "chronos": PackageVersions(pkgName: "chronos", versions: @[
        # Discovered by name — url field set to canonical URL from packages.json
        PackageMinimalInfo(name: "chronos", version: newVersion "4.2.0",
          url: "https://github.com/status-im/nim-chronos.git"),
      ]),
    }.toTable()

    var options = initOptions()
    pkgVersionTable.normalizeRequirements(options)

    # URL requirement should be normalized to "chronos" (the .nimble name)
    let rootReqs = pkgVersionTable["root"].versions[0].requires
    check rootReqs[0].name == "chronos"
    check(not rootReqs[0].name.isUrl)

  test "issue #1692: findLatest correctly maps verEq to tag":
    ## The lock file picks chronos 4.0.5. During download, findLatest must
    ## map verEq("4.0.5") to git tag "v4.0.5" — not to a different tag.
    let versions = @["v4.0.4", "v4.0.5", "v4.2.0", "v4.2.2"].getVersionList()
    let latest = findLatest(parseVersionRange("4.0.5"), versions)
    check latest.ver == newVersion("4.0.5")
    check latest.tag == "v4.0.5"

  test "issue #1692: stale download cache must be invalidated":
    ## Scenario: lock file says chronos 4.0.5, solver picks it. But the
    ## download cache directory already contains content from version 4.2.2
    ## (left behind by version discovery fallback on checkout failure).
    ##
    ## downloadPkgs (install.nim:396) must detect this version mismatch
    ## and invalidate the cache, not silently reuse the wrong content.
    let tempDir = getTempDir() / "nimble_test_1692"
    try:
      removeDir(tempDir)
      createDir(tempDir)

      # Simulate stale cache: directory is keyed for 4.0.5 but content is 4.2.2
      writeFile(tempDir / "chronos.nimble", """
# Package
version       = "4.2.2"
author        = "Status Research"
description   = "Chronos"
license       = "MIT"

requires "nim >= 1.6.0"
""")

      var options = initOptions()
      let verRange = parseVersionRange("4.0.5")  # verEq 4.0.5

      # The cache has a .nimble but it's the wrong version.
      # pkgDirHasNimble alone is not enough — must also validate version.
      check pkgDirHasNimble(tempDir, options) == true
      check isCacheVersionValid(tempDir, verRange, options) == false

    finally:
      removeDir(tempDir)

  test "issue #1692: version discovery fallback must skip on checkout failure":
    ## During version discovery, the fallback path (when declarative parsing
    ## fails) checks out each tag in a tempDir. If checkout of a tag fails,
    ## tempDir retains content from a previous tag. The code must NOT use
    ## this stale content — it must skip the failed tag entirely.
    ##
    ## doCheckout returns false on failure. The fallback path must check this
    ## and `continue` instead of reading stale content and poisoning the cache.
    ##
    ## This test simulates the fallback path: creates a repo with v2.0.0 tag,
    ## checks it out (succeeds, nimble says 2.0.0), then tries a nonexistent tag
    ## (fails). After the failed checkout the nimble file still says 2.0.0
    ## (stale). isCacheVersionValid must reject this for verEq 1.0.0.
    let tempDir = getTempDir() / "nimble_test_1692_checkout"
    try:
      removeDir(tempDir)
      createDir(tempDir)

      # Create a git repo simulating the version discovery tempDir
      discard execCmdEx("git -C " & tempDir & " init")
      discard execCmdEx("git -C " & tempDir & " config user.email test@test.com")
      discard execCmdEx("git -C " & tempDir & " config user.name test")
      writeFile(tempDir / "chronos.nimble",
        "version = \"2.0.0\"\nrequires \"nim >= 1.6.0\"\n")
      discard execCmdEx("git -C " & tempDir & " add .")
      discard execCmdEx("git -C " & tempDir & " commit -m 'v2.0.0'")
      discard execCmdEx("git -C " & tempDir & " tag v2.0.0")

      var options = initOptions()

      # Checkout v2.0.0 succeeds — tempDir has correct content
      check doCheckout(DownloadMethod.git, tempDir, "v2.0.0", options) == true

      # Checkout of nonexistent tag fails — tempDir still has v2.0.0 content
      check doCheckout(DownloadMethod.git, tempDir, "v1.0.0", options) == false

      # After failed checkout, the cache has STALE content (v2.0.0)
      # isCacheVersionValid must reject it for a different version
      check isCacheVersionValid(tempDir, parseVersionRange("1.0.0"), options) == false

    finally:
      removeDir(tempDir)

  test "PkgTuple JSON round-trip produces valid version strings":
    # Regression test: toJsonHook must be defined after `$ VersionRange`
    # to avoid corrupted cache writes (e.g. "(kind: verEqLater, ...)" instead of ">= 1.0")
    let cases = @[
      parseRequires("nim >= 2.0.0"),
      parseRequires("stew"),
      parseRequires("chronicles#head"),
      parseRequires("results >= 0.3 & < 1.0"),
    ]
    for original in cases:
      let jsonNode = original.toJsonHook()
      let serialized = jsonNode.getStr()
      # Must not contain struct-like output from generic $
      check "(kind:" notin serialized
      check "verEq" notin serialized
      # Round-trip: deserialize back and compare
      var roundTripped: PkgTuple
      var path = ""
      initFromJson(roundTripped, jsonNode, path)
      check roundTripped.name == original.name
      check roundTripped.ver.kind == original.ver.kind
