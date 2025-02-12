# Package

version       = "0.1.0"
author        = "jmgomez"
description   = "A new awesome nimble package"
license       = "MIT"
srcDir        = "src"
bin = @["features"]

# Dependencies

requires "nim >= 2.3.1"

feature "feature1":
  requires "stew"
