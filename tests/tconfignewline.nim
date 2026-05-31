discard """
  exitcode: 0
"""

import os, strutils, sequtils

let configFile = readFile("config.nims")
let content = configFile.splitLines.toSeq()
doAssert content[^2].strip() == ""
doAssert content[^1].strip() == ""
