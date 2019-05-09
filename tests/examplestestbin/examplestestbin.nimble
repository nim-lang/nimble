# Package

version       = "0.1.0"
author        = "Istvan Nagy"
description   = "test for bin pkgs"
license       = "MIT"
srcDir        = "src"
bin           = @["examplestestbin"]
installExt    = @["nim"]

# Dependencies

requires "nim >= 0.14.0"
