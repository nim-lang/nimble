discard """
  exitcode: 0
"""

import os, strutils, osproc, strformat
import ../common
from nimblepkg/common import cd, nimblePackagesDirName

proc main() =
  let testsDir = currentSourcePath().parentDir.parentDir
  let issueDir = testsDir / "issue428"
  let localNimbleDir = issueDir / "nimbleDir"
  removeDir(localNimbleDir)
  defer: removeDir(localNimbleDir)

  cd issueDir:
    let (_, exitCode) = execCmdEx(
      &"{nimblePath} -y --nimbleDir={localNimbleDir} install -g")
    doAssert exitCode == QuitSuccess
    let dummyPkgDir = getPackageDir(
      localNimbleDir / nimblePackagesDirName, "dummy-0.1.0")
    doAssert dummyPkgDir.dirExists
    doAssert not (dummyPkgDir / "nimbleDir").dirExists

main()
