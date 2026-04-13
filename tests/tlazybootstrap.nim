## Verifies that bootstrap Nim resolution is lazy: it only fires in branches
## that actually need a Nim binary, not eagerly at dispatch entry.
##
## Uses the NIMBLE_TRACE_BOOTSTRAP instrumentation hook in
## src/nimblepkg/nimresolution.nim, which prints "NIMBLE_BOOTSTRAP_RESOLVED"
## to stderr on every call to getBootstrapNimResolved.

{.used.}

import unittest, os, osproc, strutils, strtabs, sequtils, streams
import testscommon

proc countBootstrap(args: varargs[string], cwd = ""): tuple[count: int, exitCode: int, output: string] =
  var quotedArgs = @args
  quotedArgs.insert("--noColor")
  var envCopy = newStringTable()
  for k, v in envPairs():
    envCopy[k] = v
  envCopy["NIMBLE_TRACE_BOOTSTRAP"] = "1"
  let workdir = if cwd.len > 0: cwd else: getCurrentDir()
  let p = startProcess(
    command = nimblePath,
    workingDir = workdir,
    args = quotedArgs,
    env = envCopy,
    options = {poStdErrToStdOut, poUsePath})
  let outp = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  var n = 0
  for line in outp.splitLines():
    if line == "NIMBLE_BOOTSTRAP_RESOLVED":
      inc n
  (n, code, outp)

suite "lazy bootstrap nim resolution":
  test "--version never resolves bootstrap":
    # --version short-circuits in dispatch before any action handler runs.
    let r = countBootstrap("--version")
    checkpoint r.output
    check r.count == 0

  test "dump on declarative package resolves bootstrap at most once (memoized)":
    let r = countBootstrap("dump", cwd = getCurrentDir() / "testdump")
    checkpoint r.output
    check r.exitCode == 0
    check r.count <= 1

  test "tasks on declarative package resolves bootstrap at most once":
    let r = countBootstrap("tasks", cwd = getCurrentDir() / "testdump")
    checkpoint r.output
    check r.exitCode == 0
    check r.count <= 1

  test "check on declarative package resolves bootstrap at most once":
    let r = countBootstrap("check", cwd = getCurrentDir() / "testdump")
    checkpoint r.output
    check r.exitCode == 0
    check r.count <= 1
