# Copyright (C) the Nimble contributors. All rights reserved.
# BSD License. Look at license.txt for more info.

## Regression test for #1910: two nimble processes installing the same package
## version concurrently used to share (and clobber) one buildtemp directory.
##
## Scenario: install A pauses inside the package's before-install hook while
## install B (same package) runs to the end. Installing the package by
## file:// URL keeps the working directory outside the package, so the
## before-install hook is not executed early for the root package and instead
## runs from inside its buildtemp directory - A is paused while its buildtemp
## directory exists and is in use.
##
## Before the fix, B deleted A's buildtemp working tree (B's
## dirExists/removeDir at startup plus B's final cleanup) and A failed. With
## per-process buildtemp directories both installs succeed and buildtemp is
## left empty: the install-time try/finally now also covers a failed copy,
## hook or build, so no per-process leftovers can pile up.

{.used.}

import unittest, os, osproc, streams, strutils
import testscommon

suite "concurrent install":
  setup:
    # Clean up nimbleDir before each test
    removeDir(installDir)
    createDir(installDir)

  test "two concurrent installs of the same package both succeed":
    # file:// installs want a git repo for version discovery (see the
    # issue1650 test): init one for the fixture and drop it afterwards.
    let depDir = getCurrentDir() / "buildInstall" / "pkgWithConcurrencyHook"
    discard execCmdEx("git -C " & depDir.quoteShell & " init")
    discard execCmdEx("git -C " & depDir.quoteShell & " config user.name \"Test\"")
    discard execCmdEx("git -C " & depDir.quoteShell & " config user.email \"test@test.com\"")
    discard execCmdEx("git -C " & depDir.quoteShell & " add -A")
    discard execCmdEx("git -C " & depDir.quoteShell & " commit -m init")

    let signalDir = getTempDir() / "nimble_hook_signal_" & $getCurrentProcessId()
    removeDir(signalDir)
    createDir(signalDir)

    putEnv("NIMBLE_HOOK_SIGNAL_DIR", signalDir)
    # The hook fixture uses a bounded spin (nimscript has no sleep), so every
    # wait below is bounded too: the test fails instead of hanging CI.
    try:
      # Install A: runs in the background and pauses inside the before-install
      # hook, i.e. while its buildtemp directory exists and is in use.
      let p1 = startProcess(
        command = nimblePath,
        workingDir = getCurrentDir(),
        args = @["--noColor", "--nimbleDir:" & installDir, "-y",
                 "install", "file://" & depDir],
        options = {poStdErrToStdOut, poUsePath})

      # Wait until A is inside its before-install hook.
      var inHook = false
      var waited = 0
      while waited < 1200: # <= 2 minutes
        if fileExists(signalDir & "/hook_started"):
          inHook = true
          break
        os.sleep(100)
        inc waited

      if not inHook:
        # Surface A's output so the failure is diagnosable.
        writeFile(signalDir & "/hook_release", "1")
        let outA = p1.outputStream.readAll()
        discard p1.waitForExit()
        p1.close()
        checkpoint outA
      check inHook # A is paused in its before-install hook

      if inHook:
        # Install B: the same package, while A is paused. B's hook instance
        # sees A's marker and proceeds immediately.
        var outB: string
        var codeB: int
        (outB, codeB) = execNimbleYes("--nimbleDir:" & installDir,
                                      "install", "file://" & depDir)
        checkpoint outB
        check codeB == QuitSuccess
        check "HOOK_EXECUTED: before-install hook ran (second instance)" in outB

        # Release A, which must now succeed with its own buildtemp directory.
        writeFile(signalDir & "/hook_release", "1")
        var waited2 = 0
        while p1.running() and waited2 < 600: # <= 2 minutes
          os.sleep(200)
          inc waited2
        let outA = p1.outputStream.readAll()
        let codeA = p1.waitForExit()
        p1.close()
        checkpoint outA
        check codeA == QuitSuccess
        check "HOOK_EXECUTED: paused before-install hook released" in outA

        # No buildtemp leftovers from either install: with per-process names
        # nothing else would ever clean them up. buildtemp always lives in the
        # global nimble dir (see getBuildTempDir, #1650).
        let buildTempBase = getHomeDir() / ".nimble" / "buildtemp"
        if dirExists(buildTempBase):
          var leftovers = 0
          for kind, path in walkDir(buildTempBase):
            inc leftovers
          check leftovers == 0
    finally:
      delEnv("NIMBLE_HOOK_SIGNAL_DIR")
      removeDir(signalDir)
      removeDir(depDir / ".git")
