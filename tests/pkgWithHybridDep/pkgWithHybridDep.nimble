# Package

version       = "0.1.0"
author        = "test"
description   = "A new awesome nimble package"
license       = "MIT"
srcDir        = "src"
bin           = @["pkgWithHybridDep"]


# Dependencies

requires "nim >= 2.2.4"
requires "https://github.com/nim-lang/nimble?subdir=tests/develop/hybrid"
