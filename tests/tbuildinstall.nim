# Tests for the vnext build/install refactor
# Tests that packages are built in a temp directory and only necessary files are installed

{.used.}

import unittest, os, strutils
import testscommon
from nimblepkg/common import cd

suite "Build/Install refactor":
  setup:
    # Clean up nimbleDir before each test
    removeDir(installDir)
    createDir(installDir)

  test "package with installDirs installs only whitelisted directories":
    cd "buildInstall/pkgWithInstallDirs":
      let (_, exitCode) = execNimbleYes("install")
      check exitCode == QuitSuccess

      # Find the installed package directory
      var installedDir = ""
      for kind, path in walkDir(pkgsDir):
        if kind == pcDir and "pkgWithInstallDirs" in path:
          installedDir = path
          break

      check installedDir.len > 0

      # Check that installDirs content is installed
      check dirExists(installedDir / "extra")
      check fileExists(installedDir / "extra" / "data.txt")

      # Check that the binary is installed
      check fileExists(installedDir / "pkgWithInstallDirs") or
            fileExists(installedDir / "pkgWithInstallDirs.exe")

      # Check that .nimble file is installed
      check fileExists(installedDir / "pkgWithInstallDirs.nimble")

  test "package with skipDirs does not install skipped directories":
    cd "buildInstall/pkgWithSkipDirs":
      let (_, exitCode) = execNimbleYes("install")
      check exitCode == QuitSuccess

      # Find the installed package directory
      var installedDir = ""
      for kind, path in walkDir(pkgsDir):
        if kind == pcDir and "pkgWithSkipDirs" in path:
          installedDir = path
          break

      check installedDir.len > 0

      # Check that skipDirs content is NOT installed
      check not dirExists(installedDir / "internal")

      # Check that tests/ is NOT installed (skipped by default)
      check not dirExists(installedDir / "tests")

      # Check that the binary is installed
      check fileExists(installedDir / "pkgWithSkipDirs") or
            fileExists(installedDir / "pkgWithSkipDirs.exe")

      # Check that srcDir content is installed
      check dirExists(installedDir / "src")
      check fileExists(installedDir / "src" / "pkgWithSkipDirs.nim")

  test "buildtemp directory is cleaned up after install":
    cd "buildInstall/pkgWithSkipDirs":
      let (_, exitCode) = execNimbleYes("install")
      check exitCode == QuitSuccess

      # Check that buildtemp is empty or doesn't exist
      let buildTempDir = installDir / "buildtemp"
      if dirExists(buildTempDir):
        var hasDirs = false
        for kind, path in walkDir(buildTempDir):
          hasDirs = true
          break
        check not hasDirs  # buildtemp should be empty

  test "installed binaries are executable":
    cd "buildInstall/pkgWithSkipDirs":
      let (_, exitCode) = execNimbleYes("install")
      check exitCode == QuitSuccess

      # Try to run the binary
      let (binOutput, binExitCode) = execBin("pkgWithSkipDirs")
      check binExitCode == QuitSuccess
      check "Hello from pkgWithSkipDirs!" in binOutput

  test "non-binary packages skip buildtemp":
    cd "buildInstall/pkgNoBinary":
      # Clean buildtemp before install
      let buildTempDir = installDir / "buildtemp"
      removeDir(buildTempDir)
      createDir(buildTempDir)

      let (_, exitCode) = execNimbleYes("install")
      check exitCode == QuitSuccess

      # Find the installed package directory
      var installedDir = ""
      for kind, path in walkDir(pkgsDir):
        if kind == pcDir and "pkgNoBinary" in path:
          installedDir = path
          break

      check installedDir.len > 0

      # Check that the package was installed correctly
      check dirExists(installedDir / "src")
      check fileExists(installedDir / "src" / "pkgNoBinary.nim")
      check fileExists(installedDir / "pkgNoBinary.nimble")

      # Check that buildtemp was NOT used (should still be empty)
      var buildTempUsed = false
      if dirExists(buildTempDir):
        for kind, path in walkDir(buildTempDir):
          buildTempUsed = true
          break
      check not buildTempUsed  # buildtemp should not have been used

  test "before-install hook runs for non-binary packages":
    cd "buildInstall/pkgWithHook":
      let (output, exitCode) = execNimbleYes("install")
      check exitCode == QuitSuccess

      # Check that the before-install hook was executed
      check "HOOK_EXECUTED: before-install hook ran successfully" in output

      # Check that the after-install hook was also executed
      check "HOOK_EXECUTED: after-install hook ran successfully" in output

      # Verify the package was installed correctly
      var installedDir = ""
      for kind, path in walkDir(pkgsDir):
        if kind == pcDir and "pkgWithHook" in path:
          installedDir = path
          break

      check installedDir.len > 0
      check dirExists(installedDir / "src")
      check fileExists(installedDir / "src" / "pkgWithHook.nim")
      check fileExists(installedDir / "pkgWithHook.nimble")
