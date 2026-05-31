version       = "0.1.0"
author        = "test"
description   = "Test fixture with nested requires"
license       = "MIT"

when defined(windows):
  requires "winapi"
else:
  requires "posix"
