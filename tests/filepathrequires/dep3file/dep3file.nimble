# Package

version       = "0.1.0"
author        = "jmgomez"
description   = "A new awesome nimble package"
license       = "MIT"
srcDir        = "src"
bin           = @["dep3file"]

# Dependencies

requires "nim >= 2.1.9"

feature "patch":
  requires "file://../depfile"