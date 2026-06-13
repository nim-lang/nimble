discard """
  exitcode: 0
"""

import os, osproc, strutils, ../common
from nimblepkg/common import cd

cd "../issue727":
  # Clean stale build artifacts from previous runs
  removeFile("src/abc".addFileExt(ExeExt))
  removeFile("abc".addFileExt(ExeExt))
  removeFile("def".addFileExt(ExeExt))

  # Use default nimbleDir (like tdeps.nim) where timezones is cached
  let (output1, exitCode1) = execCmdEx(nimblePath & " --noColor c src/abc")
  doAssert exitCode1 == QuitSuccess, output1
  doAssert fileExists("src/abc".addFileExt(ExeExt)), "abc should be at src/abc"
  doAssert not fileExists("abc".addFileExt(ExeExt)), "abc should not be in root"
  doAssert not fileExists("def".addFileExt(ExeExt)), "def should not exist yet"

  let (output2, exitCode2) = execCmdEx(nimblePath & " --noColor run def")
  doAssert exitCode2 == QuitSuccess, output2
  doAssert output2.contains("def727"), output2
  doAssert not fileExists("abc".addFileExt(ExeExt)), "abc should not be in root after run"
  doAssert fileExists("def".addFileExt(ExeExt)), "def should be in root"

  echo "issue727 passed"
