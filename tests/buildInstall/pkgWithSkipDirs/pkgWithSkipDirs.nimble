# Package

version       = "0.1.0"
author        = "Test"
description   = "Package to test skipDirs blacklist mode"
license       = "MIT"

srcDir        = "src"
skipDirs      = @["internal"]
bin           = @["pkgWithSkipDirs"]

# Dependencies

requires "nim >= 1.6.0"
