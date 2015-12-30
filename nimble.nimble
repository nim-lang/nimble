# Package

version       = "0.7.0"
author        = "Dominik Picheta"
description   = "Nim package manager."
license       = "BSD"

bin = @["nimble"]
srcDir = "src"

# Dependencies

requires "nim >= 0.11.2"

before tasks:
  echo("About to list tasks!")
  return true

after tasks:
  echo("Listed tasks!")

task tests, "Run the Nimble tester!":
  withDir "tests":
    exec "nim c -r tester"