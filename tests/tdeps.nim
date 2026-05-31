# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, osproc, strutils, json
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
      # Extract JSON from output (nimble may print warnings before the JSON)
      let jsonStart = output.find('[')
      check jsonStart != stringNotFound
      let deps = parseJson(output[jsonStart .. ^1])
      check deps.len == 1
      check deps[0]["name"].getStr == "timezones"
      check deps[0]["version"].getStr == "@any"
      check deps[0]["resolvedTo"].getStr.len > 0
      check deps[0]["error"].getStr == ""
      let nimDeps = deps[0]["dependencies"]
      check nimDeps.len == 1
      check nimDeps[0]["name"].getStr == "nim"
      check nimDeps[0]["version"].getStr == ">= 0.19.9"
      check nimDeps[0]["resolvedTo"].getStr == ""
      check nimDeps[0]["error"].getStr == ""
      check nimDeps[0]["dependencies"].len == 0
