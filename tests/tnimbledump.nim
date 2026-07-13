# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os
import testscommon
import std/[strformat, strutils]
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

  test "nimble dump skips dep discovery when local solve fails (#1713)":
    # Regression for nim-lang/nimble#1713: dump must be a read-only operation
    # and never trigger network discovery. When a dep isn't installed
    # locally, `solveLocalPackages` correctly refuses to solve — dump should
    # return `nimDir: ""` so the langserver can detect the situation and
    # prompt the user to run `nimble install` instead of waiting on a hung
    # `processRequirements` walk.
    cleanDir installDir
    cd "testdump":
      # Write a temp .nimble that requires a package guaranteed not installed.
      let nimbleBackup = readFile("testdump.nimble")
      defer: writeFile("testdump.nimble", nimbleBackup)
      writeFile("testdump.nimble", """
description = "Test package for dump command"
version = "0.1.0"
author = "nigredo-tori"
license = "BSD"

requires "definitely_not_installed_pkg_xyz"
""")
      let (outp, exitCode) = execNimble("dump")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("nimDir: \"\"")

  test "dump does not leak declarative-parser errors on normal verbosity (#1717)":
    # Regression for nim-lang/nimble#1717: a nimble file whose `srcDir` is not a
    # string literal used to make the declarative parser emit a Nim compiler
    # error straight to stdout/stderr, bypassing Nimble's verbosity.
    let badNimble = getTempDir() / "nimble1717" / "badsrc.nimble"
    createDir badNimble.parentDir
    defer: removeDir badNimble.parentDir
    writeFile(badNimble, """
version = "0.1.0"
author = "x"
description = "a package whose srcDir is not a string literal"
license = "MIT"
const sd = "customsrc"
srcDir = sd
""")

    let (outp, exitCode) = execNimble("dump", badNimble)
    check exitCode == QuitSuccess
    # No raw compiler diagnostic leaks into the dump output...
    check "must be string literals" notin outp
    # ...and the value is still resolved correctly via the VM fallback.
    check outp.processOutput.inLines("srcDir: \"customsrc\"")

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
    check: outp == outpExpected

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
    check: outp == outpExpected
