{.used.}
import unittest, os
import testscommon
import std/[tables, sequtils, strutils, options, strformat]
import nimblepkg/[version, nimblesat, options, config, download, packageinfotypes, versiondiscovery]
from nimblepkg/common import cd, NimbleError

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
    var pkgVersionTable = initTable[string, PackageVersions]()
    collectAllVersions(pkgVersionTable, root, options, downloadMinimalPackage, nimBin = nimBin)
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
    collectAllVersions(pkgVersionTable, root, options, downloadMinimalPackage, nimBin = nimBin)
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
    let packageVersions = getPackageMinimalVersionsFromRepo(repoDir, pv, downloadRes.version, downloadMethod, options, nimBin = nimBin)

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
    discard getPackageMinimalVersionsFromRepo(repoDirPrev, pvPrev, downloadResPrev.version,  DownloadMethod.git, options, nimBin = nimBin)
    # Check that the centralized cache file exists
    check fileExists(options.pkgCachePath / TaggedVersionsFileName)

    # Requesting a different version should use the same centralized cache
    let pv = parseRequires("nimfp >= 0.4.4")
    let downloadRes = pv.downloadPkgFromUrl(options, nimBin = nimBin)[0]
    let repoDir = downloadRes.dir

    # The second call should use the cached versions from the centralized cache
    let packageVersions = getPackageMinimalVersionsFromRepo(repoDir, pv, downloadRes.version, DownloadMethod.git, options, nimBin = nimBin)
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
    var pkgVersionTable = initTable[string, PackageVersions]()
    collectAllVersions(pkgVersionTable, root, options, downloadMinimalPackage, nimBin = nimBin)
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
    proc mockGetMinimalPackage(pv: PkgTuple, options: Options, nimBin: Option[string]): seq[PackageMinimalInfo] =
      case pv.name
      of "dep":
        if pv.ver.kind == verSpecial:
          # When #head is requested, return #head version
          var headVer = newVersion("#head")
          headVer.speSemanticVersion = some("0.3.0")
          return @[PackageMinimalInfo(name: "dep", version: headVer)]
        else:
          # Return tagged versions
          return @[
            PackageMinimalInfo(name: "dep", version: newVersion("0.2.5")),
            PackageMinimalInfo(name: "dep", version: newVersion("0.2.0")),
            PackageMinimalInfo(name: "dep", version: newVersion("0.1.0"))
          ]
      of "wrapper":
        # Return both versions of wrapper
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

    var pkgVersionTable = initTable[string, PackageVersions]()
    pkgVersionTable["root"] = PackageVersions(pkgName: "root", versions: @[root])

    # Collect all versions - this triggers processRequirements
    collectAllVersions(pkgVersionTable, root, options, mockGetMinimalPackage, nimBin = some("nim"))

    check pkgVersionTable.hasKey("dep")
    let depVersions = pkgVersionTable["dep"].versions.mapIt($it.version)

    # Should have tagged versions (not replaced by #head)
    check "0.2.5" in depVersions or "0.2.0" in depVersions or "0.1.0" in depVersions
    # Should also have #head
    check "#head" in depVersions

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
