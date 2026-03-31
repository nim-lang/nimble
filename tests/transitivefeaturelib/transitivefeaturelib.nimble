# Package
version       = "0.1.0"
author        = "test"
description   = "Library with transitive feature"
license       = "MIT"
srcDir        = "src"

requires "nim"
requires "result"

feature "withresult":
  requires "result[resultfeature]"
