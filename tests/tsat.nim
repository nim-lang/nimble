{.used.}
import unittest, os, osproc
import common
import std/[options, tables]
import nimblepkg/[version, nimblesat, options, config, packageinfotypes, versiondiscovery]
from nimblepkg/common import cd, NimbleError

let nimBin = some("nim")

suite "SAT solver":
  test "nitter: same package from different fork URLs (asynctools)":
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

    options.lenient = true
    discard solvePackages(pkgInfo, @[], pkgsToInstall, options, output, solvedPkgs, nimBin)
    check solvedPkgs.len > 0

    options.lenient = false
    when defined(windows):
      discard solvePackages(pkgInfo, @[], pkgsToInstall, options, output, solvedPkgs, nimBin)
    else:
      expect NimbleError:
        discard solvePackages(pkgInfo, @[], pkgsToInstall, options, output, solvedPkgs, nimBin)

  test "issue #1162":
    removeDir("conflictingdepres")
    let exitCode1 = execCmd("git checkout conflictingdepres/")
    check exitCode1 == QuitSuccess

    cd "conflictingdepres":
      let (_, exitCode) = execNimble("install", "-l")
      check exitCode == QuitSuccess

    removeDir("conflictingdepres")
    let exitCode2 = execCmd("git checkout conflictingdepres/")
    check exitCode2 == QuitSuccess

  test "should be able to fallback to a previous version of a dependency when unsatisfable (complex case)":
    cd "libp2pconflict":
      removeDir("nimbledeps")
      let (_, exitCode) = execNimbleYes("install", "-l")
      check exitCode == QuitSuccess
