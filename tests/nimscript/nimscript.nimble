# Package

version       = "0.1.0"
author        = "Dominik Picheta"
description   = "Test package"
license       = "BSD"

bin = @["nimscript"]

# Dependencies

requires "nim >= 0.12.1"

task test, "test description":
  echo(5+5)

task c_test, "Testing `setCommand \"c\", \"nimscript.nim\"`":
  setCommand "c", "nimscript.nim"

task cr, "Testing `nimble c -r nimscript.nim` via setCommand":
  --r
  setCommand "c", "nimscript.nim"

task api, "Testing nimscriptapi module functionality":
  echo(getPkgDir())