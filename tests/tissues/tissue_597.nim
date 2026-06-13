discard """
  exitcode: 1
  outputsub: "entry should not be a source file: test.nim"
"""

import os, ../common
from nimblepkg/common import cd

cd "../issue597":
  let (output, exitCode) = execNimble("build")
  echo output
  quit(exitCode)
