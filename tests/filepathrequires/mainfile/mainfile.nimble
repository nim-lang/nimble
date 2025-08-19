# Package

version       = "0.1.0"
author        = "jmgomez"
description   = "A new awesome nimble package"
license       = "MIT"
srcDir        = "src"
bin           = @["mainfile"]


# Dependencies

requires "nim >= 2.1.9"
# requires "file://../depfile" Passed as argument to make the tests more flexible