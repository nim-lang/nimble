# Copyright (C) the Nimble contributors. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, strutils, os, strformat, times
import testscommon

from nimblepkg/displaymessages import cannotUninstallPkgMsg
from nimblepkg/common import cd
from nimblepkg/version import newVersion

suite "uninstall":
  test "uninstall resolves Nim lazily when installed metadata is not cached":
    let source = getTempDir() / "nimble_uninstall_uncached_metadata"
    cdCleanDir(source):
      writeFile("uncachedremove.nimble", """
version = "0.1.0"
author = "test"
license = "MIT"
let parts = @["dynamic", "metadata"]
description = parts.join(" ")
""")
      require execNimbleYes("install", "--useSystemNim").exitCode == QuitSuccess
    let installed = getPackageDir(pkgsDir, "uncachedremove-0.1.0")
    require installed != ""
    # Force a VM parse rather than letting the install-time INI cache mask a
    # missing compiler. A future timestamp avoids filesystem time resolution.
    setLastModificationTime(installed / "uncachedremove.nimble",
                            getTime() + initDuration(seconds = 2))
    let (output, exitCode) = execNimbleYes("uninstall", "uncachedremove", "--offline")
    check exitCode == QuitSuccess
    check not output.contains("Nim binary needed but not yet resolved")
    check not dirExists(installed)

  test "uninstall restores an older binary with uncached metadata":
    let source = getTempDir() / "nimble_uninstall_uncached_older"
    cdCleanDir(source):
      for version in ["0.1.0", "0.2.0"]:
        writeFile("uncachedrestore.nimble", """
version = "$1"
author = "test"
license = "MIT"
description = "Restore an older binary"
bin = @["uncachedrestore"]
""" % version)
        writeFile("uncachedrestore.nim", "echo \"" & version & "\"\n")
        require execNimbleYes("install", "--useSystemNim").exitCode == QuitSuccess
    let older = getPackageDir(pkgsDir, "uncachedrestore-0.1.0")
    require older != ""
    setLastModificationTime(older / "uncachedrestore.nimble",
                            getTime() + initDuration(seconds = 2))
    require execNimbleYes("uninstall", "uncachedrestore@0.2.0", "--offline").exitCode == QuitSuccess
    let (output, exitCode) = execBin("uncachedrestore")
    check exitCode == QuitSuccess
    check output.strip() == "0.1.0"
    check execNimbleYes("uninstall", "uncachedrestore", "--offline").exitCode == QuitSuccess

  test "can install packagebin2":
    cleanDir(installDir)
    let args = ["install", pkgBin2Url]
    check execNimbleYes(args).exitCode == QuitSuccess

  test "can reject same version dependencies":
    cleanDir(installDir)
    let (outp, exitCode) = execNimbleYes("install", pkgBinUrl)
    # We look at the error output here to avoid out-of-order problems caused by
    # stderr output being generated and flushed without first flushing stdout
    let ls = outp.strip.processOutput()
    check exitCode != QuitSuccess
    # The resolver explains the conflict - both irreconcilable constraints on
    # packagea named - and that explanation is the *only* error: the generic
    # "Couldnt find a solution" used to be printed underneath it as well.
    check ls.inLines("version solving failed")
    check ls.inLines("packagea [0.2, 0.2]")
    check ls.inLines("packagea [0.5, 0.5]")
    check not ls.inLines("Couldnt find a solution")
    check not ls.inLines("Unsatisfiable dependencies")

  proc setupIssue27Packages() =
    # Install b
    cd "issue27/b":
      check execNimbleYes("install").exitCode == QuitSuccess
    # Install a
    cd "issue27/a":
      check execNimbleYes("install").exitCode == QuitSuccess
    cd "issue27":
      check execNimbleYes("install").exitCode == QuitSuccess

  test "issue #27":
    setupIssue27Packages()

  test "can uninstall":
    # setup test environment
    cleanDir(installDir)
    setupIssue27Packages()
    check execNimbleYes("install", &"{pkgAUrl}@0.2").exitCode == QuitSuccess
    check execNimbleYes("install", &"{pkgAUrl}@0.5").exitCode == QuitSuccess
    check execNimbleYes("install", &"{pkgAUrl}@0.6").exitCode == QuitSuccess
    check execNimbleYes("install", pkgBin2Url).exitCode == QuitSuccess
    check execNimbleYes("install", pkgBUrl).exitCode == QuitSuccess
    cd "nimscript": check execNimbleYes("install").exitCode == QuitSuccess

    block:
      let (outp, exitCode) = execNimbleYes("uninstall", "issue27b")
      check exitCode != QuitSuccess
      var ls = outp.strip.processOutput()
      let pkg27ADir = getPackageDir(pkgsDir, "issue27a-0.1.0", false)
      let expectedMsg = cannotUninstallPkgMsg(
        "issue27b", newVersion("0.1.0"), @[pkg27ADir])
      check ls.inLinesOrdered(expectedMsg)

      check execNimbleYes("uninstall", "issue27").exitCode == QuitSuccess
      check execNimbleYes("uninstall", "issue27a").exitCode == QuitSuccess

    # Remove Package*
    check execNimbleYes("uninstall", "PackageA@0.5").exitCode == QuitSuccess

    let (outp, exitCode) = execNimbleYes("uninstall", "PackageA")
    check exitCode != QuitSuccess
    let ls = outp.processOutput()
    let
      pkgBin2Dir = getPackageDir(pkgsDir, "packagebin2-0.1.0", false)
      pkgBDir = getPackageDir(pkgsDir, "packageb-0.1.0", false)
      expectedMsgForPkgA0dot6 = cannotUninstallPkgMsg(
        "PackageA", newVersion("0.6.0"), @[pkgBin2Dir])
      expectedMsgForPkgA0dot2 = cannotUninstallPkgMsg(
        "PackageA", newVersion("0.2.0"), @[pkgBDir])
    check ls.inLines(expectedMsgForPkgA0dot6)
    check ls.inLines(expectedMsgForPkgA0dot2)

    check execNimbleYes("uninstall", "PackageBin2").exitCode == QuitSuccess

    # Case insensitive
    check execNimbleYes("uninstall", "packagea").exitCode == QuitSuccess
    check execNimbleYes("uninstall", "PackageA").exitCode != QuitSuccess

    # Remove the rest of the installed packages.
    check execNimbleYes("uninstall", "PackageB").exitCode == QuitSuccess

    check execNimbleYes("uninstall", "PackageA@0.2", "issue27b").exitCode ==
        QuitSuccess
    check(not dirExists(pkgsDir / "PackageA-0.2.0"))

    check execNimbleYes("uninstall", "nimscript").exitCode == QuitSuccess
