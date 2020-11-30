# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, strutils
import testscommon

suite "multi":
  test "can install package from git subdir":
    var
      args = @["install", pkgMultiAlphaUrl]
      (output, exitCode) = execNimbleYes(args)
    check exitCode == QuitSuccess

    # Issue 785
    args.add @[pkgMultiBetaUrl, "-n"]
    (output, exitCode) = execNimble(args)
    check exitCode == QuitSuccess
    check output.contains("forced no")
    check output.contains("beta installed successfully")

  test "can develop package from git subdir":
    cleanDir "beta"
    check execNimbleYes("develop", pkgMultiBetaUrl).exitCode == QuitSuccess
