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

  test "successful task exits with code 0":
    cd "tasks/exitcode":
      let (output, exitCode) = execNimble("ok")
      check output.contains("all good")
      check exitCode == QuitSuccess

  test "task exit code is propagated":
    cd "tasks/exitcode":
      let (_, exitCode) = execNimble("fail")
      check exitCode == 3

  test "failing exec in task produces non-zero exit code":
    cd "tasks/exitcode":
      let (_, exitCode) = execNimble("failexec")
      check exitCode != QuitSuccess
