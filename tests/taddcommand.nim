# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, strutils
import testscommon
from nimble import nimblePathsFileName, nimbleConfigFileName
from nimblepkg/common import cd
from nimblepkg/options import defaultLockFileName

const
  nimbleFileName = "addcommand.nimble"
  nimbleFileContent = """
# Package

version       = "0.1.0"
author        = "Nimble"
description   = "Fixture for the `nimble add` tests"
license       = "MIT"
"""

template withAddFixture(body: untyped) =
  ## Runs `body` in the fixture directory with a pristine nimble file and no
  ## leftover paths/config/lock files. The nimble file is restored afterwards
  ## because `nimble add` appends to it.
  cd "addcommand":
    usePackageListFile "../develop/packages.json":
      cleanFiles nimblePathsFileName, nimbleConfigFileName,
                 defaultLockFileName, ".gitignore"
      writeFile(nimbleFileName, nimbleFileContent)
      defer: writeFile(nimbleFileName, nimbleFileContent)
      body

suite "add command":
  cleanDir installDir

  test "nimble add updates the paths file when there is one (#1796)":
    withAddFixture:
      check execNimble("setup").exitCode == QuitSuccess
      check not nimblePathsFileName.readFile.contains("packagea")

      let (_, exitCode) = execNimbleYes("add", "packagea")
      check exitCode == QuitSuccess
      check nimbleFileName.readFile.contains("requires \"packagea")

      # The dependency has to be installed and reachable by the compiler.
      let pkgADir = getPackageDir(pkgsDir, "PackageA-")
      check pkgADir.len > 0
      check nimblePathsFileName.readFile.contains(pkgADir.escape)

  test "nimble add updates the lock file when there is one (#1796)":
    withAddFixture:
      check execNimble("lock").exitCode == QuitSuccess
      check not defaultLockFileName.readFile.contains("packagea")

      let (_, exitCode) = execNimbleYes("add", "packagea")
      check exitCode == QuitSuccess
      check defaultLockFileName.readFile.contains("packagea")

  test "nimble add does not create a paths or lock file on its own (#1796)":
    # Only projects already using them get them refreshed.
    withAddFixture:
      let (_, exitCode) = execNimbleYes("add", "packagea")
      check exitCode == QuitSuccess
      check not fileExists(nimblePathsFileName)
      check not fileExists(defaultLockFileName)
