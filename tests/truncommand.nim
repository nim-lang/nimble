# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, strutils, strformat
import common
import nimblepkg/displaymessages
from nimblepkg/common import cd
from nimblepkg/developfile import developFileName

suite "nimble run":
  const
    testPkgsPath = "runDependencyBinary"
    dependencyPkgPath = testPkgsPath / "dependency"
    dependentPkgPath = testPkgsPath / "dependent"
    dependencyPkgBinary = dependencyPkgPath / "binary".addFileExt(ExeExt)
    dependentPkgDevelopFile = dependentPkgPath / developFileName
    packagesFilePath = "develop/packages.json"

  test "Run binary from dependency in Nimble cache":
    cleanDir installDir
    cleanFile dependencyPkgBinary
    usePackageListFile(packagesFilePath):
      cd dependencyPkgPath:
        let (_, exitCode) = execNimble("install")
        check exitCode == QuitSuccess
      cd dependentPkgPath:
        let (output, exitCode) = execNimble("--package:dependency", "run",
          "-d:danger", "binary", "--arg1", "--arg2")
        check exitCode == QuitSuccess
        var lines = output.processOutput
        check lines.inLinesOrdered(ignoringCompilationFlagsMsg)
        check lines.inLinesOrdered("--arg1")
        check lines.inLinesOrdered("--arg2")

  test "Run binary from develop mode dependency":
    cleanDir installDir
    cleanFiles dependencyPkgBinary, dependentPkgDevelopFile
    usePackageListFile(packagesFilePath):
      cd dependentPkgPath:
        var (output, exitCode) = execNimble("develop", "-a:../dependency")
        check exitCode == QuitSuccess
        (output, exitCode) = execNimble("--package:dependency", "run",
          "-d:danger", "binary", "--arg1", "--arg2")
        check exitCode == QuitSuccess
        var lines = output.processOutput
        const binaryName = when defined(windows): "binary.exe" else: "binary"
        check lines.inLinesOrdered(
          &"Building dependency/{binaryName} using c backend")
        check lines.inLinesOrdered("--arg1")
        check lines.inLinesOrdered("--arg2")

  test "Error when specified package does not exist":
    cleanDir installDir
    cleanFile dependencyPkgBinary
    usePackageListFile(packagesFilePath):
      cd dependencyPkgPath:
        let (_, exitCode) = execNimble("install")
        check exitCode == QuitSuccess
      cd dependentPkgPath:
        let (output, exitCode) = execNimble("--package:dep", "run",
          "-d:danger", "binary", "--arg1", "--arg2")
        check exitCode == QuitFailure
        check output.contains(notFoundPkgWithNameInPkgDepTree("dep"))

  test "Error when specified binary does not exist in specified package":
    cleanDir installDir
    cleanFile dependencyPkgBinary
    usePackageListFile(packagesFilePath):
      cd dependencyPkgPath:
        let (_, exitCode) = execNimble("install")
        check exitCode == QuitSuccess
      cd dependentPkgPath:
        let (output, exitCode) = execNimble("--package:dependency", "run",
          "-d:danger", "bin", "--arg1", "--arg2")
        check exitCode == QuitFailure
        const binaryName = when defined(windows): "bin.exe" else: "bin"
        check output.contains(binaryNotDefinedInPkgMsg(
          binaryName, "dependency"))
