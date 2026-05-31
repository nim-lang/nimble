discard """
  exitcode: 0
"""

import os, strutils
import common
from nimblepkg/common import cd

proc main() =
  let testsDir = currentSourcePath().parentDir
  cd testsDir / "nimbleVersionDefine":
    let (output, exitCode) = execNimble("c", "-r", "src/nimbleVersionDefine.nim")
    doAssert output.contains("0.1.0"), output
    doAssert exitCode == QuitSuccess, output

    let (output2, exitCode2) = execNimble("run", "nimbleVersionDefine")
    doAssert output2.contains("0.1.0"), output2
    doAssert exitCode2 == QuitSuccess, output2

main()
