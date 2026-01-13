{.used.}
import unittest, os, osproc
import testscommon
# from nimblepkg/common import cd Used in the commented tests
import std/[tables, sequtils, json, jsonutils, strutils, times, options, strformat]
import nimblepkg/[version, nimblesat, options, config, download, packageinfotypes]
from nimblepkg/common import cd

let nimBin = "nim"
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
  var pkgVersionTable = initTable[string, PackageVersions]()
  collectAllVersions(pkgVersionTable, root, options, downloadMinimalPackage, nimBin = nimBin)
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
      let (_, exitCode) = execNimble("install", "-l", "--solver:sat")
      check exitCode == QuitSuccess

    removeDir("conflictingdepres")
    let exitCode2 = execCmd("git checkout conflictingdepres/")
    check exitCode2 == QuitSuccess


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
      let (_, exitCode) = execNimbleYes("install", "-l")
      check exitCode == QuitSuccess

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

  test "special versions should not replace tagged versions during collection":
    # This test verifies the fix for the issue where #head would replace all tagged versions
    # in processRequirements. When collecting versions, if one dependency path requires #head
    # and another requires a normal version, both should be kept in the version table.

    # Mock getMinimalPackage that returns controlled versions
    proc mockGetMinimalPackage(pv: PkgTuple, options: Options, nimBin: string): seq[PackageMinimalInfo] =
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
    collectAllVersions(pkgVersionTable, root, options, mockGetMinimalPackage, nimBin = "nim")

    check pkgVersionTable.hasKey("dep")
    let depVersions = pkgVersionTable["dep"].versions.mapIt($it.version)

    # Should have tagged versions (not replaced by #head)
    check "0.2.5" in depVersions or "0.2.0" in depVersions or "0.1.0" in depVersions
    # Should also have #head
    check "#head" in depVersions
