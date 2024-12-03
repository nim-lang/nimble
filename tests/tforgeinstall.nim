{.used.}

import unittest, os
import testscommon

from nimblepkg/common import cd

test "can install packages via a forge alias":
  cd "forgealias001":
    let (_, exitCode) = execNimbleYes(["build"])
    check exitCode == QuitSuccess
    check fileExists("forgealias001")
