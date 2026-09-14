# Copyright (C) the Nimble contributors. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, osproc, strutils
import testscommon
from nimblepkg/common import cd
from nimblepkg/options import prependNimBinDirToPath
import std/sequtils

when not defined(windows):
  import strformat

const
  separator = when defined(windows): ";" else: ":"

proc execShellCommand(args: varargs[string]): tuple[output: string,
    exitCode: int] =
  ## Runs `nimble shell <args>`. Uses execCmdEx rather than a hand-rolled
  ## startProcess for two reasons, both of which hung this test on Windows:
  ##
  ## * execCmdEx closes the child's stdin, so a prompt inside nimble gets EOF
  ##   instead of blocking forever on a pipe nobody ever writes to. Reading the
  ##   output first and only then waiting, with stdin left open, deadlocks.
  ## * It does not override ComSpec. `nimble shell <cmd>` runs the command
  ##   directly and never consults ComSpec/SHELL, but on Windows ComSpec is what
  ##   execCmdEx uses to spawn `cmd /c ...` — pointing it at nimble.exe breaks
  ##   every nested git invocation inside the child process.
  var cmd = nimblePath.quoteShell &
    " --global --nimbleDir:" & installDir.quoteShell & " --noColor --info shell"
  for arg in args:
    cmd.add " " & arg.quoteShell
  execCmdEx(cmd)

suite "Shell env":
  test "Shell env":
    cd "shellenv":
      var (output, exitCode) = execCmdEx(nimblePath & " shellenv")
      check exitCode == QuitSuccess
      # Filter to get only the PATH line (skip DEBUG output and warnings)
      when defined(windows):
        let pathLines = output.splitLines.toSeq.filterIt(it.startsWith("set PATH"))
        if pathLines.len > 0:
          output = pathLines[0]
      else:
        # Skip potential linker warning in some MacOs versions
        let exportLines = output.splitLines.toSeq.filterIt("export" in it)
        if exportLines.len > 0:
          output = exportLines[0]
      let
        prefixValPair = split(output, "=")
        prefix = prefixValPair[0]
        value = prefixValPair[1]
        dirs = value.split(separator)

      when defined(windows):
        check prefix == "set PATH"
      else:
        check prefix == "export PATH"

      check "shellenv" in dirs.mapIt(it.extractFileName)
      let testUtils = "testutils-0.5.0-756d0757c4dd06a068f9d38c7f238576ba5ee897"
      check testUtils in dirs.mapIt(it.extractFileName)

  test "nimble shell runs a command with its arguments (#1794)":
    cd "shellenv":
      let (output, exitCode) = execShellCommand("nim", "-v")
      checkpoint(output)
      check exitCode == QuitSuccess
      check output.contains("Nim Compiler Version")

      let (failureOutput, failureExitCode) = execShellCommand(
        "nim", "definitely-not-a-nim-command")
      checkpoint(failureOutput)
      check failureExitCode == QuitFailure

  when not defined(windows):
    test "nimble shell does not crash when dependencies are deleted inside shell":
      cd "shellenv":
        # Create a script that deletes nimbledeps then exits,
        # simulating a user running git clean -ffdx inside nimble shell
        let script = getCurrentDir() / "cleanup_shell.sh"
        writeFile(script, "#!/bin/sh\nrm -rf nimbledeps nimble.paths nimble.develop\n")
        inclFilePermissions(script, {fpUserExec})
        defer: removeFile(script)
        # Ensure nimble.paths and nimbledeps exist before the test
        let (_, setupExitCode) = execNimble("setup")
        check setupExitCode == QuitSuccess
        check fileExists("nimble.paths")
        # Run nimble shell with our cleanup script as SHELL
        let cmd = &"SHELL={script} {nimblePath} --nimbleDir:{installDir} -l shell"
        let (output, exitCode) = execCmdEx(cmd)
        checkpoint(output)
        # Should exit cleanly without assertion errors
        check exitCode == QuitSuccess
        check "AssertionDefect" notin output
        # Restore nimbledeps for other tests
        discard execNimble("setup")

  test "the running nimble stays ahead of the selected nim's bin dir on PATH (#1840)":
    # Nim distributions ship a `nimble` next to `nim`. When nimble puts the
    # selected nim's bin dir in front of PATH for tasks and hooks, that bundled
    # (usually older) nimble must not shadow the one that is running, or a
    # nested `nimble ...` call from a task silently switches versions.
    let originalPath = getEnv("PATH")
    defer: putEnv("PATH", originalPath)
    let nimBinDir = getTempDir() / "nimble_test_1840_nim" / "bin"
    prependNimBinDirToPath(nimBinDir)
    let entries = getEnv("PATH").split(separator)
    check entries[0] == getAppDir()
    check entries[1] == nimBinDir
    check entries[2 .. ^1].join(separator) == originalPath

