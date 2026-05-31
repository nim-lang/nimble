# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os
import common
import std/[strformat, strutils, sequtils]
from nimblepkg/common import cd

suite "nimble dump":
  test "can dump for current project":
    cd "testdump":
      let (outp, exitCode) = execNimble("dump")
      check: exitCode == 0
      check: outp.processOutput.inLines("desc: \"Test package for dump command\"")

  test "can dump for project directory":
    let (outp, exitCode) = execNimble("dump", "testdump")
    check: exitCode == 0
    check: outp.processOutput.inLines("desc: \"Test package for dump command\"")

  test "can dump for project file":
    let (outp, exitCode) = execNimble("dump", "testdump" / "testdump.nimble")
    check: exitCode == 0
    check: outp.processOutput.inLines("desc: \"Test package for dump command\"")

  test "can dump for installed package":
    cd "testdump":
      check: execNimbleYes("install").exitCode == 0
    defer:
      discard execNimbleYes("remove", "testdump")

    # Otherwise we might find subdirectory instead
    cd "..":
      let (outp, exitCode) = execNimble("dump", "testdump")
      check: exitCode == 0
      check: outp.processOutput.inLines("desc: \"Test package for dump command\"")

  test "can dump for project file with absolute path":
    let absPath = getCurrentDir() / "testdump" / "testdump.nimble"
    let (outp, exitCode) = execNimble("dump", absPath)
    check: exitCode == 0
    check: outp.processOutput.inLines("desc: \"Test package for dump command\"")

  test "can dump when explicitly asking for INI format":
    let nimDir = parentDir findExe "nim"
    let nimblePath = "testdump" / "testdump.nimble"

    let outpExpected = &"""
name: "testdump"
version: "0.1.0"
nimblePath: {nimblePath.escape}
author: "nigredo-tori"
desc: "Test package for dump command"
license: "BSD"
skipDirs: ""
skipFiles: ""
skipExt: ""
installDirs: ""
installFiles: ""
installExt: ""
requires: ""
bin: ""
binDir: ""
srcDir: ""
backend: "c"
paths: "path"
nimDir: {nimDir.escape}
entryPoints: "testdump.nim, entrypoint.nim"
testEntryPoint: "tests/tall.nim"
"""
    let (outp, exitCode) = execNimble("dump", "--ini", "testdump")
    check: exitCode == 0
    # nimDir may differ when a nim package is installed in nimbleDir (e.g. by tnimbinaries)
    let outpNormalized = outp.splitLines.filterIt(not it.startsWith("nimDir:")).join("\n")
    let expectedNormalized = outpExpected.splitLines.filterIt(not it.startsWith("nimDir:")).join("\n")
    check: outpNormalized == expectedNormalized

  test "can dump in JSON format":
    let nimDir = parentDir findExe "nim"
    let nimblePath = "testdump" / "testdump.nimble"

    let outpExpected = &"""
{{
  "name": "testdump",
  "version": "0.1.0",
  "nimblePath": {nimblePath.escape},
  "author": "nigredo-tori",
  "desc": "Test package for dump command",
  "license": "BSD",
  "skipDirs": [],
  "skipFiles": [],
  "skipExt": [],
  "installDirs": [],
  "installFiles": [],
  "installExt": [],
  "requires": [],
  "bin": [],
  "binDir": "",
  "srcDir": "",
  "backend": "c",
  "paths": [
    "path"
  ],
  "nimDir": {nimDir.escape},
  "entryPoints": [
    "testdump.nim",
    "entrypoint.nim"
  ],
  "testEntryPoint": "tests/tall.nim"
}}
"""
    let (outp, exitCode) = execNimble("dump", "--json", "testdump")
    check: exitCode == 0
    # nimDir may differ when a nim package is installed in nimbleDir (e.g. by tnimbinaries)
    let outpNormalized = outp.splitLines.filterIt(not it.startsWith("  \"nimDir\":")).join("\n")
    let expectedNormalized = outpExpected.splitLines.filterIt(not it.startsWith("  \"nimDir\":")).join("\n")
    check: outpNormalized == expectedNormalized
