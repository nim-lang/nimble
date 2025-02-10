# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os
import testscommon
from nimblepkg/common import cd

suite "check command":
  test "can succeed package":
    cd "binaryPackage/v1":
      let (outp, exitCode) = execNimble("check")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("success")
      check outp.processOutput.inLines("\"binaryPackage\" is valid")

    cd "packageStructure/a":
      let (outp, exitCode) = execNimble("check")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("success")
      check outp.processOutput.inLines("\"a\" is valid")

    cd "packageStructure/b":
      let (outp, exitCode) = execNimble("check")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("success")
      check outp.processOutput.inLines("\"b\" is valid")

    cd "packageStructure/c":
      let (outp, exitCode) = execNimble("check")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("success")
      check outp.processOutput.inLines("\"c\" is valid")

    cd "packageStructure/x":
      let (outp, exitCode) = execNimble("check")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("success")
      check outp.processOutput.inLines("\"x\" is valid")

  test "should fail if parsers parse different dependencies":
    cd "inconsistentdeps":
      let (outp, exitCode) = execNimble("check")
      check exitCode == QuitFailure
      check outp.processOutput.inLines("Error:  Declarative and VM dependencies are not the same")
