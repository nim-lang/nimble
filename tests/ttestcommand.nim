# Copyright (C) the Nimble contributors. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, strutils
import std/tempfiles
import testscommon
from nimblepkg/common import cd

suite "test command":
  test "custom tasks and build hooks use the requested features":
    let projectDir = createTempDir("nimble-feature-hooks-", "")
    defer: removeDir(projectDir)
    cd projectDir:
      let nimbleDir = "--nimbleDir:" & (projectDir / "cache")
      writeFile("featurehooks.nimble", """
version = "0.1.0"
author = "Test"
description = "Feature selection in tasks and hooks"
license = "MIT"
bin = @["featurehooks"]
feature "foo":
  requires "nim"
feature "bar":
  requires "https://github.com/arnetheduck/nim-results == 0.4.0"
before build:
  doAssert defined(features.featurehooks.foo) xor defined(features.featurehooks.bar)
  when defined(features.featurehooks.bar):
    exec "nim c --compileOnly probe.nim"
  else:
    exec "nim c --compileOnly freshprobe.nim"
after build:
  doAssert defined(features.featurehooks.foo) xor defined(features.featurehooks.bar)
task test, "Compile a probe":
  exec "nim c --compileOnly probe.nim"
""")
      let fooProbe = """
static:
  doAssert defined(features.featurehooks.foo)
  doAssert not defined(features.featurehooks.bar)
"""
      writeFile("probe.nim", fooProbe)
      writeFile("freshprobe.nim", fooProbe)
      writeFile("featurehooks.nim", fooProbe)
      verify execNimble(nimbleDir, "--useSystemNim", "--features:foo", "test")
      verify execNimble(nimbleDir, "--useSystemNim", "--features:foo", "build")
      check not fileExists("nimble.paths")

      verify execNimble(nimbleDir, "--useSystemNim", "--features:foo", "setup")
      let savedPaths = readFile("nimble.paths")
      let barProbe = """
import results
static:
  doAssert defined(features.featurehooks.bar)
  doAssert not defined(features.featurehooks.foo)
  doAssert Result[int, string].default.isErr
"""
      writeFile("probe.nim", barProbe)
      writeFile("featurehooks.nim", barProbe)
      # Build first so the dependency is installed during this invocation.
      verify execNimbleYes(nimbleDir, "--useSystemNim", "--features:bar", "build")
      verify execNimble(nimbleDir, "--useSystemNim", "--features:bar", "test")
      check readFile("nimble.paths") == savedPaths

  test "build hooks use current features with generated and legacy paths files":
    let projectDir = createTempDir("nimble-generated-features-", "")
    defer: removeDir(projectDir)
    cd projectDir:
      writeFile("generatedfeatures.nimble", """
version = "0.1.0"
author = "Test"
description = "Build hooks with a pre-existing paths file"
license = "MIT"
bin = @["generatedfeatures"]
feature "foo":
  requires "nim"
feature "bar":
  requires "nim"
before build:
  exec "nim c -r probe.nim"
after build:
  exec "nim c -r probe.nim"
""")
      let checkFeatures = """
static:
  let expected = staticRead("expected-feature")
  doAssert defined(features.generatedfeatures.foo) == (expected == "foo")
  doAssert defined(features.generatedfeatures.bar) == (expected == "bar")
"""
      writeFile("generatedfeatures.nim", checkFeatures)
      writeFile("probe.nim", checkFeatures & """
when defined(posix):
  import std/[os, strutils]
  let wrapperDir = getEnv("PATH").split(PathSep)[0]
  doAssert getFilePermissions(wrapperDir) == {fpUserRead, fpUserWrite, fpUserExec}
  writeFile("wrapper-dir", wrapperDir)
""")
      writeFile("seed.nim", "discard")
      verify execNimble("--useSystemNim", "--features:foo", "c", "seed.nim")
      let generatedPaths = readFile("nimble.paths")
      check generatedPaths.contains("--define:\"features.generatedfeatures.foo\"")

      writeFile("expected-feature", "bar")
      verify execNimble("--useSystemNim", "--features:bar", "build")
      when defined(posix):
        check not dirExists(readFile("wrapper-dir"))

      writeFile("expected-feature", "none")
      verify execNimble("--useSystemNim", "build")
      check readFile("nimble.paths") == generatedPaths

      let legacyPaths = "--noNimblePath\n--path:" & projectDir.escape & "\n"
      writeFile("nimble.paths", legacyPaths)
      writeFile("expected-feature", "bar")
      verify execNimble("--useSystemNim", "--features:bar", "build")
      check readFile("nimble.paths") == legacyPaths

  test "fresh custom tasks forward features selected by dependencies":
    let projectDir = createTempDir("nimble-task-dep-feature-", "")
    defer: removeDir(projectDir)
    cd projectDir:
      createDir("reviewoptdep")
      writeFile("reviewoptdep" / "reviewoptdep.nimble", """
version = "0.1.0"
author = "Test"
description = "A dependency with an optional feature"
license = "MIT"
feature "on":
  requires "nim"
""")
      writeFile("reviewoptdep" / "reviewoptdep.nim", """
const optFeature* = defined(features.reviewoptdep.on)
""")
      writeFile("featuretask.nimble", """
version = "0.1.0"
author = "Test"
description = "Uses a dependency feature in a custom test"
license = "MIT"
requires "file://./reviewoptdep[on]"
task test, "Compile a probe":
  doAssert defined(features.reviewoptdep.on)
  exec "nim c --compileOnly probe.nim"
""")
      writeFile("probe.nim", """
import reviewoptdep
static:
  doAssert optFeature
""")
      verify execNimble("--useSystemNim", "test")
      check not fileExists("nimble.paths")

  test "nested Nimble commands preserve task PATH changes":
    let projectDir = createTempDir("nimble-task-path-", "")
    defer: removeDir(projectDir)
    cd projectDir:
      createDir("tools")
      let nimbleDir = "--nimbleDir:" & (projectDir / "cache")
      writeFile("nestedfeature.nimble", """
import std/[os, strutils]
version = "0.1.0"
author = "Test"
description = "Changes PATH before running another task"
license = "MIT"
feature "foo":
  requires "nim"
task outer, "Run a nested Nimble command":
  doAssert defined(features.nestedfeature.foo)
  let tools = thisDir() / "tools"
  putEnv("PATH", tools & PathSep & getEnv("PATH"))
  exec getEnv("NIMBLE_TEST_BINARY_PATH").quoteShell & " --useSystemNim --global " &
    $1 & " inner"
task inner, "Check the inherited environment":
  doAssert (thisDir() / "tools") in getEnv("PATH").split(PathSep)
  exec "nim c --compileOnly probe.nim"
""" % nimbleDir.quoteShell.escape)
      writeFile("probe.nim", """
static:
  doAssert not defined(features.nestedfeature.foo)
""")
      verify execNimble(nimbleDir, "--useSystemNim", "--features:foo", "outer")

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
proc checkFeatures() =
  let expected = system.readFile("expected-feature")
  doAssert defined(features.featuretest.foo) == (expected == "foo")
  doAssert defined(features.featuretest.bar) == (expected == "bar")
  exec "nim c --compileOnly tests/tfeatures.nim"
before test:
  checkFeatures()
after test:
  checkFeatures()
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
      writeFile("expected-feature", "foo")
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
      writeFile("expected-feature", "bar")
      verify execNimble("--useSystemNim", "--features:bar", "test")
      check readFile("nimble.paths") == savedPaths

      writeFile(featureTest, noFeatures)
      writeFile("expected-feature", "none")
      verify execNimble("--useSystemNim", "--features", "test")
      check readFile("nimble.paths") == savedPaths

      writeFile(featureTest, fooEnabled)
      writeFile("expected-feature", "foo")
      verify execNimble("--useSystemNim", "test")

      verify execNimble("--useSystemNim", "setup")
      writeFile(featureTest, noFeatures)
      writeFile("expected-feature", "none")
      verify execNimble("--useSystemNim", "test")

      writeFile(featureTest, fooEnabled)
      writeFile("expected-feature", "foo")
      verify execNimble("--useSystemNim", "--local", "--features:foo", "test")

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
