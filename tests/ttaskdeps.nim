# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import unittest, strutils, os
import testscommon
import json
from nimblepkg/common import cd

suite "Task level dependencies":
  test "Can specify custom requirement for a task":
    cd "taskdeps/dependencies":
      let (output, exitCode) = execNimble("tasks")
      check exitCode == QuitSuccess

  test "Dependency is used when running task":
    cd "taskdeps/dependencies":
      let (output, exitCode) = execNimble("a")
      check exitCode == QuitSuccess
      check output.contains("dependencies for unittest2@0.0.4")

  test "Dependency is not used when not running task":
    cd "taskdeps/dependencies":
      let (output, exitCode) = execNimble("install")
      check exitCode == QuitSuccess
      check not output.contains("dependencies for unittest2@0.0.4")

  test "Dependency can be defined for test task":
    cd "taskdeps/test":
      let (output, exitCode) = execNimble("test")
      check exitCode == QuitSuccess
      check output.contains("dependencies for unittest2@0.0.4")

  test "Lock file has dependencies added to it":
    cd "taskdeps/dependencies":
      removeFile("nimble.lock")
      let (_, exitCode) = execNimble("lock")
      check exitCode == QuitSuccess
      # Check task level dependencies are in the lock file
      let json = parseFile("nimble.lock")
      check "unittest2" in json["packages"]
      let pkgInfo = json["packages"]["unittest2"]
      check pkgInfo["version"].getStr() == "0.0.4"

  test "Deps prints out all tasks":
    cd "taskdeps/dependencies":
      let (output, exitCode) = execNimble("--format:json", "deps")
      check exitCode == QuitSuccess
      let json = parseJson(output)

      var found = false
      for dependency in json:
        if dependency["name"].getStr() == "unittest2":
          found = true
      check found
