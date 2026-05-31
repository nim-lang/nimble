discard """
  exitcode: 0
"""

import os, strutils, ../common
from nimblepkg/common import cd

cd "../issue1609":
  let binDir = getCurrentDir() / "bin"
  let nimWrapper = binDir / (when defined(windows): "nim.cmd" else: "nim")

  proc checkWrapperInvoked(log: string, args: varargs[string]) =
    cleanFiles log, "issue1609"
    let res = execNimble(args)
    verify res
    doAssert res.output.contains("Executing $1 c" % nimWrapper), "wrapper not invoked"
    doAssert fileExists(log), "log file not created"
    doAssert readFile(log).contains("c "), "log doesn't contain 'c '"

  # Check 1: wrapper specified via --nim
  checkWrapperInvoked(binDir / "calls.log", "--useSystemNim", "--nim:" & nimWrapper, "--debug", "build")

  # Check 2: wrapper discovered via PATH (no --nim flag).
  let sep = when defined(windows): ";" else: ":"
  let oldPath = getEnv("PATH")
  putEnv("PATH", binDir & sep & oldPath)
  checkWrapperInvoked(binDir / "calls.log", "--useSystemNim", "--debug", "build")
  putEnv("PATH", oldPath)
