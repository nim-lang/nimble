# Tests that with --skipBin hybrid packages are not compiled

{.used.}

import unittest, os, strutils
import testscommon
from nimble import nimblePathsFileName, nimbleConfigFileName
from nimblepkg/common import cd

func exe(name: string): string =
  when defined(windows): name & ".exe" else: name

template checkSkip(cmd: string, toSkip = false) =
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

template runTest(name: string,  body: untyped) =
  test name:
    cd "pkgWithHybridDep":
      cleanDir installDir
      cleanFiles nimblePathsFileName, nimbleConfigFileName
      body

suite "--skipBin":
  for command in ["setup", "install"]:
    runTest command & " without --skipBin":
      checkSkip(command, false)
    runTest command & " with --skipBin":
      checkSkip(command, true)
    runTest command & " with --skipBin then without --skipBin":
      checkSkip(command, true)
      checkSkip(command, false)

