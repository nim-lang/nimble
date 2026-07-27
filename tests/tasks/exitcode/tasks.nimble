# Package

version       = "0.1.0"
author        = "nimble tests"
description   = "Test exit code propagation from tasks"
license       = "MIT"

# Dependencies

requires "nim >= 0.19.0"


task ok, "A task that succeeds":
    echo "all good"

task fail, "A task that quits with exit code 3":
    quit(3)

task failexec, "A task that runs a failing external command":
    exec "exit 7"
