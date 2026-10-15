# Copyright (C) the Nimble contributors. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, strutils, os
import testscommon
from nimble import nimblePathsFileName
from nimblepkg/common import cd

proc printedPaths(output: string): string =
  ## The `getPathsClause()` the task printed, apart from nimble's own output
  ## (which names the packages it downloads).
  for line in output.splitLines:
    if line.startsWith("paths: "):
      return line

suite "nimble getPaths/getPathsClause":
  test "an unset environment variable produces no paths or compiler flags":
    cd "tasks/getpaths":
      verify execNimbleYes("checkEmptyPaths")

  test "a task gets its dependencies and its taskRequires":
    cd "tasks/getpaths":
      let (output, exitCode) = execNimbleYes("echoPaths")
      check exitCode == QuitSuccess
      let paths = output.printedPaths
      check paths.contains("--path:" & pkgsDir / "unittest2-")
      check paths.contains("--path:" & pkgsDir / "benchy-")
      # Running a task doesn't set the project up (#1617).
      check not fileExists(nimblePathsFileName)

  test "a task does not get another task's taskRequires":
    cd "tasks/getpaths":
      let (output, exitCode) = execNimbleYes("echoOtherPaths")
      check exitCode == QuitSuccess
      let paths = output.printedPaths
      check paths.contains("--path:" & pkgsDir / "unittest2-")
      check not paths.contains("benchy")

  test "a task brings an existing nimble.paths in line with its solve":
    # Nim takes the paths config.nims includes from nimble.paths over the
    # task's `--path`s, so one left by an earlier solve would win.
    cd "tasks/getpaths":
      writeFile(nimblePathsFileName, "--noNimblePath\n--path:\"/stale\"\n")
      defer: removeFile(nimblePathsFileName)
      let (_, exitCode) = execNimbleYes("echoPaths")
      check exitCode == QuitSuccess
      let paths = nimblePathsFileName.readFile
      check not paths.contains("/stale")
      check paths.contains("unittest2-")
      check paths.contains("benchy-")

      verify execNimbleYes("echoOtherPaths")
      let otherPaths = nimblePathsFileName.readFile
      check otherPaths.contains("unittest2-")
      check not otherPaths.contains("benchy-")

  test "compiler flags work for paths containing spaces":
    cdCleanDir(getTempDir() / "nimble getpaths with spaces"):
      createDir("source files")
      writeFile("source files" / "pathprobe.nim", "const answer* = 42\n")
      writeFile("check.nim", "import pathprobe\nstatic: doAssert answer == 42\n")
      writeFile("pathfixture.nimble", """
version = "0.1.0"
author = "test"
description = "Paths containing spaces"
license = "MIT"
srcDir = "source files"

task compilePaths, "":
  exec "nim c --hints:off --compileOnly --nimcache:nimcache " & getPathsClause() & " check.nim"
""")
      verify execNimbleYes("compilePaths")
      check not fileExists(nimblePathsFileName)
