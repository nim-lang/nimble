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
    # locally, `solveLocalPackages` correctly refuses to solve — dump falls
    # back to the available nim binary's parent directory so the langserver
    # can still provide completions even when some deps are missing.
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
      let nimDir = parentDir findExe "nim"
      check outp.processOutput.inLines("nimDir: " & nimDir.escape)

  test "dump does not leak declarative-parser errors on normal verbosity (#1717)":
    # Regression for nim-lang/nimble#1717: a nimble file whose `srcDir`/`bin`/
    # `paths` are not string literals used to make the declarative parser emit a
    # Nim compiler error straight to stdout/stderr, bypassing Nimble's verbosity.
    # When resolving a project every installed package is parsed, so unrelated
    # packages' diagnostics leaked into machine-readable `nimble dump` output.
    # Non-literal values must instead route to the VM parser (like a non-literal
    # version), which evaluates them without emitting a raw error.
    let root = getTempDir() / "nimble1717"
    defer: removeDir root

    const winExe = when defined(windows): ".exe" else: ""
    # (field, non-literal .nimble body, expected resolved dump line)
    let cases = @[
      ("srcDir", "const v = \"customsrc\"\nsrcDir = v", "srcDir: \"customsrc\""),
      ("bin", "const v = \"mytool\"\nbin = @[v]", "bin: \"mytool" & winExe & "\""),
      ("paths", "const v = \"mysrc\"\npaths = @[v]", "paths: \"mysrc\""),
    ]
    for (field, body, expected) in cases:
      let badNimble = root / field / "bad.nimble"
      createDir badNimble.parentDir
      writeFile(badNimble, """
version = "0.1.0"
author = "x"
description = "a package whose """ & field & """ is not a string literal"
license = "MIT"
""" & body & "\n")

      let (outp, exitCode) = execNimble("dump", badNimble)
      check exitCode == QuitSuccess
      # No raw compiler diagnostic leaks into the dump output...
      check "must be" notin outp
      check "sequence items" notin outp
      # ...and the value is still resolved correctly via the VM fallback.
      check outp.processOutput.inLines(expected)

  test "dump does not leak a broken installed dependency's syntax errors (#1717)":
    # The other half of #1717: an installed dependency with a genuine *syntax*
    # error is parsed by the declarative parser during the solve. Those errors
    # come from the Nim parser itself (not a field check), so they can't be
    # "not produced" — the parser config must route compiler output nowhere.
    # They must not leak into dump's machine-readable output. Use an isolated
    # nimbleDir so the deliberately-broken package can't affect other tests.
    let nbDir = getTempDir() / "nimble1717nb"
    removeDir nbDir
    defer: removeDir nbDir
    let depDir = nbDir / "pkgs2" / "depbad-0.1.0-1111111111111111111111111111111111111111"
    createDir depDir
    writeFile(depDir / "depbad.nimble", """
version = "0.1.0"
author = "x"
description = "d"
license = "MIT"
requires "foo" @#bad syntax here
""")
    writeFile(depDir / "nimblemeta.json",
      """{"version":1,"metaData":{"url":"http://example.com/depbad",""" &
      """"downloadMethod":"git","vcsRevision":"1111111111111111111111111111111111111111",""" &
      """"files":["depbad.nimble"],"binaries":[],"specialVersions":["0.1.0"],"isLink":false}}""")

    let projDir = getTempDir() / "nimble1717proj"
    createDir projDir
    defer: removeDir projDir
    writeFile(projDir / "proj.nimble", """
version = "0.2.0"
author = "me"
description = "demo"
license = "MIT"
requires "depbad >= 0.1.0"
""")
    let (outp, _) = execNimble("dump", "--nimbleDir:" & nbDir, projDir / "proj.nimble")
    check "invalid indentation" notin outp
    check "expression expected" notin outp
    check "depbad.nimble(" notin outp

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
