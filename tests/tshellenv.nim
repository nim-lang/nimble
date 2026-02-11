# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, osproc, strutils
import testscommon
from nimblepkg/common import cd
import std/sequtils

when not defined(windows):
  import strformat

const
  separator = when defined(windows): ";" else: ":"

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
