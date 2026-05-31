discard """
  exitcode: 0
"""

import os, ../common
from nimblepkg/common import cd

cd "../issue564":
  let (_, exitCode) = execNimble("build")
  doAssert exitCode == QuitSuccess, "build failed"
