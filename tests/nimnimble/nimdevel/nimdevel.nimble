# Package

version       = "0.1.0"
author        = "jmgomez"
description   = "A new awesome nimble package"
license       = "MIT"
srcDir        = "src"
bin           = @["nimdevel"]


# Dependencies

requires "nim#devel"

after build:
  let (output, _) = gorgeEx "./nimdevel"
  assert output.strip == NimVersion 