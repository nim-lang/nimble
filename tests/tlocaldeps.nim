# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, osproc, strutils, strformat
import testscommon
from nimblepkg/common import cd
import nimblepkg/[options, config]

suite "project local deps mode":
  setup:
    # which messes up this test sometime
    delEnv("NIMBLE_DIR")

  test "NIMBLE_DIR set to nimbledeps uses global pkgcache (issue #1610)":
    ## When `nimble shell -l` runs, it sets NIMBLE_DIR to the local nimbledeps
    ## directory. A nested nimble process picks up NIMBLE_DIR and should still
    ## use the global pkgcache (~/.nimble/pkgcache), not nimbledeps/pkgcache.
    cd "localdeps":
      cleanDir("nimbledeps")
      createDir("nimbledeps")
      let nimbledepsAbs = expandFilename("nimbledeps")
      # Simulate what `nimble shell` does: set NIMBLE_DIR to nimbledeps
      putEnv("NIMBLE_DIR", nimbledepsAbs)
      defer: delEnv("NIMBLE_DIR")

      var options = initOptions()
      options.config = parseConfig()
      options.action = Action(typ: actionInstall)
      options.setNimbleDir()

      # nimbleDir should be the nimbledeps path (from NIMBLE_DIR env)
      check options.nimbleDir == nimbledepsAbs
      # pkgCachePath should use the GLOBAL config dir, not nimbledeps
      let globalPkgCache = expandTilde(options.config.nimbleDir).absolutePath() / "pkgcache"
      check options.pkgCachePath == globalPkgCache
      check options.pkgCachePath.find("nimbledeps") == -1

  test "nimbledeps exists":
    cd "localdeps":
      removeFile("localdeps")

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
