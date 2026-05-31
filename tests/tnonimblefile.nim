discard """
  exitcode: 0
"""

import os, strutils
import common
from nimblepkg/common import cd

proc main() =
  let testDir = getTempDir() / "no_nimble_file_test"
  if dirExists(testDir):
    removeDir(testDir)
  createDir(testDir)
  defer: removeDir(testDir)

  cd testDir:
    for cmd in ["build", "run", "test"]:
      let (output, exitCode) = execNimble(cmd)
      doAssert exitCode != QuitSuccess, cmd & ": " & output
      doAssert output.contains("Could not find a .nimble file"), output
      doAssert not output.contains("AssertionDefect"), output

main()
