# Tests that with --skipBin hybrid packages are not compiled

{.used.}

import unittest, os, strutils
import testscommon
from nimble import nimblePathsFileName, nimbleConfigFileName
from nimblepkg/common import cd

suite "skip compilation of hybrid packages with --skipBin":
  for cmd in ["setup", "install"]:
    test cmd & " with --skipBin then without --skipBin":
      cd "pkgWithHybridDep":
        cleanDir installDir
        cleanFiles nimblePathsFileName, nimbleConfigFileName
        for toSkip in [true, false]:
          var args = @[cmd]
          if toSkip: args.add "--skipBin"
          let res = execNimbleYes(args)
          verify res
          let hybridPkgDir = getPackageDir(pkgsDir, "hybrid")
          check hybridPkgDir.len > 0
          check "Building hybrid/hybrid" in res.output != toSkip
          check fileExists(
            hybridPkgDir / "hybrid" & (when defined(windows): ".exe" else: "")
          ) != toSkip
          check fileExists(installDir / "bin" / "hybrid") != toSkip
          # --skipBin should not effect the root package
          if cmd == "install":
            check fileExists(installDir / "bin" / "pkgWithHybridDep")
