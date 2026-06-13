discard """
  exitcode: 0
"""

import os, strutils
import ../common
from nimblepkg/common import cd

cd "../issue126/a":
  let (output, exitCode) = execNimbleYes("install")
  let lines = output.strip.processOutput()
  doAssert exitCode != QuitSuccess, output
  doAssert inLines(lines, "issue-126 is an invalid package name: cannot contain '-'"), output

cd "../issue126/b":
  let (output1, exitCode1) = execNimbleYes("install")
  let lines1 = output1.strip.processOutput()
  doAssert exitCode1 != QuitSuccess, output1
  doAssert inLines(lines1, "The .nimble file name must match name specified inside"), output1
