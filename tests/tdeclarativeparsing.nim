{.used.}
import unittest
import testscommon
import std/[options, tables, sequtils]
import
  nimblepkg/[packageinfotypes, version, options, config, nimblesat, declarativeparser]

proc getNimbleFileFromPkgNameHelper(pkgName: string): string =
  let pv: PkgTuple = (pkgName, VersionRange(kind: verAny))
  var options = initOptions()
  options.nimBin = some options.makeNimBin("nim")
  options.config.packageLists["official"] = PackageList(
    name: "Official",
    urls:
      @[
        "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
        "https://nim-lang.org/nimble/packages.json",
      ],
  )
  options.pkgCachePath = "./nimbleDir/pkgcache"
  let pkgInfo = downloadPkInfoForPv(pv, options)
  pkgInfo.myPath

suite "Declarative parsing":
  test "should parse requires from a nimble file":
    let nimbleFile = getNimbleFileFromPkgNameHelper("nimlangserver")

    let requires = getRequires(nimbleFile)

    let expectedPkgs =
      @["nim", "json_rpc", "with", "chronicles", "serialization", "stew", "regex"]
    for pkg in expectedPkgs:
      check pkg in requires.mapIt(it[0])
