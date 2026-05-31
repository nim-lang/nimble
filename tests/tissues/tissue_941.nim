discard """
  exitcode: 0
"""

import os, strutils, ../common
from nimblepkg/common import cd

cd "../issue941":
  let (output, exitCode) = execNimble("dump")
  doAssert exitCode == QuitSuccess, "dump failed: " & output
  const expectedBinaryName =
    when defined(windows):
      "issue941.dll"
    else:
      "libissue941.so"
  doAssert output.contains(expectedBinaryName), "should contain " & expectedBinaryName
