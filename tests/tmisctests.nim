# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, osproc, strutils, strformat, sequtils
import testscommon
from nimblepkg/common import cd, nimbleVersion, nimblePackagesDirName

suite "misc tests":
  test "depsOnly + flag order test":
    let (output, exitCode) = execNimbleYes("--depsOnly", "install", pkgBin2Url)
    check(not output.contains("Success: packagebin2 installed successfully."))
    check exitCode == QuitSuccess

  test "caching of nims and ini detects changes":
    cd "caching":
      var (output, exitCode) = execNimble("dump")
      check output.contains("0.1.0")
      let
        nfile = "caching.nimble"
      writeFile(nfile, readFile(nfile).replace("0.1.0", "0.2.0"))
      (output, exitCode) = execNimble("dump")
      check output.contains("0.2.0")
      writeFile(nfile, readFile(nfile).replace("0.2.0", "0.1.0"))

      # Verify cached .nims runs project dir specific commands correctly
      (output, exitCode) = execNimble("testpath")
      check exitCode == QuitSuccess
      check output.contains("imported")
      check output.contains("tests/caching")
      check output.contains("copied")
      check output.contains("removed")

  test "tasks can be called recursively":
    cd "recursive":
      check execNimble("recurse").exitCode == QuitSuccess

  test "picks #head when looking for packages":
    removeDir installDir
    cd "versionClashes" / "aporiaScenario":
      let (output, exitCode) = execNimbleYes("install", "--verbose")
      checkpoint output
      check exitCode == QuitSuccess
      check execNimbleYes("remove", "aporiascenario").exitCode == QuitSuccess
      check execNimbleYes("remove", "packagea").exitCode == QuitSuccess

  test "pass options to the compiler with `nimble install`":
    cd "passNimFlags":
      let (_, exitCode) = execNimble("install", "--passNim:-d:passNimIsWorking")
      check exitCode == QuitSuccess

  test "install with --noRebuild flag":
    cleanDir(installDir)
    cd "run":
      check execNimbleYes("build").exitCode == QuitSuccess
      let (output, exitCode) = execNimbleYes("install", "--noRebuild")
      check exitCode == QuitSuccess
      check output.contains("Skipping") #TODO: This is not working as expected

  test "NimbleVersion is defined":
    cd "nimbleVersionDefine":
      let (output, exitCode) = execNimble("c", "-r", "src/nimbleVersionDefine.nim")
      check output.contains("0.1.0")
      check exitCode == QuitSuccess

      let (output2, exitCode2) = execNimble("run", "nimbleVersionDefine")
      check output2.contains("0.1.0")
      check exitCode2 == QuitSuccess

  test "compilation without warnings":
    const buildDir = "./buildDir/"
    const filesToBuild = [
      "../src/nimble.nim",
      #"../src/nimblepkg/nimscriptapi.nim",
      "./tester.nim",
      ]

    proc execBuild(fileName: string): tuple[output: string, exitCode: int] =
      result = execCmdEx(
        &"nim c -o:{buildDir/fileName.splitFile.name} {fileName}")

    proc checkOutput(output: string): uint =
      const warningsToCheck = [
        "[UnusedImport]",
        "[DuplicateModuleImport]",
        # "[Deprecated]", # todo fixme
        "[XDeclaredButNotUsed]",
        "[Spacing]",
        "[ProveInit]",
        # "[UnsafeDefault]", # todo fixme
        ]

      for line in output.splitLines():
        for warning in warningsToCheck:
          if line.find(warning) != stringNotFound:
            once: checkpoint("Detected warnings:")
            checkpoint(line)
            inc(result)

    removeDir(buildDir)

    var linesWithWarningsCount: uint = 0
    for file in filesToBuild:
      let (output, exitCode) = execBuild(file)
      check exitCode == QuitSuccess
      linesWithWarningsCount += checkOutput(output)
    check linesWithWarningsCount == 0

  test "can update":
    check execNimble("update").exitCode == QuitSuccess

  test "can list":
    check execNimble("list").exitCode == QuitSuccess
    check execNimble("list", "-i").exitCode == QuitSuccess

  test "should not install submodules when --ignoreSubmodules flag is on":
    cleanDir(installDir)
    let (_, exitCode) = execNimble("--ignoreSubmodules", "install", "https://github.com/jmgomez/submodule_package")
    check exitCode == QuitFailure

  test "should install submodules when --ignoreSubmodules flag is off":
    cleanDir(installDir)
    let (_, exitCode) = execNimble("install", "https://github.com/jmgomez/submodule_package")
    check exitCode == QuitSuccess
  
  test "config file should end with a newline":
    let configFile = readFile("../config.nims")
    let content = configFile.splitLines.toSeq()
    check content[^2].strip() == ""
    check content[^1].strip() == ""

  test "recovers from corrupted pkgcache":
    # This test verifies that nimble can recover when a pkgcache directory exists
    # but is corrupted (has no .nimble/.babel file). This can happen due to:
    # - Interrupted downloads
    # - File system corruption
    # - Concurrent nimble processes

    cleanDir(installDir)

    # First install to populate the cache
    let (_, exitCode1) = execNimbleYes("install", pkgAUrl)
    check exitCode1 == QuitSuccess

    let pkgCacheDir = installDir / "pkgcache"

    # Find the cache directory that will be used for installation
    var corruptedDir = ""
    for kind, path in walkDir(pkgCacheDir):
      let dirName = path.extractFilename.toLowerAscii
      if kind == pcDir and "packagea" in dirName and dirName.endsWith("git"):
        corruptedDir = path
        break
    check corruptedDir != ""

    # Corrupt the cache directory by removing all files except .git
    for kind, path in walkDir(corruptedDir):
      if kind == pcFile:
        removeFile(path)
      elif kind == pcDir and not path.endsWith(".git"):
        removeDir(path)

    # Verify corruption (no .nimble or .babel file)
    var hasNimbleFile = false
    for file in walkFiles(corruptedDir / "*.nimble"):
      hasNimbleFile = true
    for file in walkFiles(corruptedDir / "*.babel"):
      hasNimbleFile = true
    check not hasNimbleFile

    # Remove the installed package so nimble needs to use the cache
    for kind, path in walkDir(installDir / "pkgs2"):
      if kind == pcDir and "packagea" in path.toLowerAscii:
        removeDir(path)

    # Install again - should either show "corrupted" (with fix) or "Downloading" (recovery)
    let (output, exitCode2) = execNimbleYes("install", pkgAUrl)
    check exitCode2 == QuitSuccess
    # The test passes if either:
    # - With fix: shows "corrupted" warning and re-downloads
    # - Without fix but SAT recovery: shows "Downloading"
    check output.contains("corrupted") or output.contains("Downloading")

  test "friendly error when running command without nimble file":
    # Commands like build, test, run should show a friendly error message
    # when run in a directory without a .nimble file, instead of an assertion failure
    let testDir = getTempDir() / "no_nimble_file_test"
    if dirExists(testDir):
      removeDir(testDir)
    createDir(testDir)

    cd testDir:
      # Test various commands that require a nimble file
      for cmd in ["build", "run", "test"]:
        let (output, exitCode) = execNimble(cmd)
        check exitCode != QuitSuccess
        # Should show a friendly error message, not an assertion failure
        check output.contains("Could not find a .nimble file")
        check not output.contains("AssertionDefect")

    removeDir(testDir)

  test "re-downloads when cached version doesn't match requested":
    # Simulates a stale pkgcache: the cache directory has a nimble file
    # but with a version that doesn't match the requested version range.
    # This can happen when a previous nimble version or version discovery
    # leaves a wrong checkout in the cache directory.

    cleanDir(installDir)

    # First install packagea@0.2 to populate the cache
    let (_, exitCode1) = execNimbleYes("install", pkgAUrl & "@0.2")
    check exitCode1 == QuitSuccess

    let pkgCacheDir = installDir / "pkgcache"

    # Find the version-specific cache directory for packagea
    # (the one with a version suffix, not the verAny discovery dir)
    var cacheDir = ""
    for kind, path in walkDir(pkgCacheDir):
      let dirName = path.extractFilename.toLowerAscii
      if kind == pcDir and "packagea" in dirName:
        if cacheDir == "" or dirName.len > cacheDir.extractFilename.len:
          # The version-specific dir has a longer name (includes version suffix)
          cacheDir = path

    check cacheDir != ""

    # Modify the cached nimble/babel file to declare a version below the requested range
    var nimbleFile = ""
    for file in walkFiles(cacheDir / "*.nimble"):
      nimbleFile = file
      break
    if nimbleFile == "":
      for file in walkFiles(cacheDir / "*.babel"):
        nimbleFile = file
        break
    check nimbleFile != ""

    writeFile(nimbleFile,
      "version = \"0.0.1\"\nauthor = \"test\"\ndescription = \"test\"\nlicense = \"MIT\"\n")

    # Remove installed packages so nimble needs to re-use cache
    removeDir(installDir / "pkgs2")
    createDir(installDir / "pkgs2")

    # Install again - should detect version mismatch and re-download
    let (output2, exitCode2) = execNimbleYes("install", pkgAUrl & "@0.2")
    check exitCode2 == QuitSuccess
    check output2.contains("re-downloading")

  test "depsOnly installs dependencies but not root package (vnext)":
    # Regression test for https://github.com/nim-lang/nimble/issues/1598
    # In vnext mode, --depsOnly was ignored and the root package was installed.
    let testDir = getTempDir() / "nimble_test_depsonly"
    removeDir(testDir)
    createDir(testDir)

    writeFile(testDir / "tester.nimble", """
version = "0.1.0"
author = "test"
description = "test"
license = "MIT"
srcDir = "."
bin = @["tester"]

requires "nim >= 2.0.0", "jsony"
""")
    writeFile(testDir / "tester.nim", """
echo "hello"
""")

    cleanDir(installDir)
    cd testDir:
      let (output, exitCode) = execNimbleYes("install", "--depsOnly")
      check exitCode == QuitSuccess
      # jsony (dependency) should be installed
      check output.contains("jsony")
      # root package should NOT be installed
      check not output.contains("tester installed successfully")

    removeDir(testDir)
