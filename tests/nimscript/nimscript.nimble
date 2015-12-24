# Package

version       = "0.1.0"
author        = "Dominik Picheta"
description   = "Test package"
license       = "BSD"

bin = @["nimscript"]

# Dependencies

requires "nim >= 0.12.1"

task test, "test description":
  echo(5+5)

task example, "Build and run examples for current platform":
    setCommand "c"