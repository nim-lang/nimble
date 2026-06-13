discard """
  exitcode: 0
"""

import os, strutils, ../common
from nimblepkg/common import cd

cd "../testParams":
  let (output, exitCode) = execNimbleYes("test", "Passing test")
  doAssert exitCode == QuitSuccess, "test failed: " & output
  doAssert output.contains("Passing test"), "should contain 'Passing test'"
