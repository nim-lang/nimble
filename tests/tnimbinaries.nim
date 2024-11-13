{.used.}
import unittest
import nimblepkg/[options, downloadnim, version, nimblesat, packageparser]
import std/[os, options]
import testscommon
from nimblepkg/common import cd

suite "Nim binaries":
  test "can get all releases":
    var options = initOptions()
    let releases = getOfficialReleases(options)
    check releases.len > 0
    check releases[^1] == newVersion("1.2.8")

  test "can download a concrete version":
    var options = initOptions()
    let version = newVersion("1.2.8")
    let path = downloadNim(version, options)
    check path.fileExists()

  test "can download and unzip a version. Should also compile it if the precompiled binaries are not available for the current platform":
    var options = initOptions()
    let version = newVersion("2.0.4")
    let extractDir = downloadAndExtractNim(version, options)
    check extractDir.isSome


  test "Downloading minimal package with Nim should return all the versions":
    var options = initOptions()
    let pv = ("nim", VersionRange(kind: verAny))
    let releases: seq[Version] = getOfficialReleases(options)
    
    let minimalPgks = downloadMinimalPackage(pv, options)
    
    check minimalPgks.len > 0
    check minimalPgks.len == releases.len
    for pkg in minimalPgks:
      check pkg.version in releases
  
  test "installNimFromBinariesDir should return the installed version":
    var options = initOptions()
    let require: PkgTuple = (name: "nim", ver: parseVersionRange("2.0.4"))
    let nimInstalled = installNimFromBinariesDir(require, options)
    check nimInstalled.isSome
    check nimInstalled.get().ver == newVersion("2.0.4")
  
  test "should be able to get the package info from the nim extracted folder":
    var options = initOptions()
    let require: PkgTuple = (name: "nim", ver: parseVersionRange("2.2.0"))
    let nimInstalled = installNimFromBinariesDir(require, options)
    check nimInstalled.isSome
    check nimInstalled.get().ver == newVersion("2.2.0")
    options.nimBin = some options.makeNimBin("nim")
    let pkgInfo = getPkgInfo(nimInstalled.get().dir, options)    
    check pkgInfo.basicInfo.name == "nim"
  
  test "Should be able to reuse -without compiling- a Nim version":
    cd "nimnimble":
      let nimVerDir = "nim2.0.4"
      cd nimVerDir:
        removeDir("nimbledeps")
        let (output, exitCode) = execNimble("install", "-l")
        var lines = output.processOutput
        check "iteration: 1" notin lines
        check "iteration: 2" notin lines
        check exitCode == QuitSuccess

  test "when disableNimBinaries is used should compile the Nim version":
    cd "nimnimble":
      let nimVerDir = "nim2.0.4"
      cd nimVerDir:
        removeDir("nimbledeps")
        let (output, exitCode) = execNimble("install", "-l", "--disableNimBinaries")
        var lines = output.processOutput
        check "iteration: 1" in lines
        check "iteration: 2" in lines
        check exitCode == QuitSuccess
