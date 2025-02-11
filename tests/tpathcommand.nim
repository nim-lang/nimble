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
  
  test "respects version constraint":
    cd "develop/srcdirtest":
      let (_, exitCode) = execNimbleYes("install")
      check exitCode == QuitSuccess
    check execNimble("path", "srcdirtest@1.0").exitCode == QuitSuccess
    check execNimble("path", "srcdirtest@2.0").exitCode != QuitSuccess

  test "Use current nimble package to determine path when possible":
    cd "deps":
      check execNimbleYes("install").exitCode == QuitSuccess
      let (output, exitCode) = execNimble("path", "timezones")
      check(exitCode == QuitSuccess)
      check output.strip() == getPackageDir(pkgsDir, "timezones-0.5.4")

  test "Respect develop overrides for nimble packages":
    cd "pathWithDevelop":
      let (output, exitCode) = execNimble("path", "deps")
      check(exitCode == QuitSuccess)
      checkpoint "Nimble path output was: " & output
      check output.startsWith(expandFilename("../deps"))
