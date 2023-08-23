# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, osproc, strutils
import testscommon
from nimblepkg/common import cd


suite "No global nim":
  let
    path = getEnv("PATH")
    nimbleCacheDir = getCurrentDir() / "localnimbledeps"
  when defined Linux:
    putEnv("PATH", findExe("git").parentDir)
  putEnv("NIMBLE_DIR", nimbleCacheDir)

  proc cleanup() =
    cd "nimdep":
      removeDir(nimbleCacheDir)
      removeFile("nimble.develop")
      removeDir("Nim")

  test "No nim lock file":
    cleanup()
    cd "nimdep":
      let (output, exitCode) =
        execCmdEx(nimblePath & " version -y --noLockFile")
      echo output
      check exitCode == QuitSuccess

      let usingNim = when defined(Windows): "nim.exe for compilation" else: "bin/nim for compilation"
      check output.contains(usingNim)
      check output.contains("compiling nim in ")

      # check not compiled again
      let (outputAfterInstalled, exitCodeAfterInstalled) =
        execCmdEx(nimblePath & " version -y --noLockFile")
      check exitCodeAfterInstalled == QuitSuccess
      check not outputAfterInstalled.contains("compiling nim in ")

      # install develop version
      check QuitSuccess == execCmdEx(nimblePath & " develop nim -y --noLockFile").exitCode

      let (outputAfterDevelop, exitCodeAfterDevelop) =
        execCmdEx(nimblePath & " version -y --noLockFile")
      check exitCodeAfterDevelop == QuitSuccess
      check outputAfterDevelop.contains("Develop version of nim was found but it is not compiled. Compile it now?")
      check outputAfterDevelop.contains("compiling nim in ")

      # make sure second develop call won't result in compiling and asking again
      let (outputAfterDevelop2, exitCodeAfterDevelop2) =
        execCmdEx(nimblePath & " version -y --noLockFile")
      check exitCodeAfterDevelop2 == QuitSuccess
      check not outputAfterDevelop2.contains("Develop version of nim was found but it is not compiled. Compile it now?")
      check not outputAfterDevelop2.contains("compiling nim in ")

  test "The nim from the lock file used":
    cleanup()
    cd "nimdep":

      let (output, exitCode) =
        execCmdEx(nimblePath & " version -y --lock-file=nimble-no-global-nim.lock")
      check exitCode == QuitSuccess

      let usingNim = when defined(Windows): "nim.exe for compilation" else: "bin/nim for compilation"
      check output.contains(usingNim)
      check output.contains("koch")

      # check not compiled again
      let (outputAfterInstalled, exitCodeAfterInstalled) =
        execCmdEx(nimblePath & " version -y --lock-file=nimble-no-global-nim.lock")
      check exitCodeAfterInstalled == QuitSuccess
      check not outputAfterInstalled.contains("koch")

  test "Nimble install -d works":
    cleanup()
    cd "nimdep":
      let (output, exitCode) =
        execCmdEx(nimblePath & " install -d -y --lock-file=nimble-no-global-nim.lock")
      check exitCode == QuitSuccess

      let usingNim = when defined(Windows): "nim.exe for compilation" else: "bin/nim for compilation"
      check output.contains(usingNim)
      check output.contains("koch")

  putEnv("PATH", path)
  delEnv("NIMBLE_DIR")
  cleanup()
