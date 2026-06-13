discard """
  exitcode: 0
"""

import os
import common
from nimblepkg/common import cd

proc main() =
  let testsDir = currentSourcePath().parentDir
  cd testsDir / "recursive":
    let (_, exitCode) = execNimble("recurse")
    doAssert exitCode == QuitSuccess

main()
