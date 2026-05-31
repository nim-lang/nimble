# Package

version       = "0.99.1"
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
  exec "testament --directory:tests --megatest:off --skipFrom:skip.txt pattern t*.nim"
  exec "testament --directory:tests/tissues --megatest:off pattern tissue_*.nim"
  exec "cd tests && nim c -r tester.nim"

task cibenchmark, "Run tests with timing instrumentation":
  exec "testament --directory:tests --megatest:off --skipFrom:skip.txt pattern t*.nim -d:timedTests"
  exec "testament --directory:tests/tissues --megatest:off pattern tissue_*.nim -d:timedTests"
  exec "cd tests && nim c -r -d:timedTests tester.nim"
