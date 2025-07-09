{.used.}
import unittest, os, strutils# strformat, osproc
import testscommon
from nimblepkg/common import cd

suite "requires flag":
  test "can add additional requirements to package with legacy solver":
    cleanDir(installDir)
    cd "requireflag":
      #legacy solver is not supported in vnext (nimble 1.0.0)
      let (outp, exitCode) = execNimble("--requires: stew; results > 0.1", "--solver:legacy", "--parser:nimvm", "install")
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



  test "should be able to install a special version":
  #[
    Test it can install a dep with the following variations:
      - https://github.com/status-im/nim-json-serialization.git#lean-arrays
      - https://github.com/status-im/nim-json-serialization.git#4cd31594f868a3d3cb81ec9d5f479efbe2466ebd
      - json_serialization#lean-arrays
      - json_serialization#4cd31594f868a3d3cb81ec9d5f479efbe2466ebd
  ]#
    let requires = [
      "https://github.com/status-im/nim-json-serialization.git#nimble_test_dont_delete",
      "https://github.com/status-im/nim-json-serialization.git#26bea5ffce20ae0d0855b3d61072de04d3bf9826",
      "json_serialization#nimble_test_dont_delete",
      "json_serialization#26bea5ffce20ae0d0855b3d61072de04d3bf9826",
      "json_serialization == 0.2.9"
    ]
    cleanDir(installDir)
    cd "gitversions":
      for req in requires:
        let require = "--requires: " & req
        let isVersion = req.contains("==")
        # echo "Trying require: ", req
        let no_test = if isVersion: "-d:no_test" else: ""
        let (output, exitCode) = execNimble("run", require, no_test)
        let pkgDir = getPackageDir(pkgsDir, "json_serialization-0.2.9")
        check exitCode == QuitSuccess
        
        let (_, exitCodeTest) = execNimble("test", require, no_test)
        check exitCodeTest == QuitSuccess

        let nimbleTestDontDeleteFile =  pkgDir / "json_serialization" / "nimbletest.nim"
        # echo "Nimble test dont delete file: ", nimbleTestDontDeleteFile
        if isVersion:
          check output.processOutput.inLines("Success:  json_serialization installed successfully.")
          check not fileExists(nimbleTestDontDeleteFile)
        else:
          check output.processOutput.inLines("Success:  json_serialization installed successfully.")
          check fileExists(nimbleTestDontDeleteFile)
        cleanDir(pkgDir) #Resets the package dir for each require

