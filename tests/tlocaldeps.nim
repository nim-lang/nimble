# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, osproc, strformat
import testscommon
from nimblepkg/common import cd
import nimblepkg/options

suite "project local deps mode":
  setup:
    # do this to prevent non-deterministic (random?) setting of the NIMBLE_DIR 
    # which messes up this test sometime
    delEnv("NIMBLE_DIR")

  test "nimbledeps exists":
    cd "localdeps":
      removeFile("localdeps")
      cleanDir("nimbledeps")
      # TEMPORARY: Added for global-by-default. To revert to local-by-default, remove this createDir line:
      createDir("nimbledeps")
      let (_, exitCode) = execCmdEx(nimblePath & " install -y")
      check exitCode == QuitSuccess
      check dirExists("nimbledeps")

  test "--localdeps flag":
    cd "localdeps":
      removeFile("localdeps")
      cleanDir("nimbledeps")
      let (_, exitCode) = execCmdEx(nimblePath & " install -y -l")
      check exitCode == QuitSuccess
      check dirExists("nimbledeps")

  test "localdeps develop":
    cleanDir("nimbledeps")
    cleanDir(defaultDevelopPath)
    let (_, exitCode) = execCmdEx(nimblePath &
      &" develop {pkgAUrl} --localdeps -y")
    check exitCode == QuitSuccess
    check dirExists(defaultDevelopPath / "packagea" / "nimbledeps")
    check not dirExists("nimbledeps")
