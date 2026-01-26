# Package

version       = "0.1.0"
author        = "Test"
description   = "Package with only after-install hook (no before-install)"
license       = "MIT"

srcDir        = "src"
# No bin specified - this is a library package

# Dependencies

requires "nim >= 1.6.0"

# Only after install hook - should skip buildtemp flow
after install:
  echo("HOOK_EXECUTED: after-install hook ran successfully")
