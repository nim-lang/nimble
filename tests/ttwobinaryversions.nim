# Copyright (C) the Nimble contributors. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, strutils
import testscommon
from nimblepkg/common import cd

suite "can handle two binary versions":
  setup:
    removeDir(installDir)
    cd "binaryPackage/v1":
      check execNimbleYes("install").exitCode == QuitSuccess

    cd "binaryPackage/v2":
      check execNimbleYes("install").exitCode == QuitSuccess

  test "can execute v2":
    let (output, exitCode) = execBin("binaryPackage")
    check exitCode == QuitSuccess
    check output.strip() == "v2"

  test "reinstalling cached versions switches the active binary (#1926)":
    for version in ["v1", "v2"]:
      cd "binaryPackage" / version:
        check execNimbleYes("install", "--offline").exitCode == QuitSuccess

      let (output, exitCode) = execBin("binaryPackage")
      check exitCode == QuitSuccess
      check output.strip() == version

  test "reinstalling a cached version restores a missing binary link":
    when defined(windows):
      removeFile(installDir / "bin" / "binaryPackage.cmd")
    else:
      removeFile(installDir / "bin" / "binaryPackage")

    cd "binaryPackage/v1":
      check execNimbleYes("install", "--offline").exitCode == QuitSuccess

    let (output, exitCode) = execBin("binaryPackage")
    check exitCode == QuitSuccess
    check output.strip() == "v1"

  test "installing only dependencies does not switch the active binary":
    cd "binaryPackage/v1":
      check execNimbleYes("install", "--depsOnly", "--offline").exitCode == QuitSuccess

    let (output, exitCode) = execBin("binaryPackage")
    check exitCode == QuitSuccess
    check output.strip() == "v2"

  test "using a cached binary dependency does not switch the active binary":
    cdCleanDir installDir / "binaryconsumer":
      writeFile("binaryconsumer.nimble", """
version = "1.0"
author = "Nimble tests"
description = "Uses an older binary package"
license = "MIT"
requires "binaryPackage == 1.0"
""")
      check execNimbleYes("install", "--offline").exitCode == QuitSuccess

    let (output, exitCode) = execBin("binaryPackage")
    check exitCode == QuitSuccess
    check output.strip() == "v2"

  test "can update symlink to earlier version after removal":
    check execNimbleYes("remove", "binaryPackage@2.0").exitCode==QuitSuccess

    let (output, exitCode) = execBin("binaryPackage")
    check exitCode == QuitSuccess
    check output.strip() == "v1"

  test "can keep symlink version after earlier version removal":
    check execNimbleYes("remove", "binaryPackage@1.0").exitCode==QuitSuccess

    let (output, exitCode) = execBin("binaryPackage")
    check exitCode == QuitSuccess
    check output.strip() == "v2"
