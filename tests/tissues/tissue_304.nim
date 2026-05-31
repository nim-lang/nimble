discard """
  exitcode: 0
"""

import os, ../common
from nimblepkg/common import cd

cd "../issue304/package-test":
  let (_, exitCode) = execNimble("tasks")
  doAssert exitCode == QuitSuccess, "tasks failed"
