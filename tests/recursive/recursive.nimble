# Package

version       = "0.1.0"
author        = "Dominik Picheta"
description   = "Test package"
license       = "BSD"

# Dependencies

requires "nim >= 0.12.1"

task recurse, "Level 1":
  echo 1
  exec "../../src/nimble recurse2"

task recurse2, "Level 2":
  echo 2
  exec "../../src/nimble recurse3"

task recurse3, "Level 3":
  echo 3
