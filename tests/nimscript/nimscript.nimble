# Package

version       = "0.1.0"
author        = "Dominik Picheta"
description   = "Test package"
license       = "BSD"

bin = @["nimscript"]

# Dependencies

requires "nim >= 0.12.1"

task work, "test description":
  echo(5+5)

task c_test, "Testing `setCommand \"c\", \"nimscript.nim\"`":
  setCommand "c", "nimscript.nim"

task cr, "Testing `nimble c -r nimscript.nim` via setCommand":
  --r
  setCommand "c", "nimscript.nim"

task repeated, "Testing `nimble c nimscript.nim` with repeated flags":
  --define: foo
  --define: bar
  setCommand "c", "nimscript.nim"

task api, "Testing nimscriptapi module functionality":
  echo(getPkgDir())

before hooks:
  echo("First")

task hooks, "Testing the hooks":
  echo("Middle")

after hooks:
  echo("last")

before hooks2:
  return false

task hooks2, "Testing the hooks again":
  echo("Shouldn't happen")
