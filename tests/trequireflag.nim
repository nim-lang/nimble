{.used.}
import unittest, os#, strformat, osproc
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
  
  # test "should be able to override the nim version": #TODO fork the repo and fix the test
  #   let nimqmlDir = getTempDir() / "nimqml"
  #   removeDir(nimqmlDir)
  #   echo "NIMQML DIR is ", nimqmlDir
  #   let cloneCmd = &"git clone https://github.com/seaqt/nimqml-seaqt.git {nimqmlDir}"
  #   check execCmd(cloneCmd) == 0
  #   cd nimqmlDir:
  #     let (output, exitCode) = execNimble("--requires: nim == 2.0.0", "install", "-l")
  #     check exitCode == QuitSuccess
  #     echo "OUTPUT is", output
  #     check output.processOutput.inLines("Success:  nimqml installed successfully.")
  #     check output.processOutput.inLines("Installing nim@2.0.0")


