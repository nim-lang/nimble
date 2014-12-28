# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
import osproc, unittest, strutils, os, sequtils, future

const path = "../src/nimble"

test "can compile nimble":
  check execCmdEx("nim c " & path).exitCode == QuitSuccess

template cd*(dir: string, body: stmt) =
  ## Sets the current dir to ``dir``, executes ``body`` and restores the
  ## previous working dir.
  let lastDir = getCurrentDir()
  setCurrentDir(dir)
  body
  setCurrentDir(lastDir)

proc processOutput(output: string): seq[string] =
  output.strip.splitLines().filter((x: string) => (x.len > 0))

test "can install packagebin2":
  check execCmdEx(path &
      " install -y https://github.com/nimble-test/packagebin2.git").exitCode ==
      QuitSuccess

test "can reject same version dependencies":
  let (outp, exitCode) = execCmdEx(path &
      " install -y https://github.com/nimble-test/packagebin.git")
  #echo outp
  # TODO: outp is not in the correct order.
  let ls = outp.strip.splitLines()
  check exitCode != QuitSuccess
  check ls[ls.len-1] == "Error: unhandled exception: Cannot satisfy the " &
      "dependency on PackageA 0.2.0 and PackageA 0.5.0 [ENimble]"

test "can update":
  check execCmdEx(path & " update").exitCode == QuitSuccess

test "issue #27":
  # Install b
  cd "issue27/b":
    check execCmdEx("../../" & path & " install -y").exitCode == QuitSuccess

  # Install a
  cd "issue27/a":
    check execCmdEx("../../" & path & " install -y").exitCode == QuitSuccess

  cd "issue27":
    check execCmdEx("../" & path & " install -y").exitCode == QuitSuccess

test "can uninstall":
  block:
    let (outp, exitCode) = execCmdEx(path & " uninstall -y issue27b")
    let ls = outp.processOutput()
    check exitCode != QuitSuccess
    check ls[ls.len-1] == "  Cannot uninstall issue27b (0.1.0) because " &
                          "issue27a (0.1.0) depends on it [Enimble]"

    check execCmdEx(path & " uninstall -y issue27").exitCode == QuitSuccess
    check execCmdEx(path & " uninstall -y issue27a").exitCode == QuitSuccess

  # Remove Package*
  check execCmdEx(path & " uninstall -y PackageA@0.5").exitCode == QuitSuccess

  let (outp, exitCode) = execCmdEx(path & " uninstall -y PackageA")
  check exitCode != QuitSuccess
  let ls = outp.processOutput()
  check ls[ls.len-2].startsWith("  Cannot uninstall PackageA ")
  check ls[ls.len-1].startsWith("  Cannot uninstall PackageA ")
  check execCmdEx(path & " uninstall -y PackageBin2").exitCode == QuitSuccess

  # Case insensitive
  check execCmdEx(path & " uninstall -y packagea").exitCode == QuitSuccess
  check execCmdEx(path & " uninstall -y PackageA").exitCode != QuitSuccess

  # Remove the rest of the installed packages.
  check execCmdEx(path & " uninstall -y PackageB").exitCode == QuitSuccess

  check execCmdEx(path & " uninstall -y PackageA@0.2 issue27b").exitCode == QuitSuccess
  check (not dirExists(getHomeDir() / ".nimble" / "pkgs" / "PackageA-0.2.0"))
