# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, strutils
import testscommon
from nimblepkg/common import cd

suite "path command":
  test "can get correct path for srcDir (#531)":
    cd "develop/srcdirtest":
      let (_, exitCode) = execNimbleYes("install")
      check exitCode == QuitSuccess
    let (output, _) = execNimble("path", "srcdirtest")
    let packageDir = getPackageDir(pkgsDir, "srcdirtest-1.0")
    check output.strip() == packageDir

  # test "nimble path points to develop":
  #   cd "develop/srcdirtest":
  #     var (output, exitCode) = execNimble("develop")
  #     checkpoint output
  #     check exitCode == QuitSuccess

  #     (output, exitCode) = execNimble("path", "srcdirtest")

  #     checkpoint output
  #     check exitCode == QuitSuccess
  #     check output.strip() == getCurrentDir() / "src"
