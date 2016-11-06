# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
import osproc, streams, unittest, strutils, os, sequtils, future

const path = "../src/nimble"

test "can compile nimble":
  check execCmdEx("nim c " & path).exitCode == QuitSuccess

template cd*(dir: string, body: untyped) =
  ## Sets the current dir to ``dir``, executes ``body`` and restores the
  ## previous working dir.
  let lastDir = getCurrentDir()
  setCurrentDir(dir)
  body
  setCurrentDir(lastDir)

proc processOutput(output: string): seq[string] =
  output.strip.splitLines().filter((x: string) => (x.len > 0))

proc inLines(lines: seq[string], line: string): bool =
  for i in lines:
    if line.normalize in i.normalize: return true

test "issue 129 (installing commit hash)":
  check execCmdEx(path & " install -y \"https://github.com/nimble-test/packagea.git@#1f9cb289c89\"").
          exitCode == QuitSuccess

test "issue 113 (uninstallation problems)":
  cd "issue113/c":
    check execCmdEx("../../" & path & " install -y").exitCode == QuitSuccess
  cd "issue113/b":
    check execCmdEx("../../" & path & " install -y").exitCode == QuitSuccess
  cd "issue113/a":
    check execCmdEx("../../" & path & " install -y").exitCode == QuitSuccess

  # Try to remove c.
  let (output, exitCode) = execCmdEx(path & " remove -y c")
  let lines = output.strip.splitLines()
  check exitCode != QuitSuccess
  check inLines(lines, "cannot uninstall c (0.1.0) because b (0.1.0) depends on it")

  check execCmdEx(path & " remove -y a").exitCode == QuitSuccess
  check execCmdEx(path & " remove -y b").exitCode == QuitSuccess

  cd "issue113/buildfail":
    check execCmdEx("../../" & path & " install -y").exitCode != QuitSuccess

  check execCmdEx(path & " remove -y c").exitCode == QuitSuccess

test "can refresh with default urls":
  check execCmdEx(path & " refresh").exitCode == QuitSuccess

proc safeMoveFile(src, dest: string) =
  try:
    moveFile(src, dest)
  except OSError:
    copyFile(src, dest)
    removeFile(src)

test "can refresh with custom urls":
  # Backup current config
  let configFile = getConfigDir() / "nimble" / "nimble.ini"
  let configBakFile = getConfigDir() / "nimble" / "nimble.ini.bak"
  if fileExists(configFile):
    safeMoveFile(configFile, configBakFile)

  # Ensure config dir exists
  createDir(getConfigDir() / "nimble")

  writeFile(configFile, """
    [PackageList]
    name = "official"
    url = "http://google.com"
    url = "http://google.com/404"
    url = "http://irclogs.nim-lang.org/packages.json"
    url = "http://nim-lang.org/nimble/packages.json"
  """.unindent)

  let (output, exitCode) = execCmdEx(path & " refresh")
  let lines = output.strip.splitLines()
  check exitCode == QuitSuccess
  check inLines(lines, "reading from config file")
  check inLines(lines, "downloading \"official\" package list")
  check inLines(lines, "trying http://google.com")
  check inLines(lines, "packages.json file is invalid")
  check inLines(lines, "404 not found")
  check inLines(lines, "done")

  # Restore config
  if fileExists(configBakFile):
    safeMoveFile(configBakFile, configFile)

test "can install nimscript package":
  cd "nimscript":
    check execCmdEx("../" & path & " install -y").exitCode == QuitSuccess

test "can execute nimscript tasks":
  cd "nimscript":
    let (output, exitCode) = execCmdEx("../" & path & " test")
    let lines = output.strip.splitLines()
    check exitCode == QuitSuccess
    check lines[^1] == "10"

test "can use nimscript's setCommand":
  cd "nimscript":
    let (output, exitCode) = execCmdEx("../" & path & " cTest")
    let lines = output.strip.splitLines()
    check exitCode == QuitSuccess
    check "Hint: operation successful".normalize in lines[^1].normalize

test "can use nimscript's setCommand with flags":
  cd "nimscript":
    let (output, exitCode) = execCmdEx("../" & path & " cr")
    let lines = output.strip.splitLines()
    check exitCode == QuitSuccess
    check "Hello World".normalize in lines[^1].normalize

test "can list nimscript tasks":
  cd "nimscript":
    let (output, exitCode) = execCmdEx("../" & path & " tasks")
    check "test                 test description".normalize in output.normalize
    check exitCode == QuitSuccess

test "can use pre/post hooks":
  cd "nimscript":
    let (output, exitCode) = execCmdEx("../" & path & " hooks")
    let lines = output.strip.splitLines()
    check exitCode == QuitSuccess
    check inLines(lines, "First")
    check inLines(lines, "middle")
    check inLines(lines, "last")

test "pre hook can prevent action":
  cd "nimscript":
    let (output, exitCode) = execCmdEx("../" & path & " hooks2")
    let lines = output.strip.splitLines()
    check exitCode == QuitSuccess
    check(not inLines(lines, "Shouldn't happen"))
    check inLines(lines, "Hook prevented further execution")

test "can install packagebin2":
  check execCmdEx(path &
      " install -y https://github.com/nimble-test/packagebin2.git").exitCode ==
      QuitSuccess

test "can reject same version dependencies":
  let (outp, exitCode) = execCmdEx(path &
      " install -y https://github.com/nimble-test/packagebin.git")
  # We look at the error output here to avoid out-of-order problems caused by
  # stderr output being generated and flushed without first flushing stdout
  let ls = outp.strip.splitLines()
  check exitCode != QuitSuccess
  check ls[ls.len-1] == "Error: unhandled exception: Cannot satisfy the " &
      "dependency on PackageA 0.2.0 and PackageA 0.5.0 [NimbleError]"

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

test "issue #126":
  cd "issue126/a":
    let (output, exitCode) = execCmdEx("../../" & path & " install -y")
    let lines = output.strip.splitLines()
    check exitCode != QuitSuccess # TODO
    check inLines(lines, "issue-126 is an invalid package name: cannot contain '-'")

  cd "issue126/b":
    let (output1, exitCode1) = execCmdEx("../../" & path & " install -y")
    let lines1 = output1.strip.splitLines()
    check exitCode1 == QuitSuccess
    check inLines(lines1, "The .nimble file name must match name specified inside")

test "issue #108":
  cd "issue108":
    let (output, exitCode) = execCmdEx("../" & path & " build")
    let lines = output.strip.splitLines()
    check exitCode != QuitSuccess
    check "Nothing to build" in lines[^1]

test "issue #206":
  cd "issue206":
    var (output, exitCode) = execCmdEx("../" & path & " install -y")
    check exitCode == QuitSuccess
    (output, exitCode) = execCmdEx("../" & path & " install -y")
    check exitCode == QuitSuccess

test "can list":
  check execCmdEx(path & " list").exitCode == QuitSuccess

  check execCmdEx(path & " list -i").exitCode == QuitSuccess

test "can uninstall":
  block:
    let (outp, exitCode) = execCmdEx(path & " uninstall -y issue27b")
    # let ls = outp.processOutput()
    let ls = outp.strip.splitLines()
    check exitCode != QuitSuccess
    check ls[ls.len-1] == "  Cannot uninstall issue27b (0.1.0) because " &
                          "issue27a (0.1.0) depends on it [NimbleError]"

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

  check execCmdEx(path & " uninstall -y PackageA@0.2 issue27b").exitCode ==
      QuitSuccess
  check(not dirExists(getHomeDir() / ".nimble" / "pkgs" / "PackageA-0.2.0"))

  check execCmdEx(path & " uninstall -y nimscript").exitCode == QuitSuccess
