# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, osproc, strutils, strformat
import testscommon
from nimblepkg/common import cd

suite "project local deps mode":
  setup:
    # do this to prevent non-deterministic (random?) setting of the NIMBLE_DIR 
    # which messes up this test sometime
    delEnv("NIMBLE_DIR")

  test "nimbledeps exists":
    cd "localdeps":
      cleanDir("nimbledeps")
      createDir("nimbledeps")
      let (output, exitCode) = execCmdEx(nimblePath & " install -y")
      check exitCode == QuitSuccess
      check output.contains("project local deps mode")
      check output.contains("Succeeded")

  test "--localdeps flag":
    cd "localdeps":
      cleanDir("nimbledeps")
      let (output, exitCode) = execCmdEx(nimblePath & " install -y -l")
      check exitCode == QuitSuccess
      check output.contains("project local deps mode")
      check output.contains("Succeeded")

  test "localdeps develop":
    cleanDir("nimbledeps")
    cleanDir("packagea")
    let (_, exitCode) = execCmdEx(nimblePath &
      &" develop {pkgAUrl} --localdeps -y")
    discard execCmd("find packagea")
    check exitCode == QuitSuccess
    check dirExists("packagea" / "nimbledeps")
    check not dirExists("nimbledeps")
