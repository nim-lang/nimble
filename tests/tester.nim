# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
import osproc, streams, unittest, strutils, os, sequtils, future

const path = "../src/nimble"

test "can compile nimble":
  check execCmdEx("nim c " & path).exitCode == QuitSuccess

template cd*(dir: string, body: stmt) =
  ## Sets the current dir to ``dir``, executes ``body`` and restores the
  ## previous working dir.
  let lastDir = getCurrentDir()
  setCurrentDir(dir)
  body
  setCurrentDir(lastDir)

proc execCmdEx2*(command: string, options: set[ProcessOption] = {
                poUsePath}): tuple[
                output: TaintedString,
                error: TaintedString,
                exitCode: int] {.tags: [ExecIOEffect, ReadIOEffect], gcsafe.} =
  ## A slightly altered version of osproc.execCmdEx
  ## Runs the `command` and returns the standard output, error output, and
  ## exit code.
  var p = startProcess(command = command, options = options + {poEvalCommand})
  var outp = outputStream(p)
  var errp = errorStream(p)
  result = (TaintedString"", TaintedString"", -1)
  var outLine = newStringOfCap(120).TaintedString
  var errLine = newStringOfCap(120).TaintedString
  while true:
    var checkForExit = true
    if outp.readLine(outLine):
      result[0].string.add(outLine.string)
      result[0].string.add("\n")
      checkForExit = false
    if errp.readLine(errLine):
      result[1].string.add(errLine.string)
      result[1].string.add("\n")
      checkForExit = false
    if checkForExit:
      result[2] = peekExitCode(p)
      if result[2] != -1: break
  close(p)

proc processOutput(output: string): seq[string] =
  output.strip.splitLines().filter((x: string) => (x.len > 0))

test "can install packagebin2":
  check execCmdEx(path &
      " install -y https://github.com/nimble-test/packagebin2.git").exitCode ==
      QuitSuccess

test "can reject same version dependencies":
  let (outp, errp, exitCode) = execCmdEx2(path &
      " install -y https://github.com/nimble-test/packagebin.git")
  # We look at the error output here to avoid out-of-order problems caused by
  # stderr output being generated and flushed without first flushing stdout
  let ls = errp.strip.splitLines()
  check exitCode != QuitSuccess
  check ls[ls.len-1] == "Error: unhandled exception: Cannot satisfy the " &
      "dependency on PackageA 0.2.0 and PackageA 0.5.0 [NimbleError]"

test "can update":
  check execCmdEx(path & " update").exitCode == QuitSuccess

test "issue #27":
  # Install b
  cd "issue27/b":
    check execCmdEx("../../" & path & " install -y").exitCode == QuitSuccess

  # Install a
  cd "issue27/a":
    check execCmdEx("../../" & path & " install -y").exitCode == QuitSuccess

  cd "issue27":
    check execCmdEx("../" & path & " install -y").exitCode == QuitSuccess

test "can uninstall":
  block:
    let (outp, errp, exitCode) = execCmdEx2(path & " uninstall -y issue27b")
    # let ls = outp.processOutput()
    let ls = errp.strip.splitLines()
    check exitCode != QuitSuccess
    check ls[ls.len-1] == "  Cannot uninstall issue27b (0.1.0) because " &
                          "issue27a (0.1.0) depends on it [NimbleError]"

    check execCmdEx(path & " uninstall -y issue27").exitCode == QuitSuccess
    check execCmdEx(path & " uninstall -y issue27a").exitCode == QuitSuccess

  # Remove Package*
  check execCmdEx(path & " uninstall -y PackageA@0.5").exitCode == QuitSuccess

  let (outp, errp, exitCode) = execCmdEx2(path & " uninstall -y PackageA")
  check exitCode != QuitSuccess
  let ls = errp.processOutput()
  check ls[ls.len-2].startsWith("  Cannot uninstall PackageA ")
  check ls[ls.len-1].startsWith("  Cannot uninstall PackageA ")
  check execCmdEx(path & " uninstall -y PackageBin2").exitCode == QuitSuccess

  # Case insensitive
  check execCmdEx(path & " uninstall -y packagea").exitCode == QuitSuccess
  check execCmdEx(path & " uninstall -y PackageA").exitCode != QuitSuccess

  # Remove the rest of the installed packages.
  check execCmdEx(path & " uninstall -y PackageB").exitCode == QuitSuccess

  check execCmdEx(path & " uninstall -y PackageA@0.2 issue27b").exitCode ==
      QuitSuccess
  check (not dirExists(getHomeDir() / ".nimble" / "pkgs" / "PackageA-0.2.0"))
