{.used.}
import unittest
import nimblepkg/[options, downloadnim, version, nimblesat]
import std/[os, options]

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

  test "can download and unzip a version. Should also compile it if the prebinaries are not available for the current platform":
    var options = initOptions()
    let version = newVersion("2.0.4")
    let extractDir = downloadAndExtractNim(version, options)
    check extractDir.isSome
    check fileExists(extractDir.get / "bin" / "nim".addFileExt(ExeExt))


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

#Next steps:
# - Install a package and test that the binary exists after the installation
#   - Flag to opt-out 
#   - Install deps as submodules
#   - Windows 
#   - Clean up downloadnim
#   - Test that it only enters one per nim non special version in collectAllVersions
#   - Full integration test