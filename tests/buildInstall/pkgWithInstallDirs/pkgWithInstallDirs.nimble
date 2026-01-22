# Package

version       = "0.1.0"
author        = "Test"
description   = "Package to test installDirs whitelist mode"
license       = "MIT"

srcDir        = "src"
installDirs   = @["extra"]
bin           = @["pkgWithInstallDirs"]

# Dependencies

requires "nim >= 1.6.0"
