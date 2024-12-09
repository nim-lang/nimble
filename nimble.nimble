# Package

version       = "0.16.4"
author        = "Dominik Picheta"
description   = "Nim package manager."
license       = "BSD"

bin = @["nimble"]
srcDir = "src"
installExt = @["nim"]

# Dependencies
requires "nim >= 1.6.20"

when defined(nimdistros):
  import distros
  if detectOs(Ubuntu):
    foreignDep "libssl-dev"
  else:
    foreignDep "openssl"

before install:
  exec "git submodule update --init"

task test, "Run the Nimble tester!":
  withDir "tests":
    exec "nim c -r tester"
