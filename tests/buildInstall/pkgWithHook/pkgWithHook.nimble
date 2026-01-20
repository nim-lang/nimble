# Package

version       = "0.1.0"
author        = "Test"
description   = "Package with before-install hook to test hook execution"
license       = "MIT"

srcDir        = "src"
# No bin specified - this is a library package

# Dependencies

requires "nim >= 1.6.0"

before install:
  echo("HOOK_EXECUTED: before-install hook ran successfully")

after install:
  echo("HOOK_EXECUTED: after-install hook ran successfully")
