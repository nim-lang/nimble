discard """
  exitcode: 0
"""

import os, strutils
import ../common
from nimblepkg/common import cd

proc main() =
  let tmpDir = getTempDir() / "tissue1648"
  removeDir(tmpDir)
  createDir(tmpDir)
  defer: removeDir(tmpDir)

  writeFile(tmpDir / "project.nimble", """
version = "0.1.0"
author = "test"
description = "test"
license = "MIT"
requires "nim >= 1.0.0"
requires "checksums >= 0.1.0"

task hello, "hello":
  echo "hello"
""")

  let nimbleDir = tmpDir / "nimbledir"

  # Install a specific older version
  cd tmpDir:
    let (installOut, installCode) = execNimbleYes("install", "--nimbleDir:" & nimbleDir, "checksums@0.1.0")
    doAssert installCode == QuitSuccess, installOut

  # Run a custom task — should NOT install newer checksums
  cd tmpDir:
    let (output, exitCode) = execNimbleYes("hello", "--nimbleDir:" & nimbleDir)
    doAssert exitCode == QuitSuccess, output
    doAssert output.contains("hello"), output
    # The key assertion: no newer version should be installed
    doAssert not output.contains("Installing checksums"), output

main()
