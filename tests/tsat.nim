{.used.}
import unittest, os, osproc
import testscommon
# from nimblepkg/common import cd, NimbleError Used in the commented tests
import std/[tables, json, jsonutils, strutils, sequtils, times, options]
import chronos
import nimblepkg/[version, nimblesat, options, config, packageinfotypes, versiondiscovery, urls]
from nimblepkg/common import cd, NimbleError

let nimBin = some("nim")
#Test utils:
proc downloadAndStorePackageVersionTableFor(pkgName: string, options: Options) =
  #Downloads all the dependencies for a given package and store the minimal version of the deps in a json file.
  var fileName = pkgName
  if pkgName.startsWith("https://"):
    let pkgUrl = pkgName
    fileName = pkgUrl.split("/")[^1].split(".")[0]
  
  let path = "packageMinimal" / fileName & ".json"
  if fileExists(path):
    return
  let pv: PkgTuple = (pkgName, VersionRange(kind: verAny))
  var pkgInfo = downloadPkInfoForPv(pv, options, nimBin = nimBin)
  var root = pkgInfo.getMinimalInfo(options)
  root.isRoot = true
  var pkgVersionTable = waitFor collectAllVersions(root, options, downloadMinimalPackage, nimBin = nimBin)
  pkgVersionTable[pkgName] = PackageVersions(pkgName: pkgName, versions: @[root])
  let json = pkgVersionTable.toJson()
  writeFile(path, json.pretty())

proc downloadAllPackages() {.used.} = 
  var options = initOptions()
  options.nimBin = some options.makeNimBin("nim")
  # options.config.packageLists["uing"] = PackageList(name: pkgName, urls: @[pkgUrl])
  options.config.packageLists["official"] = PackageList(name: "Official", urls: @[
    "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
    "https://nim-lang.org/nimble/packages.json"
  ])

  # let packages = getPackageList(options).mapIt(it.name)
  let importantPackages = [
  "alea", "argparse", "arraymancer", "ast_pattern_matching", "asyncftpclient", "asyncthreadpool", "awk", "bigints", "binaryheap", "BipBuffer", "blscurve",
  "bncurve", "brainfuck", "bump", "c2nim", "cascade", "cello", "checksums", "chroma", "chronicles", "chronos", "cligen", "combparser", "compactdict", 
  "https://github.com/alehander92/comprehension", "cowstrings", "criterion", "datamancer", "dashing", "delaunay", "docopt", "drchaos", "https://github.com/jackmott/easygl", "elvis", "fidget", "fragments", "fusion", "gara", "glob", "ggplotnim", 
  "https://github.com/disruptek/gittyup", "gnuplot", "https://github.com/disruptek/gram", "hts", "httpauth", "illwill", "inim", "itertools", "iterutils", "jstin", "karax", "https://github.com/jblindsay/kdtree", "loopfusion", "lockfreequeues", "macroutils", "manu", "markdown", 
  "measuremancer", "memo", "msgpack4nim", "nake", "https://github.com/nim-lang/neo", "https://github.com/nim-lang/NESM", "netty", "nico", "nicy", "nigui", "nimcrypto", "NimData", "nimes", "nimfp", "nimgame2", "nimgen", "nimib", "nimlsp", "nimly", 
  "nimongo", "https://github.com/disruptek/nimph", "nimPNG", "nimpy", "nimquery", "nimsl", "nimsvg", "https://github.com/nim-lang/nimterop", "nimwc", "nimx", "https://github.com/zedeus/nitter", "norm", "npeg", "numericalnim", "optionsutils", "ormin", "parsetoml", "patty", "pixie", 
  "plotly", "pnm", "polypbren", "prologue", "protobuf", "pylib", "rbtree", "react", "regex", "results", "RollingHash", "rosencrantz", "sdl1", "sdl2_nim", "sigv4", "sim", "smtp", "https://github.com/genotrance/snip", "ssostrings", 
  "stew", "stint", "strslice", "strunicode", "supersnappy", "synthesis", "taskpools", "telebot", "tempdir", "templates", "https://krux02@bitbucket.org/krux02/tensordslnim.git", "terminaltables", "termstyle", "timeit", "timezones", "tiny_sqlite", 
  "unicodedb", "unicodeplus", "https://github.com/alaviss/union", "unpack", "weave", "websocket", "winim", "with", "ws", "yaml", "zero_functional", "zippy"
  ]
  let ignorePackages = ["rpgsheet", 
  "arturo", "argument_parser", "murmur", "nimgame", "locale", "nim-locale",
  "nim-ao", "ao", "termbox", "linagl", "kwin", "yahooweather", "noaa",
  "nimwc", "pylib",
  "artemis"]
  let startAt = 0#importantPackages.find("rbtree")
  let toDownload = importantPackages
  for i, pkg in toDownload:
    if i >= startAt or pkg in ignorePackages:
      continue
    echo "Downloading ", pkg
    downloadAndStorePackageVersionTableFor(pkg, options)
    echo "Done with ", pkg

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

  test "nitter: same package from different fork URLs (asynctools)":
    # nitter's dep tree requires asynctools from multiple URLs:
    # - jester#baca3f requires "https://github.com/timotheecour/asynctools#pr_fix_compilation"
    # - httpbeast requires "asynctools#0e6bdc3ed5bae8c7cc9" (name-based → official)
    # normalizeSpecialVersions picks the first special version (topologically)
    # and rewrites all other requirements to use it.

    let pkgName = "https://github.com/zedeus/nitter"
    let pv: PkgTuple = (pkgName, VersionRange(kind: verAny))
    var options = initOptions()
    options.nimBin = some options.makeNimBin("nim")
    options.config.packageLists["official"] = PackageList(name: "Official", urls: @[
      "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
      "https://nim-lang.org/nimble/packages.json"
    ])

    var pkgInfo = downloadPkInfoForPv(pv, options, nimBin = nimBin)
    var pkgsToInstall: seq[(string, Version)] = @[]
    var solvedPkgs: seq[SolvedPackage] = @[]
    var output = ""

    # lenient=true (default): should resolve successfully
    options.lenient = true
    discard solvePackages(pkgInfo, @[], pkgsToInstall, options, output, solvedPkgs, nimBin)
    check solvedPkgs.len > 0

    # lenient=false: should fail with NimbleError on Linux/macOS where httpbeast is used (not used in windows)
    options.lenient = false
    when defined(windows):
      discard solvePackages(pkgInfo, @[], pkgsToInstall, options, output, solvedPkgs, nimBin)
    else:
      expect NimbleError:
        discard solvePackages(pkgInfo, @[], pkgsToInstall, options, output, solvedPkgs, nimBin)

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

  test "issue #1162":
    removeDir("conflictingdepres")
    let exitCode1 = execCmd("git checkout conflictingdepres/")
    check exitCode1 == QuitSuccess

    cd "conflictingdepres":
      #integration version of the test above
      #[
        The folder structure of the test is key for the setup:
          Notice how inside the pkgs2 folder (convention when using local packages) there are 3 folders
          where c has two versions of the same package. The version is retrieved counterintuitively from 
          the nimblemeta.json special version field. 
      ]#
      let (_, exitCode) = execNimble("install", "-l")
      check exitCode == QuitSuccess

    removeDir("conflictingdepres")
    let exitCode2 = execCmd("git checkout conflictingdepres/")
    check exitCode2 == QuitSuccess


  test "should be able to solve all nimble packages":
    # downloadAllPackages() #uncomment this to download all packages. It's better to just keep them cached as it takes a while.
    let now = now()
    var pks = 0
    for jsonFile in walkPattern("packageMinimal/*.json"):
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
    echo "Solved ", pks, " packages in ", ends - now, " seconds"
  
  test "#head requirements require #head available":
    # When a package requires dep#head, only #head should satisfy it, not tagged versions
    let pkgVersionTable = {
      "a": PackageVersions(pkgName: "a", versions: @[
        PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
          (name:"b", ver: parseVersionRange "#head")
        ], isRoot:true),
      ]),
      "b": PackageVersions(pkgName: "b", versions: @[
        PackageMinimalInfo(name: "b", version: newVersion "0.1.0")  # Only tagged version, no #head
      ])
    }.toTable()
    var graph = pkgVersionTable.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    var output = ""
    # Should fail because #head is required but only 0.1.0 is available
    check not solve(graph, form, packages, output, initOptions())

  test "#head requirements are satisfied when #head is available":
    # When #head is available, it should satisfy #head requirements
    let pkgVersionTable = {
      "a": PackageVersions(pkgName: "a", versions: @[
        PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
          (name:"b", ver: parseVersionRange "#head")
        ], isRoot:true),
      ]),
      "b": PackageVersions(pkgName: "b", versions: @[
        PackageMinimalInfo(name: "b", version: newVersion "0.1.0"),
        PackageMinimalInfo(name: "b", version: newVersion "#head")  # #head is available
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
    check packages["b"] == newVersion "1.0.0"  # Should pick exact version 1.0.0 despite 2.0.0 being available

  
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
   
  #TODO package got updated. Review test (not related with the declarative parser work)
  test "should be able to fallback to a previous version of a dependency when unsatisfable (complex case)":
    #There is an issue with 
    #[
      "libp2p",
      "https://github.com/status-im/nim-quic.git#8a97eeeb803614bce2eb0e4696127d813fea7526"
    
    Where libp2p needs to be set to an older version (15) as the constraints from nim-quic are incompatible with the 
    constraints from libp2p > 15.
    
    ]#
    cd "libp2pconflict": #0.16.2
      removeDir("nimbledeps")
      let (_, exitCode) = execNimbleYes("install", "-l")
      check exitCode == QuitSuccess

  #disabled for being too slow. TODO replace with one from the cached pkgtable similar to nwaku
  # test "should be able to solve complex dep graphs":
  #   cd "sattests" / "mgtest":
  #     removeDir("nimbledeps")
  #     let (_, exitCode) = execNimbleYes("install", "-l")
  #     check exitCode == QuitSuccess

  test "should be able to install packages with cycles in the requirements":
    cd "sattests" / "cycletest":
      removeDir("nimbledeps")
      let (_, exitCode) = execNimbleYes("install", "-l")
      check exitCode == QuitSuccess

  test "should prefer newer versions (waku@0.36.0 over 0.1.0)":
    # This test verifies that the SAT solver prefers newer versions of packages
    var pkgVersionTable = parseJson(readFile("packageMinimal/waku.json")).jsonTo(Table[string, PackageVersions], Joptions(allowMissingKeys: true))
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
    # The SAT solver should prefer waku@0.36.0 over waku@0.1.0
    check packages.hasKey("waku")
    echo "waku selected: ", packages["waku"]
    check packages["waku"] == newVersion("0.36.0")

  test "normalizeRequirements resolves URL to nimble package name":
    # Reproduces nim-libp2p issue (github.com/vacp2p/nim-libp2p/pull/2348):
    # nimble file requires "https://github.com/user/nim-jwt.git#hash"
    # while CLI install adds "https://github.com/user/nim-jwt#hash" (no .git)
    # Both should normalize to the actual package name "jwt" from the .nimble file,
    # not keep the git URL as the dependency name.
    var pkgVersionTable = {
      "root": PackageVersions(pkgName: "root", versions: @[
        PackageMinimalInfo(name: "root", version: newVersion "1.0", requires: @[
          # From nimble file: URL with .git suffix
          (name: "https://github.com/vacp2p/nim-jwt.git", ver: VersionRange(kind: verSpecial, spe: newVersion "#abc123")),
          # From CLI install: URL without .git suffix
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
    # Set speSemanticVersion on the special version
    pkgVersionTable["jwt"].versions[0].version.speSemanticVersion = some("0.1.0")

    var options = initOptions()
    pkgVersionTable.normalizeRequirements(options)

    # Both URL requirements should be normalized to "jwt" (the .nimble name)
    let rootReqs = pkgVersionTable["root"].versions[0].requires
    for req in rootReqs:
      check(not req.name.isUrl)
    let jwtReqs = rootReqs.filterIt(it.name == "jwt")
    check jwtReqs.len == 2

    # The SAT solver should find a valid solution using the package name
    var graph = pkgVersionTable.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    var output = ""
    check solve(graph, form, packages, output, options)
    check packages.hasKey("jwt")
    check packages.hasKey("bearssl")

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

  test "URL-keyed table entries cause SAT failure":
    # When processRequirements adds packages under URL keys instead of
    # .nimble package names, the SAT solver sees them as separate packages
    # and can't find a version that satisfies both the range and hash requirements.
    var pkgVersionTable = {
      "root": PackageVersions(pkgName: "root", versions: @[
        PackageMinimalInfo(name: "root", version: newVersion "1.0", requires: @[
          (name: "stew", ver: parseVersionRange(">= 0.4.2")),
          (name: "stew", ver: VersionRange(kind: verSpecial, spe: newVersion "#commit_b")),
        ], isRoot: true),
      ]),
      # Name-keyed entry: tagged versions only
      "stew": PackageVersions(pkgName: "stew", versions: @[
        PackageMinimalInfo(name: "stew", version: newVersion "0.5.0"),
        PackageMinimalInfo(name: "stew", version: newVersion "0.4.0"),
      ]),
      # BUG: URL-keyed duplicate — special version is here instead of under "stew"
      "https://github.com/status-im/nim-stew": PackageVersions(
        pkgName: "https://github.com/status-im/nim-stew", versions: @[
          PackageMinimalInfo(name: "stew", version: newVersion "#commit_b",
            url: "https://github.com/status-im/nim-stew"),
        ]),
    }.toTable()
    pkgVersionTable["https://github.com/status-im/nim-stew"].versions[0].version.speSemanticVersion = some("0.5.0")

    var options = initOptions()
    pkgVersionTable.normalizeRequirements(options)

    var graph = pkgVersionTable.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    var output = ""
    # Fails: the "stew" node has no special version, so #commit_b can't be satisfied
    check(not solve(graph, form, packages, output, options))

  test "package-name-keyed table entries solve correctly":
    # Same scenario but with special version correctly under the package name.
    # This is what the fixed processRequirements produces.
    var pkgVersionTable = {
      "root": PackageVersions(pkgName: "root", versions: @[
        PackageMinimalInfo(name: "root", version: newVersion "1.0", requires: @[
          (name: "stew", ver: parseVersionRange(">= 0.4.2")),
          (name: "stew", ver: VersionRange(kind: verSpecial, spe: newVersion "#commit_b")),
        ], isRoot: true),
      ]),
      "stew": PackageVersions(pkgName: "stew", versions: @[
        PackageMinimalInfo(name: "stew", version: newVersion "0.5.0"),
        PackageMinimalInfo(name: "stew", version: newVersion "0.4.0"),
      ]),
    }.toTable()

    var stewSpecial = newVersion("#commit_b")
    stewSpecial.speSemanticVersion = some("0.5.0")
    pkgVersionTable["stew"].versions.add PackageMinimalInfo(
      name: "stew", version: stewSpecial,
      url: "https://github.com/status-im/nim-stew")

    var options = initOptions()
    var graph = pkgVersionTable.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    var output = ""
    check solve(graph, form, packages, output, options)
    check packages["stew"] == stewSpecial

