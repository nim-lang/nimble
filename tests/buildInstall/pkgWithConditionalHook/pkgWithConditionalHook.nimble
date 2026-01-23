# Package

version       = "0.1.0"
author        = "Test"
description   = "Package with conditional before-install hook"
license       = "MIT"

srcDir        = "src"
# No bin specified - this is a library package

# Dependencies

requires "nim >= 1.6.0"

# Conditional before install hook using when (compile-time)
# This should be detected by the declarative parser
when defined(nimsuggest) or true:
  before install:
    echo("HOOK_EXECUTED: conditional before-install hook ran successfully")

after install:
  echo("HOOK_EXECUTED: after-install hook ran successfully")
