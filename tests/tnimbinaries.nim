{.used.}
import unittest
import nimblepkg/[options, downloadnim, version, nimblesat, packageparser]
import std/[os, options, osproc, strutils]
import testscommon
from nimblepkg/common import cd

suite "Nim binaries":
  test "can get all releases":
    var options = initOptions()
    let releases = getOfficialReleases(options)
    check releases.len > 0

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
    let nimBin = "nim"
    let minimalPgks = downloadMinimalPackage(pv, options, nimBin)
    
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
    let require: PkgTuple = (name: "nim", ver: parseVersionRange("2.0.4"))
    let nimInstalled = installNimFromBinariesDir(require, options)
    check nimInstalled.isSome
    check nimInstalled.get().ver == newVersion("2.0.4")
    options.nimBin = some options.makeNimBin("nim")
    let pkgInfo = getPkgInfo(nimInstalled.get().dir, options, nimBin = "nim")    
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

  test "nimble builds with all supported Nim versions":
    const
      projectRoot = currentSourcePath().parentDir.parentDir
      nimVersionRanges = [
        ("nim ~= 1.6.0", "1.6."),
        ("nim ~= 2.0.0", "2.0."),
        ("nim ~= 2.2.0", "2.2."),
      ]
    for (nimRange, expectedPrefix) in nimVersionRanges:
      checkpoint("Building with " & nimRange)
      let cmd = nimblePath & " build --requires:" & nimRange.quoteShell
      let (output, exitCode) = execCmdEx(cmd, workingDir = projectRoot)
      checkpoint(output)
      check exitCode == QuitSuccess
      var verifiedVer: bool
      for line in output.splitLines:
        if "using" in line and "for compilation" in line:
          verifiedVer = true
          let nimBin = line.split("using")[1].split("for compilation")[0].strip()
          let (verOutput, verExitCode) = execCmdEx(nimBin & " --version")
          checkpoint(verOutput)
          check verExitCode == QuitSuccess
          check "Version " & expectedPrefix in verOutput
          break
      check verifiedVer
