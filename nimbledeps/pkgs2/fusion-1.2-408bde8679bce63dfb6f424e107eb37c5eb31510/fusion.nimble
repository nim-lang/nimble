# Package

version       = "1.2"
author        = "Araq"
description   = "Extensions for Nim's stdlib"
license       = "MIT"
srcDir        = "src"


# Dependencies
requires "nim >= 1.0.0"

task docs, "":
  # JavaScript
  when (NimMajor, NimMinor) >= (1, 5):
    exec "nim c -r -d:fusionDocJs src/fusion/docutils " & srcDir
  # C
  exec "nim c -r src/fusion/docutils " & srcDir
