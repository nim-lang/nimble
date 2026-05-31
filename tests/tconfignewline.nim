discard """
  exitcode: 0
"""

import os, strutils, sequtils

let configFile = readFile(currentSourcePath().parentDir.parentDir / "config.nims")
let content = configFile.splitLines.toSeq()
doAssert content[^2].strip() == ""
doAssert content[^1].strip() == ""
