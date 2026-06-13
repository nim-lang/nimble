discard """
  exitcode: 0
"""

import os, strutils
import ../common
from nimblepkg/common import cd

cd "../issue1158":
  let (output, exitCode) = execNimble("--silent", "echoRequires")
  doAssert exitCode == QuitSuccess, output
  doAssert output.strip() == "@[\"nim >= 1.6.16\"]", output
