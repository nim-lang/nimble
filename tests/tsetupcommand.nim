# Copyright (C) the Nimble contributors. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, strutils, osproc
import testscommon
from nimble import nimblePathsFileName, nimbleConfigFileName
from nimblepkg/common import cd
from nimblepkg/developfile import developFileName

suite "setup command":
  cleanDir installDir
  test "nimble setup (without develop file)":
    cd "setup/binary":
      usePackageListFile "../../develop/packages.json":
        cleanFiles nimblePathsFileName, nimbleConfigFileName, "binary"
        let (_, exitCode) = execNimble("setup")
        check exitCode == QuitSuccess
        # Check that the paths and config files are generated.
        check fileExists(nimblePathsFileName)
        check fileExists(nimbleConfigFileName)
        # Check that the paths file contains the right path/
        let pkgADir = getPackageDir(pkgsDir, "packagea-0.2.0")
        let pkgBDir = getPackageDir(pkgsDir, "packageb-0.1.0")
        let pathsFileContent = nimblePathsFileName.readFile
        check pathsFileContent.contains(pkgADir)
        check pathsFileContent.contains(pkgBDir)
        # Check that Nim can use "nimble.paths" file to find dependencies and
        # build the project.
        let (_, nimExitCode) = execCmdEx("nim c -r binary")
        check nimExitCode == QuitSuccess

  test "nimble setup (with develop file)":
    cd "setup/dependent":
      usePackageListFile "../../develop/packages.json":
        cleanFiles nimblePathsFileName, nimbleConfigFileName,
                   developFileName, "dependent"
        let (_, developExitCode) = execNimble("develop", "-a:../dependency")
        check developExitCode == QuitSuccess
        let (_, setupExitCode) = execNimble("setup")
        check setupExitCode == QuitSuccess
        # Check that the paths and config files are generated.
        check fileExists(nimblePathsFileName)
        check fileExists(nimbleConfigFileName)
        # Check that develop mode dependency path is written in the
        # "nimble.paths" file.
        let developDepDir =
          (getCurrentDir() / ".." / "dependency").normalizedPath
        check nimblePathsFileName.readFile.contains(developDepDir.escape)
        # Check that Nim can use "nimble.paths" file to find dependencies and
        # build the project.
        let (_, nimExitCode) = execCmdEx("nim c -r dependent")
        check nimExitCode == QuitSuccess

  test "Check if upgrading of setup section":
    cd "setupproject":
      cleanFiles nimblePathsFileName, nimbleConfigFileName, "nimble.lock", ".gitignore"
      discard execNimble("setup")
      var configFileContent = nimbleConfigFileName.readFile
      check not configFileContent.contains("--noNimblePath")
      let (_, developExitCode) = execNimble("lock")
      check developExitCode == QuitSuccess

      # update of the section works
      discard execNimble("setup")
      check fileExists("nimble.lock")
      configFileContent = nimbleConfigFileName.readFile
      check configFileContent.contains("--noNimblePath")

      cleanFiles nimblePathsFileName, nimbleConfigFileName, "nimble.lock", ".gitignore"
    
  test "nimble lock implies nimble setup (#1795)":
    cd "setup/binary":
      usePackageListFile "../../develop/packages.json":
        cleanFiles nimblePathsFileName, nimbleConfigFileName, "nimble.lock",
                   "binary"
        let (_, exitCode) = execNimble("lock")
        check exitCode == QuitSuccess
        check fileExists("nimble.lock")
        # Without the paths/config files the lock file is not enforced during
        # compilation, so `lock` has to generate them too.
        check fileExists(nimblePathsFileName)
        check fileExists(nimbleConfigFileName)
        let pathsFileContent = nimblePathsFileName.readFile
        check pathsFileContent.contains(getPackageDir(pkgsDir, "packagea-0.2.0"))
        check pathsFileContent.contains(getPackageDir(pkgsDir, "packageb-0.1.0"))
        # A lock file is present now, so the config has to pin the paths.
        check nimbleConfigFileName.readFile.contains("--noNimblePath")
        cleanFiles nimblePathsFileName, nimbleConfigFileName, "nimble.lock"

  test "nimble setup writes active feature paths and defines":
    cd "features":
      let binary = addFileExt("setup_features_test", ExeExt)
      cleanFiles nimblePathsFileName, nimbleConfigFileName, binary
      for features in ["--features:feature1,dev", "--features:feature1;dev"]:
        verify execNimble("setup", features)
        let pathsFileContent = nimblePathsFileName.readFile
        check pathsFileContent.contains("stew")
        check pathsFileContent.count("--define:\"features.features.feature1\"") == 1
        check pathsFileContent.count("--define:\"features.features.dev\"") == 1
        check pathsFileContent.count("--define:\"features.result.resultfeature\"") == 1

      let (output, nimExitCode) =
        execCmdEx("nim c -r --out:" & binary.quoteShell & " src/features.nim")
      checkpoint output
      check nimExitCode == QuitSuccess
      check output.processOutput.inLines("feature1 is enabled\nresultfeature is enabled")

      verify execNimble("setup")
      let pathsFileContent = nimblePathsFileName.readFile
      check not pathsFileContent.contains("stew")
      check not pathsFileContent.contains("features.features.feature1")
      check pathsFileContent.contains("--define:\"features.result.resultfeature\"")

