discard """
  exitcode: 0
"""

import unittest, os, osproc
import std/[tables, json, jsonutils, strutils, sequtils, times, options]
import nimblepkg/[version, nimblesat, options, packageinfotypes, urls, download]
from nimblepkg/common import NimbleError

let testsDir = currentSourcePath().parentDir.parentDir

proc fromJsonHook(pv: var PkgTuple, jsonNode: JsonNode, opt = Joptions()) =
  if jsonNode.kind == Jstring:
    pv = parseRequires(jsonNode.getStr())
  else:
    raise newException(ValueError, "Expected a string for PkgTuple found: " & $jsonNode.kind & " val: " & $jsonNode)


suite "SAT solver":
  test "can solve simple SAT":
    let pkgVersionTable = {
      "a": PackageVersions(pkgName: "a", versions: @[
        PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
          (name:"b", ver: parseVersionRange ">= 0.1.0")
        ], isRoot:true),
      ]),
      "b": PackageVersions(pkgName: "b", versions: @[
        PackageMinimalInfo(name: "b", version: newVersion "0.1.0")
      ])
    }.toTable()
    var graph = pkgVersionTable.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    var output = ""
    check solve(graph, form, packages, output, initOptions())
    check packages.len == 2
    check packages["a"] == newVersion "3.0"
    check packages["b"] == newVersion "0.1.0"

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

  test "solves 'Conflicting dependency resolution' #1162":
    let pkgVersionTable = {
      "a": PackageVersions(pkgName: "a", versions: @[
        PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
          (name:"b", ver: parseVersionRange ">= 0.1.4"),
          (name:"c", ver: parseVersionRange ">= 0.0.5 & <= 0.1.0")
        ], isRoot:true),
      ]),
      "b": PackageVersions(pkgName: "b", versions: @[
        PackageMinimalInfo(name: "b", version: newVersion "0.1.4", requires: @[
          (name:"c", ver: VersionRange(kind: verAny))
        ]),
      ]),
      "c": PackageVersions(pkgName: "c", versions: @[
        PackageMinimalInfo(name: "c", version: newVersion "0.1.0"),
        PackageMinimalInfo(name: "c", version: newVersion "0.2.1")
      ])
    }.toTable()
    var graph = pkgVersionTable.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    var output = ""
    check solve(graph, form, packages, output, initOptions())
    check packages.len == 3
    check packages["a"] == newVersion "3.0"
    check packages["b"] == newVersion "0.1.4"
    check packages["c"] == newVersion "0.1.0"

  test "dont solve unsatisfable":
    let pkgVersionTable = {
      "a": PackageVersions(pkgName: "a", versions: @[
        PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
          (name:"b", ver: parseVersionRange ">= 0.5.0")
        ], isRoot:true),
      ]),
      "b": PackageVersions(pkgName: "b", versions: @[
        PackageMinimalInfo(name: "b", version: newVersion "0.1.0")
      ])
    }.toTable()
    var graph = pkgVersionTable.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    var output = ""
    check not solve(graph, form, packages, output, initOptions())
    echo output
    check packages.len == 0

  test "should be able to solve all nimble packages":
    let start = now()
    var pks = 0
    for jsonFile in walkPattern(testsDir / "packageMinimal" / "*.json"):
      inc pks
      var pkgVersionTable = parseJson(readFile(jsonFile)).jsonTo(Table[string, PackageVersions], Joptions(allowMissingKeys: true))
      pkgVersionTable.normalizeRequirements(initOptions())
      var graph = pkgVersionTable.toDepGraph()
      let form = toFormular(graph)
      var packages = initTable[string, Version]()
      var output = ""
      check solve(graph, form, packages, output, initOptions())
      check packages.len > 0

    let ends = now()
    echo "Solved ", pks, " packages in ", ends - start, " seconds"

  test "#head requirements require #head available":
    let pkgVersionTable = {
      "a": PackageVersions(pkgName: "a", versions: @[
        PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
          (name:"b", ver: parseVersionRange "#head")
        ], isRoot:true),
      ]),
      "b": PackageVersions(pkgName: "b", versions: @[
        PackageMinimalInfo(name: "b", version: newVersion "0.1.0")
      ])
    }.toTable()
    var graph = pkgVersionTable.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    var output = ""
    check not solve(graph, form, packages, output, initOptions())

  test "#head requirements are satisfied when #head is available":
    let pkgVersionTable = {
      "a": PackageVersions(pkgName: "a", versions: @[
        PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
          (name:"b", ver: parseVersionRange "#head")
        ], isRoot:true),
      ]),
      "b": PackageVersions(pkgName: "b", versions: @[
        PackageMinimalInfo(name: "b", version: newVersion "0.1.0"),
        PackageMinimalInfo(name: "b", version: newVersion "#head")
      ])
    }.toTable()
    var graph = pkgVersionTable.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    var output = ""
    check solve(graph, form, packages, output, initOptions())
    check packages.len == 2
    check packages["b"] == newVersion("#head")

  test "should not match other tags":
    let pkgVersionTable = {
      "a": PackageVersions(pkgName: "a", versions: @[
        PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
          (name:"b", ver: parseVersionRange "#head")
        ], isRoot:true),
      ]),
      "b": PackageVersions(pkgName: "b", versions: @[
        PackageMinimalInfo(name: "b", version: newVersion "#someOtherTag")
      ])
    }.toTable()
    var graph = pkgVersionTable.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    var output = ""
    check not solve(graph, form, packages, output, initOptions())

  test "should prioritize exact version matches":
    let pkgVersionTable = {
      "a": PackageVersions(pkgName: "a", versions: @[
        PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
          (name:"b", ver: parseVersionRange "== 1.0.0"),
          (name:"b", ver: parseVersionRange ">= 0.5.0")
        ], isRoot:true),
      ]),
      "b": PackageVersions(pkgName: "b", versions: @[
        PackageMinimalInfo(name: "b", version: newVersion "1.0.0"),
        PackageMinimalInfo(name: "b", version: newVersion "2.0.0")
      ])
    }.toTable()
    var graph = pkgVersionTable.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    var output = ""
    check solve(graph, form, packages, output, initOptions())
    check packages.len == 2
    check packages["a"] == newVersion "3.0"
    check packages["b"] == newVersion "1.0.0"

  test "if a dependency is unsatisfable, it should fallback to the previous version of the depency when available":
    let pkgVersionTable = {
      "a": PackageVersions(pkgName: "a", versions: @[
        PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
          (name:"b", ver: parseVersionRange ">= 0.5.0")
        ], isRoot: true),
      ]),
      "b": PackageVersions(pkgName: "b", versions: @[
        PackageMinimalInfo(name: "b", version: newVersion "0.6.0", requires: @[
          (name:"c", ver: parseVersionRange ">= 0.0.5")
        ]),
        PackageMinimalInfo(name: "b", version: newVersion "0.5.0", requires: @[

        ]),
      ]),
      "c": PackageVersions(pkgName: "c", versions: @[
        PackageMinimalInfo(name: "c", version: newVersion "0.0.4"),
      ])
    }.toTable()

    var graph = pkgVersionTable.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    var output = ""
    check solve(graph, form, packages, output, initOptions())

  test "should be able to solve packages with cycles in the requirements":
    let pkgVersionTable = {
      "root": PackageVersions(pkgName: "root", versions: @[
        PackageMinimalInfo(name: "root", version: newVersion "1.0", requires: @[
          (name: "a", ver: parseVersionRange(">= 1.0")),
        ], isRoot: true),
      ]),
      "a": PackageVersions(pkgName: "a", versions: @[
        PackageMinimalInfo(name: "a", version: newVersion "1.0", requires: @[
          (name: "b", ver: parseVersionRange(">= 1.0")),
        ]),
      ]),
      "b": PackageVersions(pkgName: "b", versions: @[
        PackageMinimalInfo(name: "b", version: newVersion "1.0", requires: @[
          (name: "a", ver: parseVersionRange(">= 1.0")),
        ]),
      ]),
    }.toTable()
    var graph = pkgVersionTable.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    var output = ""
    check solve(graph, form, packages, output, initOptions())
    check packages["a"] == newVersion "1.0"
    check packages["b"] == newVersion "1.0"

  test "should prefer newer versions (waku@0.36.0 over 0.1.0)":
    var pkgVersionTable = parseJson(readFile(testsDir / "packageMinimal" / "waku.json")).jsonTo(Table[string, PackageVersions], Joptions(allowMissingKeys: true))
    pkgVersionTable.normalizeRequirements(initOptions())
    var graph = pkgVersionTable.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    var output = ""
    let solved = solve(graph, form, packages, output, initOptions())
    echo "Solved: ", solved, " packages: ", packages.len
    for pkgName, version in packages.pairs():
      echo pkgName & "@" & $version
    if packages.hasKey("waku"):
      echo "waku version selected: ", packages["waku"]
    check solved
    check packages.len > 0
    check packages.hasKey("waku")
    echo "waku selected: ", packages["waku"]
    check packages["waku"] == newVersion("0.36.0")

  test "normalizeRequirements resolves URL to nimble package name":
    var pkgVersionTable = {
      "root": PackageVersions(pkgName: "root", versions: @[
        PackageMinimalInfo(name: "root", version: newVersion "1.0", requires: @[
          (name: "https://github.com/vacp2p/nim-jwt.git", ver: VersionRange(kind: verSpecial, spe: newVersion "#abc123")),
          (name: "https://github.com/vacp2p/nim-jwt", ver: VersionRange(kind: verSpecial, spe: newVersion "#abc123")),
          (name: "bearssl", ver: parseVersionRange(">= 0.2.7")),
        ], isRoot: true),
      ]),
      "jwt": PackageVersions(pkgName: "jwt", versions: @[
        PackageMinimalInfo(name: "jwt", version: newVersion "#abc123",
          url: "https://github.com/vacp2p/nim-jwt.git",
          requires: @[
            (name: "bearssl", ver: parseVersionRange(">= 0.2.7")),
          ]),
      ]),
      "bearssl": PackageVersions(pkgName: "bearssl", versions: @[
        PackageMinimalInfo(name: "bearssl", version: newVersion "0.2.8"),
      ]),
    }.toTable()
    pkgVersionTable["jwt"].versions[0].version.speSemanticVersion = some("0.1.0")

    var options = initOptions()
    pkgVersionTable.normalizeRequirements(options)

    let rootReqs = pkgVersionTable["root"].versions[0].requires
    for req in rootReqs:
      check(not req.name.isUrl)
    let jwtReqs = rootReqs.filterIt(it.name == "jwt")
    check jwtReqs.len == 2

    var graph = pkgVersionTable.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    var output = ""
    check solve(graph, form, packages, output, options)
    check packages.hasKey("jwt")
    check packages.hasKey("bearssl")

  test "normalizeRequirements resolves URL via canonical url field":
    var pkgVersionTable = {
      "root": PackageVersions(pkgName: "root", versions: @[
        PackageMinimalInfo(name: "root", version: newVersion "1.0", requires: @[
          (name: "https://github.com/status-im/nim-chronos", ver: parseVersionRange(">= 4.0")),
        ], isRoot: true),
      ]),
      "chronos": PackageVersions(pkgName: "chronos", versions: @[
        PackageMinimalInfo(name: "chronos", version: newVersion "4.2.0",
          url: "https://github.com/status-im/nim-chronos.git"),
      ]),
    }.toTable()

    var options = initOptions()
    pkgVersionTable.normalizeRequirements(options)

    let rootReqs = pkgVersionTable["root"].versions[0].requires
    check rootReqs[0].name == "chronos"
    check(not rootReqs[0].name.isUrl)

  test "issue #1692: findLatest correctly maps verEq to tag":
    let versions = @["v4.0.4", "v4.0.5", "v4.2.0", "v4.2.2"].getVersionList()
    let latest = findLatest(parseVersionRange("4.0.5"), versions)
    check latest.ver == newVersion("4.0.5")
    check latest.tag == "v4.0.5"

  test "issue #1692: stale download cache must be invalidated":
    let tempDir = getTempDir() / "nimble_test_1692"
    try:
      removeDir(tempDir)
      createDir(tempDir)

      writeFile(tempDir / "chronos.nimble", """
# Package
version       = "4.2.2"
author        = "Status Research"
description   = "Chronos"
license       = "MIT"

requires "nim >= 1.6.0"
""")

      var options = initOptions()
      let verRange = parseVersionRange("4.0.5")

      check pkgDirHasNimble(tempDir, options) == true
      check isCacheVersionValid(tempDir, verRange, options) == false

    finally:
      removeDir(tempDir)

  test "issue #1692: version discovery fallback must skip on checkout failure":
    let tempDir = getTempDir() / "nimble_test_1692_checkout"
    try:
      removeDir(tempDir)
      createDir(tempDir)

      discard execCmdEx("git -C " & tempDir & " init")
      discard execCmdEx("git -C " & tempDir & " config user.email test@test.com")
      discard execCmdEx("git -C " & tempDir & " config user.name test")
      writeFile(tempDir / "chronos.nimble",
        "version = \"2.0.0\"\nrequires \"nim >= 1.6.0\"\n")
      discard execCmdEx("git -C " & tempDir & " add .")
      discard execCmdEx("git -C " & tempDir & " commit -m 'v2.0.0'")
      discard execCmdEx("git -C " & tempDir & " tag v2.0.0")

      var options = initOptions()

      check doCheckout(DownloadMethod.git, tempDir, "v2.0.0", options) == true
      check doCheckout(DownloadMethod.git, tempDir, "v1.0.0", options) == false
      check isCacheVersionValid(tempDir, parseVersionRange("1.0.0"), options) == false

    finally:
      removeDir(tempDir)

  test "PkgTuple JSON round-trip produces valid version strings":
    let cases = @[
      parseRequires("nim >= 2.0.0"),
      parseRequires("stew"),
      parseRequires("chronicles#head"),
      parseRequires("results >= 0.3 & < 1.0"),
    ]
    for original in cases:
      let jsonNode = original.toJsonHook()
      let serialized = jsonNode.getStr()
      check "(kind:" notin serialized
      check "verEq" notin serialized
      var roundTripped: PkgTuple
      var path = ""
      initFromJson(roundTripped, jsonNode, path)
      check roundTripped.name == original.name
      check roundTripped.ver.kind == original.ver.kind

  test "issue #1691: solver succeeds when old versions depend on missing packages":
    var pkgVersionTable = initTable[string, PackageVersions]()
    let root = PackageMinimalInfo(
      name: "testpkg", version: newVersion("0.1.0"), isRoot: true,
      requires: @[("prologue", parseVersionRange(">= 0.6.0"))])
    pkgVersionTable["testpkg"] = PackageVersions(pkgName: "testpkg", versions: @[root])
    let prologueOld = PackageMinimalInfo(
      name: "prologue", version: newVersion("0.3.2"),
      requires: @[("cookies", parseVersionRange(">= 0.2.0"))])
    let prologueNew = PackageMinimalInfo(
      name: "prologue", version: newVersion("0.6.8"),
      requires: @[("cookiejar", parseVersionRange(">= 0.2.0"))])
    pkgVersionTable["prologue"] = PackageVersions(
      pkgName: "prologue", versions: @[prologueOld, prologueNew])
    let cookiejar = PackageMinimalInfo(
      name: "cookiejar", version: newVersion("0.3.1"), requires: @[])
    pkgVersionTable["cookiejar"] = PackageVersions(
      pkgName: "cookiejar", versions: @[cookiejar])

    var output = ""
    var options = initOptions()
    let solved = pkgVersionTable.getSolvedPackages(output, options)
    check solved.len > 0
    var foundPrologue = false
    for pkg in solved:
      if pkg.pkgName == "prologue":
        check pkg.version == newVersion("0.6.8")
        foundPrologue = true
    check foundPrologue
