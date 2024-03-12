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
    collectAllVersions(pkgVersionTable, pkgInfo, options)
    pkgVersionTable[pkgName] = PackageVersions(pkgName: pkgName, versions: @[root])

    var graph = pkgVersionTable.toDepGraph()
    let form = graph.toFormular()
    var packages = initTable[string, Version]()
    solve(graph, form, packages, listVersions= true)
    check packages.len > 0
    echo "Packages ", packages
      

      #Test to also add to the package the json_rpc original and the 
      #asynctools
  # test "should be able to retrieve the package versions using git":
  #   #[
  #     Testear uno que tenga varios paquetes.
  #     Head version is producing a duplicated in the versions   

  #   ]#

  #   let pkgName: string = "nimlangserver"
  #   let pv: PkgTuple = (pkgName, VersionRange(kind: verAny))
  #   var options = initOptions()
  #   options.nimBin = "nim"
  #   # options.config.packageLists["uing"] = PackageList(name: pkgName, urls: @[pkgUrl])
  #   options.config.packageLists["official"] = PackageList(name: "Official", urls: @[
  #     "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
  #     "https://nim-lang.org/nimble/packages.json"
  #   ])

  #   when false:
  #     var pkgInfo = downloadPkInfoForPv(pv, options)
  #     var root = pkgInfo.getMinimalInfo()
  #     # root.requires = root.requires.mapIt(
  #     #   if  it.name.contains "asynctools": (name: "asynctools", ver: VersionRange(kind: verAny))
  #     #   elif it.name.contains "nim-json-rpc": (name: "json_rpc", ver:VersionRange(kind: verAny))
  #     #   else: it
  #     # )
  #     root.isRoot = true
  #     var pkgVersionTable = initTable[string, PackageVersions]()
  #     collectAllVersions(pkgVersionTable, pkgInfo, options)
  #     pkgVersionTable[pkgName] = PackageVersions(pkgName: pkgName, versions: @[root])

  #     let json = pkgVersionTable.toJson()
  #     writeFile("langserverPgkVersionTable.json", json.pretty())
  #   else:
  #     let file = readFile("langserverPgkVersionTable.json")
  #     let pkgVersionTable = parseJson(file).to(Table[string, PackageVersions])

  #     var graph = pkgVersionTable.toDepGraph()

  #     # echo "Graph ", graph
  #     let form = graph.toFormular()
  #     var packages = initTable[string, Version]()
  #     solve(graph, form, packages, listVersions= true)
  #     check packages.len > 0
  #     echo "Packages ", packages
      

  #     #Test to also add to the package the json_rpc original and the 
  #     #asynctools