# Package

version       = "0.1.0"
author        = "xTrayambak"
description   = "Test to check if Nimble can correctly handle packages that are installed via a forge alias"
license       = "MIT"
srcDir        = "src"
bin           = @["forgealias001"]


# Dependencies

requires "nim >= 1.6.0"
requires "gh:xTrayambak/librng >= 0.1.3"
