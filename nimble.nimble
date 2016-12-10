import ospaths
template thisModuleFile: string = instantiationInfo(fullPaths = true).filename

when fileExists(thisModuleFile.parentDir / "src/nimblepkg/common.nim"):
  # In the git repository the Nimble sources are in a ``src`` directory.
  import src/nimblepkg/common
else:
  # When the package is installed, the ``src`` directory disappears.
  import nimblepkg/common

# Package

version       = nimbleVersion
author        = "Dominik Picheta"
description   = "Nim package manager."
license       = "BSD"

bin = @["nimble"]
srcDir = "src"

# Dependencies

requires "nim >= 0.13.0", "compiler#head"

task tests, "Run the Nimble tester!":
  withDir "tests":
    exec "nim c -r tester"
