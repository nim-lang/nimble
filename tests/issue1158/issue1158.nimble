
# Package

version       = "0.1.0"
author        = "stoneface86"
description   = "A new awesome nimble package"
license       = "MIT"
srcDir        = "src"


# Dependencies

requires "nim >= 1.6.16"

task echoRequires, "":
  echo requiresData

