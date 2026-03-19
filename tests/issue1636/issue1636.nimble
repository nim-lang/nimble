# Package
version       = "0.1.0"
author        = "Test"
description   = "Test exit code on task failure"
license       = "MIT"

task failme, "A task that always fails":
  exec "exit 1"
