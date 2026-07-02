{.used.}
import unittest, os
import testscommon
import std/[tables, sequtils, strutils, options, strformat, osproc]
import chronos
import nimblepkg/[version, nimblesat, options, config, download, packageinfotypes, versiondiscovery]
from nimblepkg/common import cd, NimbleError
from nimblepkg/packageparser import validateVersion

let nimBin = some("nim")

suite "Version Discovery":
  test "should be able to download a package and select its deps":

    let pkgName: string = "nimlangserver"
    let pv: PkgTuple = (pkgName, VersionRange(kind: verAny))
    var options = initOptions()
    options.nimBin = some options.makeNimBin("nim")
    options.config.packageLists["official"] = PackageList(name: "Official", urls: @[
      "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
      "https://nim-lang.org/nimble/packages.json"
    ])

    var pkgInfo = downloadPkInfoForPv(pv, options, nimBin = nimBin)
    var root = pkgInfo.getMinimalInfo(options)
    root.isRoot = true
    var pkgVersionTable = waitFor collectAllVersions(root, options, downloadMinimalPackage, nimBin = nimBin)
    pkgVersionTable[pkgName] = PackageVersions(pkgName: pkgName, versions: @[root])

    var graph = pkgVersionTable.toDepGraph()
    let form = graph.toFormular()
    var packages = initTable[string, Version]()
    var output = ""
    check solve(graph, form, packages, output, initOptions())
    if packages.len == 0:
      echo output
    check packages.len > 0

  test "should be able to retrieve the package minimal info from the nimble directory":
    var options = initOptions()
    options.nimbleDir = getCurrentDir() / "conflictingdepres" / "nimbledeps"
    let pkgs = getInstalledMinimalPackages(options)
    var pkgVersionTable = initTable[string, PackageVersions]()
    fillPackageTableFromPreferred(pkgVersionTable, pkgs)
    check pkgVersionTable.hasVersion("b", newVersion "0.1.4")
    check pkgVersionTable.hasVersion("c", newVersion "0.1.0")
    check pkgVersionTable.hasVersion("c", newVersion "0.2.1")

  test "should fallback to the download if the package is not found in the list of packages":
    let root =
      PackageMinimalInfo(
        name: "a", version: newVersion "3.0",
        requires: @[
        (name:"b", ver: parseVersionRange ">= 0.1.4"),
        (name:"c", ver: parseVersionRange ">= 0.0.5 & <= 0.1.0"),
        (name: "random", ver: VersionRange(kind: verAny)),
      ],
      isRoot:true)

    var options = initOptions()
    options.config.packageLists["official"] = PackageList(name: "Official", urls: @[
      "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
      "https://nim-lang.org/nimble/packages.json"
    ])
    options.nimbleDir = getCurrentDir() / "conflictingdepres" / "nimbledeps"
    options.nimBin = some options.makeNimBin("nim")
    options.pkgCachePath = getCurrentDir() / "conflictingdepres" / "download"
    let pkgs = getInstalledMinimalPackages(options)
    var pkgVersionTable = initTable[string, PackageVersions]()
    pkgVersionTable["a"] = PackageVersions(pkgName: "a", versions: @[root])
    fillPackageTableFromPreferred(pkgVersionTable, pkgs)
    let discovered = waitFor collectAllVersions(root, options, downloadMinimalPackage, nimBin = nimBin)
    for k, v in discovered:
      if k notin pkgVersionTable: pkgVersionTable[k] = v
      else:
        for ver in v.versions: pkgVersionTable[k].versions.addVersionUnique ver
    var output = ""
    let solvedPkgs = pkgVersionTable.getSolvedPackages(output, options)
    let pkgB = solvedPkgs.filterIt(it.pkgName == "b")[0]
    let pkgC = solvedPkgs.filterIt(it.pkgName == "c")[0]
    check pkgB.pkgName == "b" and pkgB.version == newVersion "0.1.4"
    check pkgC.pkgName == "c" and pkgC.version == newVersion "0.1.0"
    check "random" in pkgVersionTable

    removeDir(options.pkgCachePath)

  test "should be able to get all the released PackageVersions from a git local repository":
    var options = initOptions()
    options.nimBin = some options.makeNimBin("nim")
    options.config.packageLists["official"] = PackageList(name: "Official", urls: @[
    "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
    "https://nim-lang.org/nimble/packages.json"
    ])
    options.localDeps = false
    let pv = parseRequires("nimfp >= 0.3.4")
    let downloadRes = pv.downloadPkgFromUrl(options, nimBin = nimBin)[0] #This is just to setup the test. We need a git dir to work on
    let repoDir = downloadRes.dir
    let downloadMethod = DownloadMethod git
    let packageVersions = waitFor getPackageMinimalVersionsFromRepo(repoDir, pv, downloadMethod, options, nimBin = nimBin)

    #we know these versions are available
    let availableVersions = @["0.3.4", "0.3.5", "0.3.6", "0.4.5", "0.4.4"].mapIt(newVersion(it))
    for version in availableVersions:
      check version in packageVersions.mapIt(it.version)
    # Check that the centralized cache file exists
    check fileExists(options.pkgCachePath / TaggedVersionsFileName)

  test "should use the centralized cache for package versions":
    var options = initOptions()
    options.nimBin = some options.makeNimBin("nim")
    options.localDeps = false
    options.config.packageLists["official"] = PackageList(name: "Official", urls: @[
    "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
    "https://nim-lang.org/nimble/packages.json"
    ])
    # Clean up any existing cache
    removeFile(options.pkgCachePath / TaggedVersionsFileName)
    for dir in walkDir(".", true):
      if dir.kind == PathComponent.pcDir and dir.path.startsWith("githubcom_vegansknimfp"):
        echo "Removing dir", dir.path
        removeDir(dir.path)

    let pvPrev = parseRequires("nimfp >= 0.3.4")
    let downloadResPrev = pvPrev.downloadPkgFromUrl(options, nimBin = nimBin)[0]
    let repoDirPrev = downloadResPrev.dir
    discard waitFor getPackageMinimalVersionsFromRepo(repoDirPrev, pvPrev, DownloadMethod.git, options, nimBin = nimBin)
    # Check that the centralized cache file exists
    check fileExists(options.pkgCachePath / TaggedVersionsFileName)

    # Requesting a different version should use the same centralized cache
    let pv = parseRequires("nimfp >= 0.4.4")
    let downloadRes = pv.downloadPkgFromUrl(options, nimBin = nimBin)[0]
    let repoDir = downloadRes.dir

    # The second call should use the cached versions from the centralized cache
    let packageVersions = waitFor getPackageMinimalVersionsFromRepo(repoDir, pv, DownloadMethod.git, options, nimBin = nimBin)
    #we know these versions are available
    let availableVersions = @["0.4.5", "0.4.4"].mapIt(newVersion(it))
    for version in availableVersions:
      check version in packageVersions.mapIt(it.version)

  test "collectAllVersions should retrieve all releases of a given package":
    var options = initOptions()
    options.nimBin = some options.makeNimBin("nim")
    options.config.packageLists["official"] = PackageList(name: "Official", urls: @[
    "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
    "https://nim-lang.org/nimble/packages.json"
    ])
    let pv = parseRequires("chronos >= 4.0.0")
    var pkgInfo = downloadPkInfoForPv(pv, options, nimBin = nimBin)
    var root = pkgInfo.getMinimalInfo(options)
    root.isRoot = true
    var pkgVersionTable = waitFor collectAllVersions(root, options, downloadMinimalPackage, nimBin = nimBin)
    for k, v in pkgVersionTable:
      # All packages should have at least one version
      check v.versions.len > 0
      echo &"{k} versions {v.versions.len}"

  test "should fallback to a previous version of a dependency when is unsatisfable":
    #version 0.4.5 of nimfp requires nim as `nim 0.18.0` and other deps require `nim > 0.18.0`
    #version 0.4.4 tags it properly, so we test thats the one used
    #i.e when maxTaggedVersions is 1 it would fail as it would use 0.4.5
    cd "wronglytaggednim":
      removeDir("nimbledeps")
      let (_, exitCode) = execNimble("install", "-l")
      check exitCode == QuitSuccess

  test "should be able to collect all requires from old versions":
    #We know this nimble version has additional requirements (new nimble use submodules)
    #so if the requires are not collected we will not be able solve the package
    cd "oldnimble": #0.16.2
      removeDir("nimbledeps")
      let (_, exitCode) = execNimbleYes("install", "-l")
      check exitCode == QuitSuccess

  test "special versions should not replace tagged versions during collection":
    # This test verifies the fix for the issue where #head would replace all tagged versions
    # in processRequirements. When collecting versions, if one dependency path requires #head
    # and another requires a normal version, both should be kept in the version table.

    # Mock getMinimalPackage that returns controlled versions
    proc mockGetMinimalPackage(pv: PkgTuple, options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
      case pv.name
      of "dep":
        if pv.ver.kind == verSpecial:
          var headVer = newVersion("#head")
          headVer.speSemanticVersion = some("0.3.0")
          return @[PackageMinimalInfo(name: "dep", version: headVer)]
        else:
          return @[
            PackageMinimalInfo(name: "dep", version: newVersion("0.2.5")),
            PackageMinimalInfo(name: "dep", version: newVersion("0.2.0")),
            PackageMinimalInfo(name: "dep", version: newVersion("0.1.0"))
          ]
      of "wrapper":
        return @[
          PackageMinimalInfo(name: "wrapper", version: newVersion("1.0.0"), requires: @[
            (name: "dep", ver: parseVersionRange(">= 0.2.0"))
          ]),
          PackageMinimalInfo(name: "wrapper", version: newVersion("0.5.0"), requires: @[
            (name: "dep", ver: parseVersionRange("#head"))
          ])
        ]
      else:
        return @[]

    var options = initOptions()

    # Root package requires wrapper and dep
    let root = PackageMinimalInfo(
      name: "root",
      version: newVersion("1.0.0"),
      requires: @[
        (name: "wrapper", ver: parseVersionRange(">= 0.5.0")),
        (name: "dep", ver: parseVersionRange(">= 0.1.0"))
      ],
      isRoot: true
    )

    # Collect all versions - this triggers processRequirements
    var pkgVersionTable = waitFor collectAllVersions(root, options, mockGetMinimalPackage, nimBin = some("nim"))
    pkgVersionTable["root"] = PackageVersions(pkgName: "root", versions: @[root])

    check pkgVersionTable.hasKey("dep")
    let depVersions = pkgVersionTable["dep"].versions.mapIt($it.version)

    # Should have tagged versions (not replaced by #head)
    check "0.2.5" in depVersions or "0.2.0" in depVersions or "0.1.0" in depVersions
    # Should also have #head
    check "#head" in depVersions

  test "cachedTagsCoverLocalTags detects stale tagged_versions.json":
    # Regression for: SAT solver doesn't fetch git tags when resolving
    # `requires "pkg >= X.Y.Z"` by name. Stale tagged_versions.json entries
    # must be detected so the resolution path refreshes them instead of
    # returning only locally-installed versions.

    # Cache has only 0.1.0, but the repo has v0.1.0 and v0.1.1 tagged locally.
    let cached = @[
      PackageMinimalInfo(name: "kairos", version: newVersion("0.1.0"))
    ]
    check not cachedTagsCoverLocalTags(cached, @["v0.1.0", "v0.1.1"])

    # Cache covers all local tags — fresh.
    let cachedFresh = @[
      PackageMinimalInfo(name: "kairos", version: newVersion("0.1.0")),
      PackageMinimalInfo(name: "kairos", version: newVersion("0.1.1"))
    ]
    check cachedTagsCoverLocalTags(cachedFresh, @["v0.1.0", "v0.1.1"])

    # Cache has MORE than local — fresh (local repo just hasn't fetched all tags).
    check cachedTagsCoverLocalTags(cachedFresh, @["v0.1.0"])

    # Empty tag list — vacuously fresh.
    check cachedTagsCoverLocalTags(cached, @[])

  test "downloadMinimalPackage memoizes a dep reached by many branches (75x ls-remote bug)":
    # A near-universal transitive dep (e.g. unittest2 in nimbus-eth1) is reached by
    # many top-level dependency branches, each with its own `visited` set. It must be
    # downloaded ONCE per resolution pass. The bug: the cache evicted each entry the
    # moment its download completed, so every branch that reached the dep *afterward*
    # re-ran `git ls-remote` — 75 times in the wild. Remote tags don't change within a
    # single invocation, so the result must be memoized for the whole pass.
    var fetchCount = 0
    proc countingFetch(pv: PkgTuple, options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
      inc fetchCount
      return @[PackageMinimalInfo(name: "diamonddep", version: newVersion("1.0.0"))]

    let pv: PkgTuple = ("https://github.com/example/diamonddep.git", VersionRange(kind: verAny))
    var options = initOptions()

    # Branches reach the same dep one after another (staggered, not concurrent).
    for i in 0 ..< 10:
      let res = waitFor memoizedDownloadMinimal(pv, options, nimBin, countingFetch)
      check res.len == 1

    check fetchCount == 1

  test "downloadMinimalPackage does not memoize a failed download":
    # A failed discovery must be evicted so a later reach can retry (and so the real
    # error surfaces) instead of replaying a cached failure for the rest of the pass.
    var attempt = 0
    proc flakyFetch(pv: PkgTuple, options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
      inc attempt
      if attempt == 1:
        raise newException(NimbleError, "transient failure")
      return @[PackageMinimalInfo(name: "flakydep", version: newVersion("2.0.0"))]

    let pv: PkgTuple = ("https://github.com/example/flakydep.git", VersionRange(kind: verAny))
    var options = initOptions()

    expect CatchableError:
      discard waitFor memoizedDownloadMinimal(pv, options, nimBin, flakyFetch)

    # Second reach must retry, not replay the cached failure.
    let res = waitFor memoizedDownloadMinimal(pv, options, nimBin, flakyFetch)
    check res.len == 1
    check attempt == 2

  test "verAny uses version-agnostic cache directory for discovery":
    # Test that verAny (used during package discovery) uses version-agnostic cache
    # to avoid downloading the same repo multiple times.
    # Specific version requirements use version-specific directories to ensure
    # correct version is installed.
    var options = initOptions()
    options.nimBin = some options.makeNimBin("nim")
    options.config.packageLists["official"] = PackageList(name: "Official", urls: @[
      "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
      "https://nim-lang.org/nimble/packages.json"
    ])

    let url = "https://github.com/vegansk/nimfp"

    # verAny uses version-agnostic cache (for package discovery/enumeration)
    let cacheDirAny = getCacheDownloadDir(url, VersionRange(kind: verAny), options)

    # Specific version requirements use version-specific directories
    let cacheDir1 = getCacheDownloadDir(url, parseVersionRange(">= 0.3.0"), options)
    let cacheDir2 = getCacheDownloadDir(url, parseVersionRange(">= 0.4.0"), options)
    let cacheDir3 = getCacheDownloadDir(url, parseVersionRange("== 0.4.5"), options)

    # verAny should differ from specific versions
    check cacheDirAny != cacheDir1
    check cacheDirAny != cacheDir2
    check cacheDirAny != cacheDir3

    # Different version requirements should have different directories
    check cacheDir1 != cacheDir2
    check cacheDir2 != cacheDir3

    # Special versions (commit hashes) should also get separate directories
    let cacheDir4 = getCacheDownloadDir(url, parseVersionRange("#abc123"), options)
    let cacheDir5 = getCacheDownloadDir(url, parseVersionRange("#def456"), options)

    # Different special versions should have different directories
    check cacheDir4 != cacheDir5

  test "getVersionList ignores tags that are not real version tags":
    let tags = @[
      "v1.0.0", "0.6.0", "v23.2.0-rc1", "v1.0.5",       # real version tags
      "v7", "v20240112",                                 # single-segment versions (require a `v`)
      "2024",                                            # single-segment WITHOUT `v` -> rejected
      "201903-testnet0", "delete", "nightly", "latest", # junk
      "not_a_release_0", "altona_v1", "altair-beta",    # junk
    ]
    let kept = toSeq(getVersionList(tags).values)
    # real version tags are kept
    check "v1.0.0" in kept
    check "0.6.0" in kept
    check "v23.2.0-rc1" in kept
    check "v1.0.5" in kept
    # single-segment versions are kept only with a `v` prefix
    check "v7" in kept
    check "v20240112" in kept
    check "2024" notin kept
    # junk tags are dropped (incl. junk that merely starts/ends with digits)
    check "201903-testnet0" notin kept
    check "delete" notin kept
    check "nightly" notin kept
    check "latest" notin kept
    check "not_a_release_0" notin kept
    check "altona_v1" notin kept
    check "altair-beta" notin kept

# --- Pre-release version discovery from real git tags -----------------------

proc runGit(dir, args: string) =
  let (output, code) = execCmdEx("git -C " & dir.quoteShell & " " & args)
  doAssert code == 0, "git " & args & " failed:\n" & output

proc nimbleContent(version: string, requires: seq[string] = @[]): string =
  ## A minimal, declaratively-parseable nimble file.
  result = "version = \"" & version & "\"\n" &
           "author = \"t\"\ndescription = \"t\"\nlicense = \"MIT\"\n"
  for r in requires:
    result &= "requires \"" & r & "\"\n"

proc makeTaggedRepo(remoteDir, pkgName: string,
                    tags: seq[tuple[tag, content: string]]) =
  ## Build a git repo where each tag points at a specific nimble file state.
  removeDir(remoteDir)
  createDir(remoteDir)
  runGit(remoteDir, "init")
  runGit(remoteDir, "config user.email test@test.com")
  runGit(remoteDir, "config user.name test")
  let nimbleFile = remoteDir / (pkgName & ".nimble")
  for (tag, content) in tags:
    writeFile(nimbleFile, content)
    runGit(remoteDir, "add .")
    runGit(remoteDir, "commit -m " & tag.quoteShell)
    runGit(remoteDir, "tag " & tag)

proc cloneLocalRepo(remoteDir, workDir: string) =
  ## A local clone gets `origin` pointing at `remoteDir`, so the discovery
  ## code's `git fetch --tags` works offline.
  removeDir(workDir)
  let (output, code) = execCmdEx(
    "git clone " & remoteDir.quoteShell & " " & workDir.quoteShell)
  doAssert code == 0, "git clone failed:\n" & output

proc discoverVersions(workDir, reqStr, cacheDir: string): seq[PackageMinimalInfo] =
  var options = initOptions()
  options.nimBin = some options.makeNimBin("nim")
  removeDir(cacheDir)
  createDir(cacheDir)
  options.pkgCachePath = cacheDir
  let pv = parseRequires(reqStr)
  result = waitFor getPackageMinimalVersionsFromRepo(
    workDir, pv, DownloadMethod.git, options, nimBin = nimBin)

suite "Pre-release version discovery (integration)":
  let base = getTempDir() / "nimble_prerelease_it"

  test "pre-release git tags are discovered and ordered below the final release":
    let remote = base / "ordering_remote"
    let work = base / "ordering_work"
    let cache = base / "ordering_cache"
    try:
      makeTaggedRepo(remote, "prerelib", @[
        ("v1.0.0-rc1", nimbleContent("1.0.0-rc1")),
        ("v1.0.0", nimbleContent("1.0.0")),
        ("v1.1.0", nimbleContent("1.1.0")),
      ])
      cloneLocalRepo(remote, work)
      let vers = discoverVersions(work, "prerelib >= 1.0.0-rc1", cache).mapIt(it.version)
      check newVersion("1.0.0-rc1") in vers
      check newVersion("1.0.0") in vers
      check newVersion("1.1.0") in vers
      # the pre-release orders below its final release
      check newVersion("1.0.0-rc1") < newVersion("1.0.0")
    finally:
      for d in [remote, work, cache]: removeDir(d)

  test "a pre-release requires in a real nimble file is parsed end-to-end":
    let remote = base / "requires_remote"
    let work = base / "requires_work"
    let cache = base / "requires_cache"
    try:
      makeTaggedRepo(remote, "reqlib", @[
        ("v1.0.0", nimbleContent("1.0.0", @["dep >= 1.0.0-rc1"])),
      ])
      cloneLocalRepo(remote, work)
      let versions = discoverVersions(work, "reqlib >= 1.0.0", cache)
      let v = versions.filterIt(it.version == newVersion("1.0.0"))[0]
      let depReq = v.requires.filterIt(it.name == "dep")[0]
      check depReq.ver.kind == verEqLater
      check depReq.ver.ver == newVersion("1.0.0-rc1")
    finally:
      for d in [remote, work, cache]: removeDir(d)

  test "the package version field accepts a pre-release through the VM parser gate":
    # validateVersion is the full/VM parser's gate on the `version` field. It
    # must accept the same semver charset that newVersion and parseVersionRange
    # accept, otherwise a package declaring `version = "1.0.0-rc1"` fails to
    # parse whenever the VM fallback is used (complex/computed nimble files).
    validateVersion("1.0.0-rc1")
    validateVersion("2.0.0-alpha.1")
    validateVersion("1.0.0+build.5")
    # genuinely invalid characters are still rejected
    expect NimbleError:
      validateVersion("1.0.0/bad")

  test "nimble file version field wins when it disagrees with the git tag":
    # Tag says v2.0.0 but the nimble file declares 2.0.0-rc1. Discovery must use
    # the nimble file version (declarativeparser: file version overrides the tag).
    let remote = base / "mismatch_remote"
    let work = base / "mismatch_work"
    let cache = base / "mismatch_cache"
    try:
      makeTaggedRepo(remote, "mmlib", @[
        ("v2.0.0", nimbleContent("2.0.0-rc1")),
      ])
      cloneLocalRepo(remote, work)
      let vers = discoverVersions(work, "mmlib >= 1.0.0", cache).mapIt($it.version)
      check "2.0.0-rc1" in vers   # file version wins
      check "2.0.0" notin vers    # the tag's version is not used
    finally:
      for d in [remote, work, cache]: removeDir(d)
