discard """
  exitcode: 0
"""

import os, ../common
from nimblepkg/common import cd

createDir("issue581/src")
cd "issue581":
  const Src = "echo \"OK\""
  writeFile("src/issue581.nim", Src)
  doAssert execNimbleYes("init").exitCode == QuitSuccess, "init failed"
  doAssert readFile("src/issue581.nim") == Src, "file was overwritten"
removeDir("issue581")
