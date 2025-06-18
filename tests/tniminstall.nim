
{.used.}

import unittest, os, strutils
import testscommon
from nimblepkg/common import cd


# proc isNimPkgVer(folder: string, ver: string): bool = 
#   let nimPkg = getPkgInfoFromDirWithDeclarativeParser(folder, initOptions())
#   echo "Checking ", folder, " for ", ver, " result: ", nimPkg.basicInfo.name, " ", $nimPkg.basicInfo.version
#   result = nimPkg.basicInfo.name == "nim" and nimPkg.basicInfo.version == newVersion(ver)


suite "Nim install":
  test "Should be able to install different Nim versions":
    cd "nimnimble":
      for nimVerDir in ["nim2.0.4"]:
        cd nimVerDir:
          # let nimVer = nimVerDir.replace("nim", "")
          let (output, exitCode) = execNimble("install", "-l")
          # let pkgPath = getCurrentDir() / "nimbledeps" / "pkgs2"
          check exitCode == QuitSuccess
          # check walkDir(pkgPath).toSeq.anyIt(it[1].isNimPkgVer(nimVer))  
          # echo output    
          check output.contains("nim-2.0.4")