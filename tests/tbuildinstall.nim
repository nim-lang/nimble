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
      # Use --verbose to see buildtemp messages
      let (output, exitCode) = execNimbleYes("--verbose", "install")
      check exitCode == QuitSuccess

      # Verify buildtemp was NOT used
      check "Using buildtemp for pkgNoBinary" notin output

      # Find the installed package directory
      var installedDir = ""
      for kind, path in walkDir(pkgsDir):
        if kind == pcDir and "pkgNoBinary" in path:
          installedDir = path
          break

      check installedDir.len > 0
      check dirExists(installedDir / "src")
      check fileExists(installedDir / "src" / "pkgNoBinary.nim")
      check fileExists(installedDir / "pkgNoBinary.nimble")

  test "before-install hook uses buildtemp":
    cd "buildInstall/pkgWithHook":
      # Use --verbose to see buildtemp messages
      let (output, exitCode) = execNimbleYes("--verbose", "install")
      check exitCode == QuitSuccess

      # Verify buildtemp was used (verbose message)
      check "Using buildtemp for pkgWithHook" in output
      check "before-install hook: true" in output

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

  test "after-install-only hook skips buildtemp":
    cd "buildInstall/pkgWithAfterHookOnly":
      # Use --verbose to see buildtemp messages
      let (output, exitCode) = execNimbleYes("--verbose", "install")
      check exitCode == QuitSuccess

      # Verify buildtemp was NOT used (no before-install hook)
      check "Using buildtemp for pkgWithAfterHookOnly" notin output

      # Check that the after-install hook was executed
      check "HOOK_EXECUTED: after-install hook ran successfully" in output

      # Find the installed package directory
      var installedDir = ""
      for kind, path in walkDir(pkgsDir):
        if kind == pcDir and "pkgWithAfterHookOnly" in path:
          installedDir = path
          break

      check installedDir.len > 0
      check dirExists(installedDir / "src")
      check fileExists(installedDir / "src" / "pkgWithAfterHookOnly.nim")
      check fileExists(installedDir / "pkgWithAfterHookOnly.nimble")

  test "conditional before-install hook uses buildtemp":
    cd "buildInstall/pkgWithConditionalHook":
      # Use --verbose to see buildtemp messages
      let (output, exitCode) = execNimbleYes("--verbose", "install")
      check exitCode == QuitSuccess

      # Verify buildtemp was used (declarative parser detected the hook in when block)
      check "Using buildtemp for pkgWithConditionalHook" in output
      check "before-install hook: true" in output

      # Check that the conditional before-install hook was executed
      check "HOOK_EXECUTED: conditional before-install hook ran successfully" in output
      # Check that the after-install hook was also executed
      check "HOOK_EXECUTED: after-install hook ran successfully" in output

      # Verify the package was installed correctly
      var installedDir = ""
      for kind, path in walkDir(pkgsDir):
        if kind == pcDir and "pkgWithConditionalHook" in path:
          installedDir = path
          break

      check installedDir.len > 0
      check dirExists(installedDir / "src")
      check fileExists(installedDir / "src" / "pkgWithConditionalHook.nim")
      check fileExists(installedDir / "pkgWithConditionalHook.nimble")

  test "binary packages use buildtemp":
    cd "buildInstall/pkgWithSkipDirs":
      # Use --verbose to see buildtemp messages
      let (output, exitCode) = execNimbleYes("--verbose", "install")
      check exitCode == QuitSuccess

      # Verify buildtemp was used for binary package
      check "Using buildtemp for pkgWithSkipDirs" in output
      check "binaries: true" in output

  test "special versions do not have # in directory names":
    # Install a package with an explicit special version (#head)
    # This test verifies our fix strips # from directory names
    let (_, exitCode) = execNimbleYes("install", "https://github.com/nimble-test/packagebin2.git@#head")
    check exitCode == QuitSuccess

    proc checkNoPoundInDirs(baseDir: string): bool =
      if not dirExists(baseDir):
        return true
      for kind, path in walkDir(baseDir):
        if '#' in path:
          echo "Found # in path: ", path
          return false
        if kind == pcDir:
          if not checkNoPoundInDirs(path):
            return false
      return true

    let pkgCacheDir = installDir / "pkgcache"
    check checkNoPoundInDirs(pkgCacheDir)

    let buildTempDir = installDir / "buildtemp"
    check checkNoPoundInDirs(buildTempDir)

    check checkNoPoundInDirs(pkgsDir)

    # Verify a package was installed and no directory contains '#'
    var foundPackage = false
    for kind, path in walkDir(pkgsDir):
      if kind == pcDir and "packagebin2" in path.toLowerAscii:
        foundPackage = true
        check '#' notin path
        break
    check foundPackage
