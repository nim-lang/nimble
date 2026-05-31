discard """
  exitcode: 0
"""

import os, strutils, ../common

let reservedNames = [
  "CON", "PRN", "AUX", "NUL",
  "COM1", "COM2", "COM3", "COM4", "COM5",
  "COM6", "COM7", "COM8", "COM9",
  "LPT1", "LPT2", "LPT3", "LPT4", "LPT5",
  "LPT6", "LPT7", "LPT8", "LPT9",
]

proc checkName(name: string) =
  let (outp, code) = execNimbleYes("init", name)
  let msg = outp.strip.processOutput()
  doAssert code == QuitFailure, "expected failure for " & name
  doAssert inLines(msg, "\"$1\" is an invalid package name: reserved name" % name),
    "unexpected message for " & name & ": " & msg.join("\n")
  try:
    removeFile(name.changeFileExt("nimble"))
    removeDir("src")
    removeDir("tests")
  except OSError:
    discard

for reserved in reservedNames:
  checkName(reserved.toUpperAscii())
  checkName(reserved.toLowerAscii())
