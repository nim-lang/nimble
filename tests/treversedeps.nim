# Copyright (C) the Nimble contributors. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, strutils, json
import testscommon

from nimblepkg/common import cd

suite "reverse dependencies":
  test "basic test":
    cd "revdep/mydep":
      verify execNimbleYes("install")

    cd "revdep/pkgWithDep":
      verify execNimbleYes("install")

    verify execNimbleYes("remove", "pkgA")
    verify execNimbleYes("remove", "mydep")

  test "revdep fail test":
    cd "revdep/mydep":
      verify execNimbleYes("install")

    cd "revdep/pkgWithDep":
      verify execNimbleYes("install")

    let (output, exitCode) = execNimble("uninstall", "mydep")
    checkpoint output
    check output.processOutput.inLines("cannot uninstall mydep")
    check exitCode == QuitFailure

  test "revdep -i test":
    cd "revdep/mydep":
      verify execNimbleYes("install")

    cd "revdep/pkgWithDep":
      verify execNimbleYes("install")

    verify execNimbleYes("remove", "mydep", "-i")

  test "issue #373":
    cd "revdep/mydep":
      verify execNimbleYes("install")

    cd "revdep/pkgWithDep":
      verify execNimbleYes("install")

    verify execNimbleYes("remove", "pkgA")

    cd "revdep/pkgNoDep":
      verify execNimbleYes("install")

    verify execNimbleYes("remove", "mydep")

  test "remove skips packages with revDeps (#504)":
    var (output, exitCode) = execNimbleYes(
      "install", "nimboost@0.5.5", "nimfp@0.4.4")
    check exitCode == QuitSuccess

    (output, exitCode) = execNimble("uninstall", "nimboost", "nimfp", "-n")
    var lines = output.strip.processOutput()
    check inLines(lines, "Cannot uninstall nimboost")

    (output, exitCode) = execNimbleYes("uninstall", "nimfp", "nimboost")
    lines = output.strip.processOutput()
    check (not inLines(lines, "Cannot uninstall nimboost"))

    check execNimble("path", "nimboost").exitCode != QuitSuccess
    check execNimble("path", "nimfp").exitCode != QuitSuccess

  test "stale develop reverse dep does not block remove (#1831)":
    # Install mydep first (the resolver finds it through the local
    # nimble dir, as in the "basic test" above), then the pkgWithDep
    # fixture (whose package name is pkgA and which requires mydep) so
    # that mydep gets a real reverse-dep record.
    cd "revdep/mydep":
      verify execNimbleYes("install")
    cd "revdep/pkgWithDep":
      verify execNimbleYes("install")

    let dataFile = installDir / "nimbledata2.json"
    var (verKey, csKey) = ("", "")
    block:
      let data = parseFile(dataFile)
      for v, hashSums in data["reverseDeps"]["mydep"]:
        verKey = v
        for c, _ in hashSums:
          csKey = c
    require verKey != ""

    # Remove the normal reverse dependency so mydep has none left.
    verify execNimbleYes("remove", "pkgA")

    # Inject a stale develop-mode record: the project directory exists,
    # but its .nimble does not require mydep. Without pruning, this
    # record keeps mydep "in use" forever (report: #1831).
    let staleDir = installDir.parentDir / "staleUser1831"
    removeDir(staleDir)
    createDir(staleDir / "src")
    writeFile(staleDir / "staleUser.nimble",
              "version = \"0.1.0\"\nauthor = \"test\"\n" &
              "description = \"No mydep here\"\nlicense = \"MIT\"\n")
    writeFile(staleDir / "staleUser.nim", "echo \"stale\"\n")
    var data = parseFile(dataFile)
    data["reverseDeps"]["mydep"] =
      %{verKey: %{csKey: %[%{"path": %($staleDir)}]}}
    writeFile(dataFile, data.pretty)

    # The stale record is pruned and the remove succeeds.
    let (output, exitCode) = execNimbleYes("remove", "mydep")
    checkpoint output
    check exitCode == QuitSuccess

    # The pruned record is also persisted.
    let dataAfter = parseFile(dataFile)
    check dataAfter{"reverseDeps"}{"mydep"}.isNil

  test "live develop reverse dep still blocks remove":
    cd "revdep/mydep":
      verify execNimbleYes("install")
    cd "revdep/pkgWithDep":
      verify execNimbleYes("install")

    let dataFile = installDir / "nimbledata2.json"
    var (verKey, csKey) = ("", "")
    block:
      let data = parseFile(dataFile)
      for v, hashSums in data["reverseDeps"]["mydep"]:
        verKey = v
        for c, _ in hashSums:
          csKey = c
    require verKey != ""

    # Point an extra develop-mode record at pkgWithDep, whose .nimble
    # DOES require mydep: this record must survive the pruning.
    let liveDir = testsDir / "revdep" / "pkgWithDep"
    var data = parseFile(dataFile)
    data["reverseDeps"]["mydep"][verKey][csKey].add(%*{"path": %($liveDir)})
    writeFile(dataFile, data.pretty)

    let (output, exitCode) = execNimble("uninstall", "mydep")
    checkpoint output
    check output.processOutput.inLines("cannot uninstall mydep")
    check exitCode == QuitFailure
