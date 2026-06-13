# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

discard """
  exitcode: 0
"""

import os, osproc, strutils, common
from nimblepkg/common import cd

cd "deps":
  let (output, exitCode) = execCmdEx(nimblePath & " --silent deps -y")
  doAssert exitCode == QuitSuccess, output
  doAssert output.contains("deps (@0.1.0)"), output
  doAssert output.contains("timezones 0.5.4 (@0.5.4)"), output
