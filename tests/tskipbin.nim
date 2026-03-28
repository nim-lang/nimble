# Tests that with --skipBin hybrid packages ares not compiled
# packages are built in a temp directory and only necessary files are installed

{.used.}

import unittest, os, strutils
import testscommon
from nimble import nimblePathsFileName, nimbleConfigFileName
from nimblepkg/common import cd

func exe(name: string): string =
  when defined(windows): name & ".exe" else: name

template checkSkip(cmd: string, toSkip = false) =
  cd "pkgWithHybridDep":
    cleanDir installDir
    cleanFiles nimblePathsFileName, nimbleConfigFileName
    var args = @[cmd]
    if toSkip: args.add "--skipBin"
    let res = execNimbleYes(args)
    verify res
    let hybridPkgDir = getPackageDir(pkgsDir, "hybrid")
    check hybridPkgDir.len > 0
    check "Building hybrid/hybrid" in res.output != toSkip
    check fileExists(hybridPkgDir / "hybrid".exe) != toSkip
    check fileExists(installDir / "bin" / "hybrid") != toSkip
    # --skipBin should not effect the root package
    if cmd == "install":
      check fileExists(installDir / "bin" / "pkgWithHybridDep")

suite "--skipBin":
  for command in ["setup", "install"]:
    test command & " without --skipBin":
      checkSkip(command, false)
    test command & " with --skipBin":
      checkSkip(command, true)

