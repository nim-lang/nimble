# Copyright (C) the Nimble contributors. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os
import std/tempfiles
import testscommon
from nimblepkg/common import cd

suite "test command":
  test "setup saves default features for tests and builds":
    let projectDir = createTempDir("nimble-test-features-", "")
    defer: removeDir(projectDir)
    cd projectDir:
      writeFile("featuretest.nimble", """
version = "0.1.0"
author = "Test"
description = "Tests feature defines in the built-in test runner"
license = "MIT"
bin = @["featuretest"]
feature "foo":
  requires "nim"
feature "bar":
  requires "nim"
""")
      createDir("tests")
      let
        featureTest = "tests" / "tfeatures.nim"
        fooEnabled = """
static:
  doAssert defined(features.featuretest.foo)
  doAssert not defined(features.featuretest.bar)
"""
        noFeatures = """
static:
  doAssert not defined(features.featuretest.foo)
  doAssert not defined(features.featuretest.bar)
"""
      writeFile(featureTest, fooEnabled)
      verify execNimble("--useSystemNim", "--features:foo", "test")
      check not fileExists("nimble.paths")

      verify execNimble("--useSystemNim", "--features:foo", "setup")
      verify execNimble("--useSystemNim", "test")
      writeFile("featuretest.nim", fooEnabled)
      verify execNimble("--useSystemNim", "build")

      let savedPaths = readFile("nimble.paths")
      writeFile(featureTest, """
static:
  doAssert defined(features.featuretest.bar)
  doAssert not defined(features.featuretest.foo)
""")
      verify execNimble("--useSystemNim", "--features:bar", "test")
      check readFile("nimble.paths") == savedPaths

      writeFile(featureTest, noFeatures)
      verify execNimble("--useSystemNim", "--features", "test")
      check readFile("nimble.paths") == savedPaths

      writeFile(featureTest, fooEnabled)
      verify execNimble("--useSystemNim", "test")

      verify execNimble("--useSystemNim", "setup")
      writeFile(featureTest, noFeatures)
      verify execNimble("--useSystemNim", "test")

  test "Runs passing unit tests":
    cd "testCommand/testsPass":
      # Pass flags to test #726, #757
      let (outp, exitCode) = execNimble("test", "-d:CUSTOM")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("First test")
      check outp.processOutput.inLines("Second test")
      check outp.processOutput.inLines("Third test")
      check outp.processOutput.inLines("Executing my func")

  test "Runs failing unit tests":
    cd "testCommand/testsFail":
      let (outp, exitCode) = execNimble("test")
      check exitCode == QuitFailure
      check outp.processOutput.inLines("First test")
      check outp.processOutput.inLines("Failing Second test")
      check(not outp.processOutput.inLines("Third test"))

  test "Continues after a failed test and returns failure":
    cd "testCommand/testsFail":
      let (outp, exitCode) = execNimble("test", "-c")
      check exitCode == QuitFailure
      check outp.processOutput.inLines("First test")
      check outp.processOutput.inLines("Failing Second test")
      check outp.processOutput.inLines("Third test")
      check outp.processOutput.inLines("Only 2/3 tests files passed")

  test "test command can be overridden":
    cd "testCommand/testOverride":
      let (outp, exitCode) = execNimble("-d:CUSTOM", "test", "--runflag")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("overridden")
      check outp.processOutput.inLines("true")

  test "certain files are ignored":
    cd "testCommand/testsIgnore":
      let (outp, exitCode) = execNimble("test")
      check exitCode == QuitSuccess
      check(not outp.processOutput.inLines("Should be ignored"))
      check outp.processOutput.inLines("First test")

  test "CWD is root of package":
    cd "testCommand/testsCWD":
      let (outp, exitCode) = execNimble("test")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines(getCurrentDir())
