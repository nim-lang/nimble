discard """
  exitcode: 0
"""

import os, strutils
import ../common

# Ensure nimbleDir exists (standalone test doesn't have prior tests creating it)
createDir(installDir)

# Remove all packages from the json file so it needs to be refreshed
writeFile(installDir / "packages_official.json", "[]")
removeDir(installDir / "pkgs2")

let (output, exitCode) = execNimble("install", "-y", "fusion")
let lines = output.strip.processOutput()
# Test that it needed to refresh packages and that it installed
doAssert exitCode == QuitSuccess, output
doAssert inLines(lines, "check internet for updated packages"), output
doAssert inLines(lines, "fusion installed successfully"), output

# Clean up package file
doAssert execNimble(["refresh"]).exitCode == QuitSuccess
