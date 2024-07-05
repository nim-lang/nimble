# Package

version       = "0.1.0"
author        = "jmgomez"
description   = "A new awesome nimble package"
license       = "MIT"
srcDir        = "src"
bin = @["nim1620"]

# Dependencies

requires "nim == 1.6.20"

after build:
  let (output, _) = gorgeEx "./nim1620"
  assert output == NimVersion 