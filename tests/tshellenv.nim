# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, osproc, strutils
import testscommon
from nimblepkg/common import cd

const
  separator = when defined(windows): ";" else: ":"

suite "Shell env":
  test "Shell env":
    cd "shellenv":
      let (output, exitCode) = execCmdEx(nimblePath & " shellenv")
      check exitCode == QuitSuccess
      let
        prefixValPair = split(output, "=")
        prefix = prefixValPair[0]
        value = prefixValPair[1]
        dirs = value.split(separator)

      when defined windows:
        check prefix == "set PATH"
        const extension = ".exe"
      else:
        const extension = ""
        check prefix == "export PATH"

      check (dirs[0] / ("nim" & extension)).fileExists
      check dirs[1].extractFileName == "shellenv"
      check dirs[2].extractFileName == "testutils-0.5.0-756d0757c4dd06a068f9d38c7f238576ba5ee897"
