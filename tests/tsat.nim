{.used.}
import unittest, os
import testscommon
# from nimblepkg/common import cd Used in the commented tests
import std/[tables, sequtils, json, jsonutils, strutils, times]
import nimblepkg/[version, nimblesat, options, config]
from nimblepkg/common import cd


proc initFromJson*(dst: var PkgTuple, jsonNode: JsonNode, jsonPath: var string) =
  dst = parseRequires(jsonNode.str)

proc toJsonHook*(src: PkgTuple): JsonNode =
  let ver = if src.ver.kind == verAny: "" else: $src.ver
  case src.ver.kind
  of verAny: newJString(src.name)
  of verSpecial: newJString(src.name & ver)
  else:
    newJString(src.name & " " & ver)

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
  var pkgInfo = downloadPkInfoForPv(pv, options)
  var root = pkgInfo.getMinimalInfo()
  root.isRoot = true
  var pkgVersionTable = initTable[string, PackageVersions]()
  collectAllVersions(pkgVersionTable, root, options, downloadMinimalPackage)
  pkgVersionTable[pkgName] = PackageVersions(pkgName: pkgName, versions: @[root])
  let json = pkgVersionTable.toJson()
  writeFile(path, json.pretty())

proc downloadAllPackages() {.used.} = 
  var options = initOptions()
  options.nimBin = "nim"
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
  "nimwc",
  "artemis"]
  let toDownload = importantPackages.filterIt(it notin ignorePackages)
  for pkg in toDownload:
    echo "Downloading ", pkg
    downloadAndStorePackageVersionTableFor(pkg, options)
    echo "Done with ", pkg

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
    check solve(graph, form, packages, output)
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
    check solve(graph, form, packages, output)
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
    check not solve(graph, form, packages, output)
    echo output
    check packages.len == 0

  test "issue #1162":
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

  test "should be able to download a package and select its deps":

    let pkgName: string = "nimlangserver"
    let pv: PkgTuple = (pkgName, VersionRange(kind: verAny))
    var options = initOptions()
    options.nimBin = "nim"
    options.config.packageLists["official"] = PackageList(name: "Official", urls: @[
      "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
      "https://nim-lang.org/nimble/packages.json"
    ])

    var pkgInfo = downloadPkInfoForPv(pv, options)
    var root = pkgInfo.getMinimalInfo()
    root.isRoot = true
    var pkgVersionTable = initTable[string, PackageVersions]()
    collectAllVersions(pkgVersionTable, root, options, downloadMinimalPackage)
    pkgVersionTable[pkgName] = PackageVersions(pkgName: pkgName, versions: @[root])

    var graph = pkgVersionTable.toDepGraph()
    let form = graph.toFormular()
    var packages = initTable[string, Version]()
    var output = ""
    check solve(graph, form, packages, output)
    check packages.len > 0
    
  test "should be able to solve all nimble packages":
    # downloadAllPackages() #uncomment this to download all packages. It's better to just keep them cached as it takes a while.
    let now = now()
    var pks = 0
    for jsonFile in walkPattern("packageMinimal/*.json"):
      inc pks
      var pkgVersionTable = parseJson(readFile(jsonFile)).to(Table[string, PackageVersions])
      var graph = pkgVersionTable.toDepGraph()
      let form = toFormular(graph)
      var packages = initTable[string, Version]()
      var output = ""
      check solve(graph, form, packages, output)
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
    options.nimBin = "nim"
    options.pkgCachePath = getCurrentDir() / "conflictingdepres" / "download"
    let pkgs = getInstalledMinimalPackages(options)
    var pkgVersionTable = initTable[string, PackageVersions]()
    pkgVersionTable["a"] = PackageVersions(pkgName: "a", versions: @[root])
    fillPackageTableFromPreferred(pkgVersionTable, pkgs)
    collectAllVersions(pkgVersionTable, root, options, downloadMinimalPackage)
    var output = ""
    let solvedPkgs = pkgVersionTable.getSolvedPackages(output)
    let pkgB = solvedPkgs.filterIt(it.pkgName == "b")[0]
    let pkgC = solvedPkgs.filterIt(it.pkgName == "c")[0]
    check pkgB.pkgName == "b" and pkgB.version == newVersion "0.1.4"
    check pkgC.pkgName == "c" and pkgC.version == newVersion "0.1.0"
    check "random" in pkgVersionTable
    
    removeDir(options.pkgCachePath)