# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
import osproc, streams, unittest, strutils, os, sequtils, future

# TODO: Each test should start off with a clean slate. Currently installed
# packages are shared between each test which causes a multitude of issues
# and is really fragile.

var rootDir = getCurrentDir().parentDir()
var nimblePath = rootDir / "src" / addFileExt("nimble", ExeExt)
var installDir = rootDir / "tests" / "nimbleDir"
const path = "../src/nimble"

# Clear nimble dir.
removeDir(installDir)
createDir(installDir)

test "can compile nimble":
  check execCmdEx("nim c " & path).exitCode == QuitSuccess

template cd*(dir: string, body: untyped) =
  ## Sets the current dir to ``dir``, executes ``body`` and restores the
  ## previous working dir.
  let lastDir = getCurrentDir()
  setCurrentDir(dir)
  body
  setCurrentDir(lastDir)

proc execNimble(args: varargs[string]): tuple[output: string, exitCode: int] =
  var quotedArgs = @args
  quotedArgs.insert(nimblePath)
  quotedArgs.add("--nimbleDir:" & installDir)
  quotedArgs = quoted_args.map((x: string) => ("\"" & x & "\""))

  result = execCmdEx(quotedArgs.join(" "))
  #echo(result.output)

proc processOutput(output: string): seq[string] =
  output.strip.splitLines().filter((x: string) => (x.len > 0))

proc inLines(lines: seq[string], line: string): bool =
  for i in lines:
    if line.normalize in i.normalize: return true

test "picks #head when looking for packages":
  cd "versionClashes" / "aporiaScenario":
    check execNimble("install", "-y", "--verbose").exitCode == QuitSuccess
    check execNimble("remove", "aporiascenario", "-y").exitCode == QuitSuccess
    check execNimble("remove", "packagea", "-y").exitCode == QuitSuccess

test "can distinguish package reading in nimbleDir vs. other dirs (#304)":
  cd "issue304" / "package-test":
    check execNimble("tasks").exitCode == QuitSuccess

test "can build with #head and versioned package (#289)":
  cd "issue289":
    check execNimble(["install", "-y"]).exitCode == QuitSuccess

  check execNimble(["uninstall", "issue289", "-y"]).exitCode == QuitSuccess
  check execNimble(["uninstall", "packagea", "-y"]).exitCode == QuitSuccess

test "can validate package structure (#144)":
  # Test that no warnings are produced for correctly structured packages.
  for package in ["a", "b", "c"]:
    cd "packageStructure/" & package:
      let (output, exitCode) = execNimble(["install", "-y"])
      check exitCode == QuitSuccess
      let lines = output.strip.splitLines()
      check(not inLines(lines, "warning"))

  # Test that warnings are produced for the incorrectly structured packages.
  for package in ["x", "y", "z"]:
    cd "packageStructure/" & package:
      let (output, exitCode) = execNimble(["install", "-y"])
      check exitCode == QuitSuccess
      let lines = output.strip.splitLines()
      case package
      of "x":
        check inLines(lines, "File 'foobar.nim' inside package 'x' is outside" &
                             " of the permitted namespace, should be inside a" &
                             " directory named 'x' but is in a directory named" &
                             " 'incorrect' instead.")
      of "y":
        check inLines(lines, "File 'foobar.nim' inside package 'y' is outside" &
                             " of the permitted namespace, should be inside a" &
                             " directory named 'ypkg' but is in a directory" &
                             " named 'yWrong' instead.")
      of "z":
        check inLines(lines, "File inside package 'z' is outside of permitted" &
                             " namespace, should be named 'z.nim' but was" &
                             " named 'incorrect.nim' instead.")
      else:
        assert false

test "issue 129 (installing commit hash)":
  let arguments = @["install", "-y",
                   "https://github.com/nimble-test/packagea.git@#1f9cb289c89"]
  check execNimble(arguments).exitCode == QuitSuccess
  # Verify that it was installed correctly.
  check dirExists(installDir / "pkgs" / "PackageA-#1f9cb289c89")
  # Remove it so that it doesn't interfere with the uninstall tests.
  check execNimble("uninstall", "-y", "packagea@#1f9cb289c89").exitCode ==
        QuitSuccess

test "issue 113 (uninstallation problems)":
  cd "issue113/c":
    check execNimble(["install", "-y"]).exitCode == QuitSuccess
  cd "issue113/b":
    check execNimble(["install", "-y"]).exitCode == QuitSuccess
  cd "issue113/a":
    check execNimble(["install", "-y"]).exitCode == QuitSuccess

  # Try to remove c.
  let (output, exitCode) = execNimble(["remove", "-y", "c"])
  let lines = output.strip.splitLines()
  check exitCode != QuitSuccess
  check inLines(lines, "cannot uninstall c (0.1.0) because b (0.1.0) depends on it")

  check execNimble(["remove", "-y", "a"]).exitCode == QuitSuccess
  check execNimble(["remove", "-y", "b"]).exitCode == QuitSuccess

  cd "issue113/buildfail":
    check execNimble(["install", "-y"]).exitCode != QuitSuccess

  check execNimble(["remove", "-y", "c"]).exitCode == QuitSuccess

test "can refresh with default urls":
  check execNimble(["refresh"]).exitCode == QuitSuccess

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

  let (output, exitCode) = execNimble(["refresh", "--verbose"])
  let lines = output.strip.splitLines()
  check exitCode == QuitSuccess
  check inLines(lines, "config file at")
  check inLines(lines, "official package list")
  check inLines(lines, "http://google.com")
  check inLines(lines, "packages.json file is invalid")
  check inLines(lines, "404 not found")
  check inLines(lines, "Package list downloaded.")

  # Restore config
  if fileExists(configBakFile):
    safeMoveFile(configBakFile, configFile)

test "can install nimscript package":
  cd "nimscript":
    check execNimble(["install", "-y"]).exitCode == QuitSuccess

test "can execute nimscript tasks":
  cd "nimscript":
    let (output, exitCode) = execNimble("--verbose", "test")
    let lines = output.strip.splitLines()
    check exitCode == QuitSuccess
    check lines[^1] == "10"

test "can use nimscript's setCommand":
  cd "nimscript":
    let (output, exitCode) = execNimble("--verbose", "cTest")
    let lines = output.strip.splitLines()
    check exitCode == QuitSuccess
    check "Execution finished".normalize in lines[^1].normalize

test "can use nimscript's setCommand with flags":
  cd "nimscript":
    let (output, exitCode) = execNimble("--debug", "cr")
    # let lines = output.strip.splitLines()
    check exitCode == QuitSuccess
    # check "Hello World".normalize in lines[^2].normalize

test "can use nimscript with repeated flags (issue #329)":
  cd "nimscript":
    let (output, exitCode) = execNimble("--debug", "repeated")
    let lines = output.strip.splitLines()
    check exitCode == QuitSuccess
    var found = false
    for line in lines:
      if line.contains("--define:foo"):
        found = true
    check found == true

test "can list nimscript tasks":
  cd "nimscript":
    let (output, exitCode) = execNimble("tasks")
    check "test                 test description".normalize in output.normalize
    check exitCode == QuitSuccess

test "can use pre/post hooks":
  cd "nimscript":
    let (output, exitCode) = execNimble("hooks")
    let lines = output.strip.splitLines()
    check exitCode == QuitSuccess
    check inLines(lines, "First")
    check inLines(lines, "middle")
    check inLines(lines, "last")

test "pre hook can prevent action":
  cd "nimscript":
    let (output, exitCode) = execNimble("hooks2")
    let lines = output.strip.splitLines()
    check exitCode == QuitSuccess
    check(not inLines(lines, "Shouldn't happen"))
    check inLines(lines, "Hook prevented further execution")

test "can install packagebin2":
  let args = ["install", "-y", "https://github.com/nimble-test/packagebin2.git"]
  check execNimble(args).exitCode == QuitSuccess

test "can reject same version dependencies":
  let (outp, exitCode) = execNimble(
      "install", "-y", "https://github.com/nimble-test/packagebin.git")
  # We look at the error output here to avoid out-of-order problems caused by
  # stderr output being generated and flushed without first flushing stdout
  let ls = outp.strip.splitLines()
  check exitCode != QuitSuccess
  check "Cannot satisfy the dependency on PackageA 0.2.0 and PackageA 0.5.0" in
        ls[ls.len-1]

test "can update":
  check execNimble("update").exitCode == QuitSuccess

test "issue #27":
  # Install b
  cd "issue27/b":
    check execNimble("install", "-y").exitCode == QuitSuccess

  # Install a
  cd "issue27/a":
    check execNimble("install", "-y").exitCode == QuitSuccess

  cd "issue27":
    check execNimble("install", "-y").exitCode == QuitSuccess

test "issue #126":
  cd "issue126/a":
    let (output, exitCode) = execNimble("install", "-y")
    let lines = output.strip.splitLines()
    check exitCode != QuitSuccess # TODO
    check inLines(lines, "issue-126 is an invalid package name: cannot contain '-'")

  cd "issue126/b":
    let (output1, exitCode1) = execNimble("install", "-y")
    let lines1 = output1.strip.splitLines()
    check exitCode1 != QuitSuccess
    check inLines(lines1, "The .nimble file name must match name specified inside")

test "issue #108":
  cd "issue108":
    let (output, exitCode) = execNimble("build")
    let lines = output.strip.splitLines()
    check exitCode != QuitSuccess
    check inLines(lines, "Nothing to build")

test "issue #206":
  cd "issue206":
    var (output, exitCode) = execNimble("install", "-y")
    check exitCode == QuitSuccess
    (output, exitCode) = execNimble("install", "-y")
    check exitCode == QuitSuccess

test "can list":
  check execNimble("list").exitCode == QuitSuccess

  check execNimble("list", "-i").exitCode == QuitSuccess

test "can uninstall":
  block:
    let (outp, exitCode) = execNimble("uninstall", "-y", "issue27b")

    let ls = outp.strip.splitLines()
    check exitCode != QuitSuccess
    check "Cannot uninstall issue27b (0.1.0) because issue27a (0.1.0) depends" &
          " on it" in ls[ls.len-1]

    check execNimble("uninstall", "-y", "issue27").exitCode == QuitSuccess
    check execNimble("uninstall", "-y", "issue27a").exitCode == QuitSuccess

  # Remove Package*
  check execNimble("uninstall", "-y", "PackageA@0.5").exitCode == QuitSuccess

  let (outp, exitCode) = execNimble("uninstall", "-y", "PackageA")
  check exitCode != QuitSuccess
  let ls = outp.processOutput()
  check inLines(ls, "Cannot uninstall PackageA (0.2.0)")
  check inLines(ls, "Cannot uninstall PackageA (0.6.0)")
  check execNimble("uninstall", "-y", "PackageBin2").exitCode == QuitSuccess

  # Case insensitive
  check execNimble("uninstall", "-y", "packagea").exitCode == QuitSuccess
  check execNimble("uninstall", "-y", "PackageA").exitCode != QuitSuccess

  # Remove the rest of the installed packages.
  check execNimble("uninstall", "-y", "PackageB").exitCode == QuitSuccess

  check execNimble("uninstall", "-y", "PackageA@0.2", "issue27b").exitCode ==
      QuitSuccess
  check(not dirExists(installDir / "pkgs" / "PackageA-0.2.0"))

  check execNimble("uninstall", "-y", "nimscript").exitCode == QuitSuccess

test "can dump for current project":
  cd "testdump":
    let (outp, exitCode) = execNimble("dump")
    check: exitCode == 0
    check: outp.processOutput.inLines("desc: \"Test package for dump command\"")

test "can dump for project directory":
  let (outp, exitCode) = execNimble("dump", "testdump")
  check: exitCode == 0
  check: outp.processOutput.inLines("desc: \"Test package for dump command\"")

test "can dump for project file":
  let (outp, exitCode) = execNimble("dump", "testdump" / "testdump.nimble")
  check: exitCode == 0
  check: outp.processOutput.inLines("desc: \"Test package for dump command\"")

test "can dump for installed package":
  cd "testdump":
    check: execNimble("install", "-y").exitCode == 0
  defer:
    discard execNimble("remove", "-y", "testdump")

  # Otherwise we might find subdirectory instead
  cd "..":
    let (outp, exitCode) = execNimble("dump", "testdump")
    check: exitCode == 0
    check: outp.processOutput.inLines("desc: \"Test package for dump command\"")
