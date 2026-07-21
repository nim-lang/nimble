# Regression fixture for issue #1779.
# Uses Nim's style-insensitive `src_dir` (snake_case) instead of `srcDir`.
# The declarative parser must treat them as equivalent so the binary sources
# under src/ are found.
version       = "0.1.0"
author        = "test"
description   = "style-insensitive nimble fields (#1779)"
license       = "MIT"
src_dir       = "src"
bin           = @["snakecasefields"]

requires "nim >= 1.6.0"
