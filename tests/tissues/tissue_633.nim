discard """
  exitcode: 0
"""

import os, strutils, ../common
from nimblepkg/common import cd

cd "../issue633":
  let (output, exitCode) = execNimble("testTask", "--testTask")
  doAssert exitCode == QuitSuccess, "testTask failed: " & output
  doAssert output.contains("Got it"), "should contain 'Got it'"
