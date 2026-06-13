discard """
  exitcode: 0
"""

import os, strutils, osproc
import ../common
from nimblepkg/common import cd

proc main() =
  let testsDir = currentSourcePath().parentDir.parentDir
  # file:// requires a git repo, so init one for the dep fixture
  let depDir = testsDir / "issue1650dep"
  discard execCmdEx("git -C " & depDir.quoteShell & " init")
  discard execCmdEx("git -C " & depDir.quoteShell & " config user.name \"Test\"")
  discard execCmdEx("git -C " & depDir.quoteShell & " config user.email \"test@test.com\"")
  discard execCmdEx("git -C " & depDir.quoteShell & " add -A")
  discard execCmdEx("git -C " & depDir.quoteShell & " commit -m init")
  defer: removeDir(depDir / ".git")

  # Point --nimbleDir inside issue1650/ so buildtemp ends up inside the project
  # dir tree, reproducing the nimbledeps layout where Nim walks up from the
  # dep source and finds the root project's config.nims.
  let localNimbleDir = testsDir / "issue1650" / "testnimbledir"
  defer: removeDir(localNimbleDir)
  let (output, exitCode) = execNimbleYes("install", "--nimbleDir:" & localNimbleDir, "file://" & depDir)
  doAssert exitCode == QuitSuccess, output
  doAssert output.contains("installed successfully"), output

main()
