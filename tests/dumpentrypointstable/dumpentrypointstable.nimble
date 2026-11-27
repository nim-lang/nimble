# Package

version       = "0.1.0"
author        = "nimble"
description   = "Binaries in entryPoints, from a namedBin built as a whole table"
license       = "MIT"
srcDir        = "src"

import std/tables
namedBin = {"cli/main": "mytool"}.toTable()
