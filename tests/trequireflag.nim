{.used.}
import unittest, os
import testscommon
from nimblepkg/common import cd

suite "requires flag":
  test "can add additional requirements to package with legacy solver":
    cleanDir(installDir)
    cd "requireflag":
      let (outp, exitCode) = execNimble("--requires: stew; results > 0.1", "--solver:legacy", "install")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("Success:  results installed successfully.")
      check outp.processOutput.inLines("Success:  stew installed successfully.")

  test "can add additional requirements to package with sat solver":
    cleanDir(installDir)
    cd "requireflag":
      let (outp, exitCode) = execNimble("--requires: stew; results > 0.1", "--solver:sat", "install")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("Success:  results installed successfully.")
      check outp.processOutput.inLines("Success:  stew installed successfully.")