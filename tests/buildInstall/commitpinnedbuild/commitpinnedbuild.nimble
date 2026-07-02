# Regression fixture for issue #1752.
# Depends on a commit-pinned package that gets installed into pkgs2. Building a
# second time must still find the dependency's sources.
version       = "0.1.0"
author        = "test"
description   = "commit-pinned dependency rebuild regression (#1752)"
license       = "MIT"
srcDir        = "src"
bin           = @["commitpinnedbuild"]

requires "nim >= 2.0.0"
requires "https://github.com/nim-lang/uirelays#688dd44"
