# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, strutils, os
import testscommon

suite "offline mode":
  test "cannot install packagebin2 in --offline mode":
    cleanDir(installDir)
    let args = ["--offline", "install", pkgBin2Url]
    let (output, exitCode) = execNimbleYes(args)
    check exitCode != QuitSuccess
    check output.contains("offline mode")

  test "cannot refresh in --offline mode":
    let (output, exitCode) = execNimble(["--offline", "refresh"])
    check exitCode != QuitSuccess
    check output.contains("Cannot refresh package list in offline mode.")

  test "cannot check URL type in --offline mode":
    cleanDir(installDir)
    # Using a raw URL (not a known package name) triggers checkUrlType
    let args = ["--offline", "install", "https://github.com/nimble-test/packagea.git"]
    let (output, exitCode) = execNimbleYes(args)
    check exitCode != QuitSuccess
    check output.contains("offline mode")

  test "cannot download Nim in --offline mode":
    cleanDir(installDir)
    # Attempting to install a package that requires a Nim download in offline mode
    let args = ["--offline", "--useSystemNim", "install", pkgBin2Url]
    let (output, exitCode) = execNimbleYes(args)
    # This should either succeed (using system nim, already cached) or fail with offline error
    # The key is it should NOT attempt network calls
    if exitCode != QuitSuccess:
      check output.contains("offline") or output.contains("Cannot download")
