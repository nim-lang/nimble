{.used.}

import unittest, os, osproc
import testscommon
from nimblepkg/common import cd

suite "build lib":
  test "build lib":
    const
      projectName = "libproject"
      libName = "lib" & projectName
      libExt =
        when defined linux:
          ".so"
        elif defined windows:
          ".dll"
        elif defined osx:
          ".dynlib"

    cd projectName:
      let (output, exitCode) = execCmdEx(nimblePath & " build")
      check exitCode == QuitSuccess
      check (libName & libExt).fileExists()
