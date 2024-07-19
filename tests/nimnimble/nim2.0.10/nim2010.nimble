# Package
version       = "0.1.0"
author        = "jmgomez"
description   = "A new awesome nimble package"
license       = "MIT"
srcDir        = "src"
bin           = @["nim2010"]

# Dependencies

requires "nim == 2.0.10"

after build:
  let (output, _) = gorgeEx "./nim2010"
  assert output.strip == NimVersion 
