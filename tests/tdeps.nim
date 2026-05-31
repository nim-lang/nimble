# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, osproc, strutils, strformat
import common
from nimblepkg/common import cd

suite "nimble deps":
  test "nimble deps":
    cd "deps":
      let (output, exitCode) = execCmdEx(nimblePath & " --silent deps -y")
      check exitCode == QuitSuccess
      check output.contains("deps (@0.1.0)")
      check output.contains("timezones 0.5.4 (@0.5.4)")

  test "nimble deps(json)":
    cd "issue727":
      let (output, exitCode) = execCmdEx(nimblePath & " --format:json deps -y")
      check exitCode == QuitSuccess
      check output.contains("\"name\": \"timezones\"")
      check output.contains("\"version\": \"@any\"")
      check output.contains("\"resolvedTo\": \"")
      check output.contains("\"error\": \"")
      check output.contains("\"name\": \"nim\"")
      check output.contains("\"version\": \">= 0.19.9\"")
      check output.contains("\"dependencies\": []")
