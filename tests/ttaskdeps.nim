# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, strutils, os
import testscommon
import json
from nimblepkg/common import cd

template makeLockFile() =
  ## Makes lock file, cleans up after itself
  verify execNimble("lock")
  defer: removeFile("nimble.lock")

template inDir(body: untyped) =
  ## Runs code inside taskdeps folder
  cd "taskdeps/main/":
    body

suite "Task level dependencies":
  verify execNimbleYes("update")

  teardown:
    uninstallDeps()

  test "Can specify custom requirement for a task":
    inDir:
      verify execNimble("tasks")

  test "Dependency is used when running task":
    inDir:
      let (output, exitCode) = execNimble("benchmark")
      check exitCode == QuitSuccess
      check output.contains("benchy@0.0.1")
      check not output.contains("unittest2@0.0.4")

  test "Dependency is not used when not running task":
    inDir:
      let (output, exitCode) = execNimble("install")
      check exitCode == QuitSuccess
      check not output.contains("unittest2@0.0.4")
      check not output.contains("benchy@0.0.1")

  test "Dependency can be defined for test task":
    inDir:
      let (output, exitCode) = execNimble("test")
      check exitCode == QuitSuccess
      check output.contains("unittest2@0.0.4")

  test "Lock file has dependencies added to it":
    inDir:
      makeLockFile()
      # Check task level dependencies are in the lock file
      let json = parseFile("nimble.lock")
      check:
        "test" in json["packages"]
        "benchmark" in json["packages"]
      let pkgInfo = json["packages"]["test"]["unittest2"]
      check pkgInfo["version"].getStr() == "0.0.4"

  test "Task dependencies from lock file are used":
    inDir:
      makeLockFile()
      uninstallDeps()
      let (output, exitCode) = execNimble("test")
      check exitCode == QuitSuccess
      check not output.contains("benchy installed successfully")
      check output.contains("unittest2 installed successfully")


  test "Lock file doesn't install task dependencies":
    inDir:
      makeLockFile()
      # Uninstall the dependencies and see if nimble
      # tries to install them later
      uninstallDeps()

      let (output, exitCode) = execNimble("install")
      check exitCode == QuitSuccess
      check not output.contains("benchy installed successfully")
      check not output.contains("unittest2 installed successfully")

  test "Deps prints out all tasks dependencies":
    inDir:
      # Uninstall the dependencies fist to make sure deps command
      # still installs everything correctly
      uninstallDeps()
      let (output, exitCode) = execNimble("--format:json", "--silent", "deps")
      check exitCode == QuitSuccess
      let json = parseJson(output)

      var found = false
      for dependency in json:
        if dependency["name"].getStr() == "unittest2":
          found = true
      check found

  test "Develop file is used":
    inDir:
      defer:
        removeDir("nim-unittest2")
        removeFile("nimble.develop")

      verify execNimble("develop", "unittest2")
      # Add in a file to the develop file
      # We will then try and import this
      createDir "nim-unittest2/unittest2"
      "nim-unittest2/unittest2/customFile.nim".writeFile("")
      let (output, exitCode) = execNimble("-d:useDevelop", "test")
      check exitCode == QuitSuccess
      check "Using custom file" in output

  test "Dependencies aren't verified twice":
    inDir:
      let (output, _) = execNimble("test")
      check output.count("dependencies for unittest2@0.0.4") == 1

  test "Requirements for tasks in dependencies aren't used":
    cd "taskdeps/subdep/":
      let (output, _) = execNimbleYes("install")
      check "threading" notin output

    inDir:
      let (output, exitCode) = execNimble("test")
      check exitCode == QuitSuccess
      check "threading" notin output

  test "Error thrown when setting requirement for task that doesn't exist":
    cd "taskdeps/error/":
      let (output, exitCode) = execNimble("check")
      check exitCode == QuitFailure
      check "Task benchmark doesn't exist for requirement benchy == 0.0.1" in output

  test "Dump contains information":
    inDir:
      let (output, exitCode) = execNimble("dump")
      check exitCode == QuitSuccess
      check output.processOutput.inLines("benchmarkRequires: \"benchy 0.0.1\"")
      check output.processOutput.inLines("testRequires: \"unittest2 0.0.4\"")

  test "Lock files don't break":
    # Tests for regression caused by tasks deps.
    # nimlangserver is good candidate, has locks and quite a few dependencies
    let (_, exitCode) = execNimble("install", "nimlangserver@#19715af")
    check exitCode == QuitSuccess
