{.used.}
import unittest, os, strutils, sequtils# strformat, osproc
import testscommon
from nimblepkg/common import cd
from nimble import nimblePathsFileName

suite "requires flag":
  test "can add additional requirements to package with legacy solver":
    cleanDir(installDir)
    cd "requireflag":
      #legacy solver is not supported in vnext (nimble 1.0.0)
      let (outp, exitCode) = execNimble("--requires: stew; results > 0.1", "--solver:legacy", "--legacy", "install")
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
    cd "gitversions":
      for req in requires:
        cleanDir(installDir)
        let require = "--requires: " & req
        let isVersion = req.contains("==")
        echo "Trying require: ", req
        let no_test = if isVersion: "-d:no_test" else: ""
        let (_, exitCode) = execNimble("run", require, no_test)
        
        check exitCode == QuitSuccess
        if exitCode != QuitSuccess:
          break
        
        let (_, exitCodeTest) = execNimble("test", require, no_test)
        check exitCodeTest == QuitSuccess

        let (_, exitCodeSetup) = execNimble("setup", require)
        check exitCodeSetup == QuitSuccess
        
        # Check nimble.paths file for correct path and no duplicates
        check fileExists(nimblePathsFileName)
        let pathsContent = nimblePathsFileName.readFile
        let jsonSerializationLines = pathsContent.splitLines.filterIt(it.contains("json_serialization"))
        check jsonSerializationLines.len == 1
        
        # Verify the path is correctly formatted
        let pathLine = jsonSerializationLines[0]
        let pathStart = pathLine.find('"') + 1
        let pathEnd = pathLine.rfind('"')
        check pathStart > 0 and pathEnd > pathStart
        let packagePath = pathLine[pathStart..<pathEnd]
        check packagePath.contains("json_serialization")

        var pkgDir = ""
        if isVersion:
          pkgDir = getPackageDir(pkgsDir, "json_serialization")
        else:
          # Special version - find the directory with nimbletest.nim
          for kind, dir in walkDir(pkgsDir):
            if kind == pcDir and dir.splitPath.tail.startsWith("json_serialization"):
              let testFile = dir / "json_serialization" / "nimbletest.nim"
              if fileExists(testFile):
                pkgDir = dir
                break
          # If no directory with nimbletest.nim found, fall back to standard function
          if pkgDir == "":
            pkgDir = getPackageDir(pkgsDir, "json_serialization")
        
        check pkgDir != ""

        let nimbleTestDontDeleteFile = pkgDir / "json_serialization" / "nimbletest.nim"
        # echo "Nimble test dont delete file: ", nimbleTestDontDeleteFile
        if isVersion:
          # Regular version should NOT have the nimbletest.nim file
          check not fileExists(nimbleTestDontDeleteFile)
        else:
          # Special version should have the nimbletest.nim file
          check fileExists(nimbleTestDontDeleteFile)
        # Clean up all json_serialization directories
        for kind, dir in walkDir(pkgsDir):
          if kind == pcDir and dir.splitPath.tail.startsWith("json_serialization"):
            removeDir(dir)

