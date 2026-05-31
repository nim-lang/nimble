discard """
  exitcode: 0
"""

import os, ../common
from nimblepkg/common import cd

cd "../issue1636":
  let (_, exitCode) = execNimbleYes("failme")
  doAssert exitCode == QuitFailure, "expected failme to fail"
