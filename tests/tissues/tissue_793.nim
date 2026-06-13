discard """
  exitcode: 0
"""

import os, strutils, ../common
from nimblepkg/common import cd

cd "../issue793":
  var (output, exitCode) = execNimble("build")
  doAssert exitCode == QuitSuccess, "build failed: " & output
  doAssert output.contains("before build"), "should contain 'before build'"
  doAssert output.contains("after build"), "should contain 'after build'"

  # Issue 776
  (output, exitCode) = execNimble("doc", "src/issue793")
  doAssert exitCode == QuitSuccess, "doc failed: " & output
  doAssert output.contains("before doc"), "should contain 'before doc'"
  doAssert output.contains("after doc"), "should contain 'after doc'"
