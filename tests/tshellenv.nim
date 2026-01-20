# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, osproc, strutils
import testscommon
from nimblepkg/common import cd
import std/sequtils

const
  separator = when defined(windows): ";" else: ":"

suite "Shell env":
  test "Shell env":
    cd "shellenv":
      var (output, exitCode) = execCmdEx(nimblePath & " shellenv")
      # Debug output to diagnose CI failures
      echo "=== DEBUG: nimble shellenv output ==="
      echo "Exit code: ", exitCode
      echo "Output length: ", output.len
      echo "Output:\n", output
      echo "=== END DEBUG ==="
      check exitCode == QuitSuccess
      when not defined windows:
        # Skip potential linker warning in some MacOs versions
        let exportLines = output.splitLines.toSeq.filterIt("export" in it)
        echo "DEBUG: exportLines.len = ", exportLines.len
        if exportLines.len > 0:
          output = exportLines[0]
        else:
          echo "DEBUG: No export lines found, keeping original output"
      let prefixValPair = split(output, "=")
      echo "DEBUG: prefixValPair.len = ", prefixValPair.len
      echo "DEBUG: prefixValPair = ", prefixValPair
      let
        prefix = prefixValPair[0]
        value = if prefixValPair.len > 1: prefixValPair[1] else: ""
        dirs = value.split(separator)

      when defined windows:
        check prefix == "set PATH"
      else:
        check prefix == "export PATH"

      check "shellenv" in dirs.mapIt(it.extractFileName)
      let testUtils = "testutils-0.5.0-756d0757c4dd06a068f9d38c7f238576ba5ee897"
      check testUtils in dirs.mapIt(it.extractFileName)
