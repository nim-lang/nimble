# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, strutils
import testscommon

suite "nimble refresh":
  test "can refresh with default urls":
    let (output, exitCode) = execNimble(["refresh"])
    checkpoint(output)
    check exitCode == QuitSuccess

  test "can refresh with custom urls":
    testRefresh():
      writeFile(configFile, """
        [PackageList]
        name = "official"
        url = "https://google.com"
        url = "https://google.com/404"
        url = "https://irclogs.nim-lang.org/packages.json"
        url = "https://nim-lang.org/nimble/packages.json"
        url = "https://github.com/nim-lang/packages/raw/master/packages.json"
      """.unindent)

      let (output, exitCode) = execNimble(["refresh", "--verbose"])
      checkpoint(output)
      let lines = output.strip.processOutput()
      check exitCode == QuitSuccess
      check inLines(lines, "config file at")
      check inLines(lines, "official package list")
      check inLines(lines, "https://google.com")
      check inLines(lines, "packages.json file is invalid")
      check inLines(lines, "404")
      check inLines(lines, "Package list downloaded.")

  test "can refresh with local package list":
    testRefresh():
      writeFile(configFile, """
        [PackageList]
        name = "local"
        path = "$1"
      """.unindent % (getCurrentDir() / "issue368" / "packages.json").replace(
        "\\", "\\\\"))
      let (output, exitCode) = execNimble(["refresh", "--verbose"])
      let lines = output.strip.processOutput()
      check inLines(lines, "config file at")
      check inLines(lines, "Copying")
      check inLines(lines, "Package list copied.")
      check exitCode == QuitSuccess

  test "missing package refreshes a fresh package list only once (#1793)":
    testRefresh():
      let
        tempNimbleDir = getTempDir() / "nimble_missing_package_refresh"
        packageList = getCurrentDir() / "issue368" / "packages.json"
      removeDir(tempNimbleDir)
      defer: removeDir(tempNimbleDir)

      writeFile(configFile, """
        [PackageList]
        name = "Official"
        path = "$1"
      """.unindent % packageList.replace("\\", "\\\\"))

      let (output, exitCode) = execNimble(
        "--nimbleDir:" & tempNimbleDir,
        "-y", "install", "definitely-not-a-nimble-package")
      checkpoint output
      check exitCode == QuitFailure
      check output.count("Copying Official package list") == 1
      check output.contains("Package definitely-not-a-nimble-package")

  test "package list source required":
    testRefresh():
      writeFile(configFile, """
        [PackageList]
        name = "local"
      """)
      let (output, exitCode) = execNimble(["refresh", "--verbose"])
      let lines = output.strip.processOutput()
      check inLines(lines, "config file at")
      check inLines(lines, "Package list 'local' requires either url or path")
      check exitCode == QuitFailure

  test "package list can only have one source":
    testRefresh():
      writeFile(configFile, """
        [PackageList]
        name = "local"
        path = "$1"
        url = "http://nim-lang.org/nimble/packages.json"
      """)
      let (output, exitCode) = execNimble(["refresh", "--verbose"])
      let lines = output.strip.processOutput()
      check inLines(lines, "config file at")
      check inLines(lines, "Attempted to specify `url` and `path` for the " &
                           "same package list 'local'")
      check exitCode == QuitFailure
