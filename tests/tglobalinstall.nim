
{.used.}

import unittest, os
import testscommon
from nimblepkg/common import cd

suite "Global install":
  test "can install a package with a binDir directory":
    removeDir("nimbleDir")
    defer:
      removeDir("globalinstall")
    createDir("globalinstall")
    cd "globalinstall":
      let (_, exitCode) = execNimble("install", "nimtetris")
      check exitCode == QuitSuccess