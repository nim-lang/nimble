# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, osproc
from nimblepkg/common import cd

suite "Module tests":
  template moduleTest(moduleName: string) =
    test moduleName:
      cd "..":
        check execCmdEx("nim c -r src/nimblepkg/" & moduleName).
          exitCode == QuitSuccess

  moduleTest "aliasthis"
  moduleTest "common"
  moduleTest "download"
  moduleTest "jsonhelpers"
  moduleTest "packageinfo"
  moduleTest "packageparser"
  moduleTest "paths"
  moduleTest "reversedeps"
  moduleTest "sha1hashes"
  moduleTest "tools"
  moduleTest "topologicalsort"
  moduleTest "vcstools"
  moduleTest "version"
