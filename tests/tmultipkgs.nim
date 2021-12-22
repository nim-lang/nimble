# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os
import testscommon

from nimblepkg/common import nimblePackagesDirName
from nimblepkg/version import newVRAny
from nimblepkg/displaymessages import pkgDepsAlreadySatisfiedMsg
from nimblepkg/tools import getNameVersionChecksum

template installAlpha =
  cleanDir installDir
  var args {.inject.} = @["install", pkgMultiAlphaUrl]
  let (output, exitCode) = execNimbleYes(args)
  check exitCode == QuitSuccess
  check output.processOutput.inLines("alpha installed successfully")

suite "multi":
  test "can install package from git subdir":
    installAlpha()

  test "do not replace a package if already installed":
    installAlpha()
    args.add pkgMultiBetaUrl
    let (output, exitCode) = execNimbleYes(args)
    check exitCode == QuitSuccess
    var lines = output.processOutput
    for _,  dir in walkDir(installDir / nimblePackagesDirName):
      let (name, _, _) = getNameVersionChecksum(dir)
      if name != "alpha": continue
      check lines.inLinesOrdered(
        pkgDepsAlreadySatisfiedMsg((name: name, ver: newVRAny())))
      break
    check lines.inLinesOrdered("beta installed successfully")

  test "can develop package from git subdir":
    cleanDir "beta"
    check execNimbleYes("develop", pkgMultiBetaUrl).exitCode == QuitSuccess
