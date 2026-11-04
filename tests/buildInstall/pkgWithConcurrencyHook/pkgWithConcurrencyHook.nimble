# Package

version       = "0.1.0"
author        = "Test"
description   = "Package whose before-install hook pauses for the concurrent-install regression test"
license       = "MIT"

srcDir        = "src"
# No bin specified - this is a library package

# Dependencies

requires "nim >= 1.6.0"

# Used by tests/tconcurrentinstall.nim.
#
# Protocol: the first hook instance (env NIMBLE_HOOK_SIGNAL_DIR set, no
# hook_started marker yet) writes the marker and then spins until the test
# writes hook_release. A second hook instance sees the marker and proceeds
# immediately. Without NIMBLE_HOOK_SIGNAL_DIR the hook is a plain no-op so
# manual installs of this fixture never block.
#
# Note: nimscript has no sleep(), so the wait is a bounded spin on
# fileExists() (a real filesystem check per iteration). Paths are built with
# `&` because the os module's `/` and joinPath are not available in the
# nimscript evaluation context.
before install:
  let signalDir = getEnv("NIMBLE_HOOK_SIGNAL_DIR")
  if signalDir.len > 0:
    if fileExists(signalDir & "/hook_started"):
      echo("HOOK_EXECUTED: before-install hook ran (second instance)")
    else:
      writeFile(signalDir & "/hook_started", "1")
      var spins = 0
      while not fileExists(signalDir & "/hook_release"):
        inc spins
        if spins > 50_000_000:
          raise newException(CatchableError,
            "hook_release never appeared (bounded spin exhausted)")
      echo("HOOK_EXECUTED: paused before-install hook released")
  else:
    echo("HOOK_EXECUTED: before-install hook ran successfully")

after install:
  echo("HOOK_EXECUTED: after-install hook ran successfully")
