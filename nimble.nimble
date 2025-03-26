# Package

version       = "0.18.2"
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
  #Find params that are a test name
  var extraParams = ""
  for i in 0 .. paramCount():
    if "::" in paramStr(i):
      extraParams = "test " 
      extraParams.addQuoted paramStr(i)

  withDir "tests":  
    exec "nim c -r tester " & extraParams
