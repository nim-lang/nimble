# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

discard """
  exitcode: 0
"""

import os, osproc, strutils, common
from nimblepkg/common import cd

cd "issue727":
  let (output, exitCode) = execCmdEx(nimblePath & " --format:json deps -y")
  doAssert exitCode == QuitSuccess, output
  doAssert output.contains("\"name\": \"timezones\""), output
  doAssert output.contains("\"resolvedTo\": \"0.5.4\""), output
