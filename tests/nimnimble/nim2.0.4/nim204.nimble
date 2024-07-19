# Package
version       = "0.1.0"
author        = "jmgomez"
description   = "A new awesome nimble package"
license       = "MIT"
srcDir        = "src"
bin           = @["nim204"]

# Dependencies

requires "nim >= 2.0.4 & < 2.1"

after build:
  let (output, _) = gorgeEx "./nim204"
  assert output.strip == NimVersion 
