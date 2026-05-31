discard """
  exitcode: 1
  outputsub: "Nothing to build"
"""

import os, ../common
from nimblepkg/common import cd

cd "../issue108":
  let (output, exitCode) = execNimble("build")
  echo output
  quit(exitCode)
