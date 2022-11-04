# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, strutils, os
import testscommon
from nimblepkg/common import cd

suite "nimble tasks":
  test "can list tasks even with no tasks defined in nimble file":
    cd "tasks/empty":
      let (_, exitCode) = execNimble("tasks")
      check exitCode == QuitSuccess

  test "tasks with no descriptions are correctly displayed":
    cd "tasks/nodesc":
      let (output, exitCode) = execNimble("tasks")
      check output.contains("nodesc")
      check exitCode == QuitSuccess

  test "task descriptions are correctly aligned to longer name":
    cd "tasks/max":
      let (output, exitCode) = execNimble("tasks")
      check output.contains("task1           Description1")
      check output.contains("very_long_task  This is a task with a long name")
      check output.contains("aaa             A task with a small name")
      check exitCode == QuitSuccess

  test "task descriptions are correctly aligned to minimum (10 chars)":
    cd "tasks/min":
      let (output, exitCode) = execNimble("tasks")
      check output.contains("a         Description for a")
      check exitCode == QuitSuccess


  test "Can specify custom requirement for a task":
    cd "tasks/dependencies":
      let (output, exitCode) = execNimble("tasks")
      check exitCode == QuitSuccess

  test "Dependency is used when running task":
    cd "tasks/dependencies":
      let (output, exitCode) = execNimble("a")
      check exitCode == QuitSuccess
      check output.contains("dependencies for unittest2@0.0.4")

  test "Dependency is not used when not running task":
    cd "tasks/dependencies":
      let (output, exitCode) = execNimble("install")
      check exitCode == QuitSuccess
      check not output.contains("dependencies for unittest2@0.0.4")
