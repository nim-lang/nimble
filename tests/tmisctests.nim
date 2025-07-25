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
