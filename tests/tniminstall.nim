
{.used.}

import unittest, os, strutils, sequtils, strscans
import testscommon
from nimblepkg/common import cd

proc isNimPkgVer(folder: string, ver: string): bool = 
  let name = folder.split("-")
  result = name.len == 3 and name[1].contains(ver)
  echo "Checking ", folder, " for ", ver, " result: ", result
  if ver == "devel":
  #We know devel is bigger than 2.1 and it should be an odd number (notice what we test here is actually the #)
    var major, minor, patch: int 
    if scanf(name[1], "$i.$i.$i", major, minor, patch):
      return major >= 2 and minor >= 1 and minor mod 2 == 1
    else: return false


suite "Nim install":
  test "Should be able to install different Nim versions":
    cd "nimnimble":
      for nimVerDir in ["nim1.6.20", "nim2.0.4"]:
        cd nimVerDir:
          let nimVer = nimVerDir.replace("nim", "")
          echo "Checking version ", nimVer
          let (_, exitCode) = execNimble("install", "-l")
          let pkgPath = getCurrentDir() / "nimbledeps" / "pkgs2"
          echo "Checking ", pkgPath
          check exitCode == QuitSuccess
          check walkDir(pkgPath).toSeq.anyIt(it[1].isNimPkgVer(nimVer))      
