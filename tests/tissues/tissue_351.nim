discard """
  exitcode: 0
"""

import os, osproc, ../common
from nimblepkg/common import cd

cd "../binaryPackage/v2":
  let (output, exitCode) = execCmdEx(nimblePath &
                                    " c -r" &
                                    " -d:myVar=\"string with spaces\"" &
                                    " binaryPackage")
  doAssert exitCode == QuitSuccess, "build failed: " & output
