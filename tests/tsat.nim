{.used.}
import unittest, os
import testscommon
from nimblepkg/common import cd
import std/[tables, sequtils, algorithm, json, jsonutils, strutils]
import nimblepkg/[version, sha1hashes, packageinfotypes, nimblesat, options, 
  download, packageinfo, packageparser, config]
import nimble


proc downloadPkInfoForPv(pv: PkgTuple, options: Options): PackageInfo  =
  let (meth, url, metadata) = 
    getDownloadInfo(pv, options, doPrompt = true)
  let subdir = metadata.getOrDefault("subdir")
  let res = 
    downloadPkg(url, pv.ver, meth, subdir, options,
                  downloadPath = "", vcsRevision = notSetSha1Hash)
  return getPkgInfo(res.dir, options)

proc initFromJson*(dst: var PkgTuple, jsonNode: JsonNode, jsonPath: var string) =
  dst = parseRequires(jsonNode.str)


proc toJsonHook*(src: PkgTuple): JsonNode =
  let ver = if src.ver.kind == verAny: "" else: $src.ver
  case src.ver.kind
  of verAny: newJString(src.name)
  of verSpecial: newJString(src.name & ver)
  else:
    newJString(src.name & " " & ver)

proc collectAllVersions(versions: var Table[string, PackageVersions], package: PackageInfo, options: Options) =
  for pv in package.requires:
    # echo "Collecting versions for ", pv.name, " and Version: ", $pv.ver, " via ", package.name
    var pv = pv
    if not hasVersion(versions, pv):  # Not found, meaning this package-version needs to be explored
      let pkgInfo = downloadPkInfoForPv(pv, options)
      var minimalInfo = pkgInfo.getMinimalInfo()
      if pv.ver.kind == verSpecial:
        echo "Special version ", pv, " but it was ", minimalInfo.version
        minimalInfo.version = newVersion $pv.ver
      if not versions.hasKey(pv.name):
        versions[pv.name] = PackageVersions(pkgName: pv.name, versions: @[minimalInfo])
      else:
        versions[pv.name].versions.addUnique minimalInfo
      collectAllVersions(versions, pkgInfo, options)


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
  collectAllVersions(pkgVersionTable, pkgInfo, options)
  pkgVersionTable[pkgName] = PackageVersions(pkgName: pkgName, versions: @[root])
  let json = pkgVersionTable.toJson()
  writeFile(path, json.pretty())

proc downloadAllPackages() = 
  var options = initOptions()
  options.nimBin = "nim"
  # options.config.packageLists["uing"] = PackageList(name: pkgName, urls: @[pkgUrl])
  options.config.packageLists["official"] = PackageList(name: "Official", urls: @[
    "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
    "https://nim-lang.org/nimble/packages.json"
  ])

  let packages = getPackageList(options).mapIt(it.name)
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
    solve(graph, form, packages, true)
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
    solve(graph, form, packages, true)
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
    solve(graph, form, packages)
    echo packages
    check packages.len == 0

  # test "issue #1162":
  #   cd "conflictingdepres":
  #     #integration version of the test above
  #     #TODO document folder structure setup so others know how to run similar tests
  #     let (_, exitCode) = execNimble("install", "-l")
  #     check exitCode == QuitSuccess

#[
  Next download all packages store it in a json and solve the dependencies one by one. 

  TODO
    - Create the table from already downloaded packages.
    - See if downloads can be cached and reused. 
    - Review if when downloading a package we could just navigate it to get all versions without triggering another download
    
]#

  # test "should be able to download a package and select its deps":

  #   let pkgName: string = "nimlangserver"
  #   let pv: PkgTuple = (pkgName, VersionRange(kind: verAny))
  #   var options = initOptions()
  #   options.nimBin = "nim"
  #   options.config.packageLists["official"] = PackageList(name: "Official", urls: @[
  #     "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
  #     "https://nim-lang.org/nimble/packages.json"
  #   ])

  #   var pkgInfo = downloadPkInfoForPv(pv, options)
  #   var root = pkgInfo.getMinimalInfo()
  #   root.isRoot = true
  #   var pkgVersionTable = initTable[string, PackageVersions]()
  #   collectAllVersions(pkgVersionTable, pkgInfo, options)
  #   pkgVersionTable[pkgName] = PackageVersions(pkgName: pkgName, versions: @[root])

  #   var graph = pkgVersionTable.toDepGraph()
  #   let form = graph.toFormular()
  #   var packages = initTable[string, Version]()
  #   solve(graph, form, packages, listVersions= true)
  #   check packages.len > 0
    

  test "should be solve all nimble packages":
    downloadAllPackages() #uncomment this to download all packages. It's better to just keep them cached as it takes a while.

    for jsonFile in walkPattern("packageMinimal/*.json"):
      var pkgVersionTable = parseJson(readFile(jsonFile)).to(Table[string, PackageVersions])
      var graph = pkgVersionTable.toDepGraph()
      let form = toFormular(graph)
      var packages = initTable[string, Version]()
      solve(graph, form, packages, listVersions= false)
      echo "Solved ", jsonFile.extractFilename, " with ", packages.len, " packages"

      check packages.len > 0