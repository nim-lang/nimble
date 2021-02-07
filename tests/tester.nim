# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
import osproc, unittest, strutils, os, sequtils, sugar, strformat

# TODO: Each test should start off with a clean slate. Currently installed
# packages are shared between each test which causes a multitude of issues
# and is really fragile.

let rootDir = getCurrentDir().parentDir()
let nimblePath = rootDir / "src" / addFileExt("nimble", ExeExt)
let installDir = rootDir / "tests" / "nimbleDir"
const path = "../src/nimble"
const stringNotFound = -1

# Set env var to propagate nimble binary path
putEnv("NIMBLE_TEST_BINARY_PATH", nimblePath)

# Clear nimble dir.
removeDir(installDir)
createDir(installDir)

# Always recompile.
doAssert execCmdEx("nim c -d:danger " & path).exitCode == QuitSuccess

template cd*(dir: string, body: untyped) =
  ## Sets the current dir to ``dir``, executes ``body`` and restores the
  ## previous working dir.
  block:
    let lastDir = getCurrentDir()
    setCurrentDir(dir)
    body
    setCurrentDir(lastDir)

proc execNimble(args: varargs[string]): tuple[output: string, exitCode: int] =
  var quotedArgs = @args
  quotedArgs.insert("--nimbleDir:" & installDir)
  quotedArgs.insert(nimblePath)
  quotedArgs = quotedArgs.map((x: string) => x.quoteShell)

  let path {.used.} = getCurrentDir().parentDir() / "src"

  var cmd =
    when not defined(windows):
      "PATH=" & path & ":$PATH " & quotedArgs.join(" ")
    else:
      quotedArgs.join(" ")
  when defined(macosx):
    # TODO: Yeah, this is really specific to my machine but for my own sanity...
    cmd = "DYLD_LIBRARY_PATH=/usr/local/opt/openssl@1.1/lib " & cmd

  result = execCmdEx(cmd)
  checkpoint(cmd)
  checkpoint(result.output)

proc execNimbleYes(args: varargs[string]): tuple[output: string, exitCode: int]=
  # issue #6314
  execNimble(@args & "-y")

proc execBin(name: string): tuple[output: string, exitCode: int] =
  var
    cmd = installDir / "bin" / name

  when defined(windows):
    cmd = "cmd /c " & cmd & ".cmd"

  result = execCmdEx(cmd)

template verify(res: (string, int)) =
  let r = res
  checkpoint r[0]
  check r[1] == QuitSuccess

proc processOutput(output: string): seq[string] =
  output.strip.splitLines().filter(
    (x: string) => (
      x.len > 0 and
      "Using env var NIM_LIB_PREFIX" notin x
    )
  )

proc inLines(lines: seq[string], line: string): bool =
  for i in lines:
    if line.normalize in i.normalize: return true

proc hasLineStartingWith(lines: seq[string], prefix: string): bool =
  for line in lines:
    if line.strip(trailing = false).startsWith(prefix):
      return true
  return false

proc safeMoveFile(src, dest: string) =
  try:
    moveFile(src, dest)
  except OSError:
    copyFile(src, dest)
    removeFile(src)

template testRefresh(body: untyped) =
  # Backup current config
  let configFile {.inject.} = getConfigDir() / "nimble" / "nimble.ini"
  let configBakFile = getConfigDir() / "nimble" / "nimble.ini.bak"
  if fileExists(configFile):
    safeMoveFile(configFile, configBakFile)

  # Ensure config dir exists
  createDir(getConfigDir() / "nimble")

  body

  # Restore config
  if fileExists(configBakFile):
    safeMoveFile(configBakFile, configFile)

suite "nimble refresh":
  test "can refresh with default urls":
    let (output, exitCode) = execNimble(["refresh"])
    checkpoint(output)
    check exitCode == QuitSuccess

  test "can refresh with custom urls":
    testRefresh():
      writeFile(configFile, """
        [PackageList]
        name = "official"
        url = "https://google.com"
        url = "https://google.com/404"
        url = "https://irclogs.nim-lang.org/packages.json"
        url = "https://nim-lang.org/nimble/packages.json"
        url = "https://github.com/nim-lang/packages/raw/master/packages.json"
      """.unindent)

      let (output, exitCode) = execNimble(["refresh", "--verbose"])
      checkpoint(output)
      let lines = output.strip.processOutput()
      check exitCode == QuitSuccess
      check inLines(lines, "config file at")
      check inLines(lines, "official package list")
      check inLines(lines, "https://google.com")
      check inLines(lines, "packages.json file is invalid")
      check inLines(lines, "404 not found")
      check inLines(lines, "Package list downloaded.")

  test "can refresh with local package list":
    testRefresh():
      writeFile(configFile, """
        [PackageList]
        name = "local"
        path = "$1"
      """.unindent % (getCurrentDir() / "issue368" / "packages.json").replace("\\", "\\\\"))
      let (output, exitCode) = execNimble(["refresh", "--verbose"])
      let lines = output.strip.processOutput()
      check inLines(lines, "config file at")
      check inLines(lines, "Copying")
      check inLines(lines, "Package list copied.")
      check exitCode == QuitSuccess

  test "package list source required":
    testRefresh():
      writeFile(configFile, """
        [PackageList]
        name = "local"
      """)
      let (output, exitCode) = execNimble(["refresh", "--verbose"])
      let lines = output.strip.processOutput()
      check inLines(lines, "config file at")
      check inLines(lines, "Package list 'local' requires either url or path")
      check exitCode == QuitFailure

  test "package list can only have one source":
    testRefresh():
      writeFile(configFile, """
        [PackageList]
        name = "local"
        path = "$1"
        url = "http://nim-lang.org/nimble/packages.json"
      """)
      let (output, exitCode) = execNimble(["refresh", "--verbose"])
      let lines = output.strip.processOutput()
      check inLines(lines, "config file at")
      check inLines(lines, "Attempted to specify `url` and `path` for the same package list 'local'")
      check exitCode == QuitFailure

suite "nimscript":
  test "can install nimscript package":
    cd "nimscript":
      let
        nim = findExe("nim").relativePath(base = getCurrentDir())
      check execNimbleYes(["install", "--nim:" & nim]).exitCode == QuitSuccess

  test "before/after install pkg dirs are correct":
    cd "nimscript":
      let (output, exitCode) = execNimbleYes(["install", "--nim:nim"])
      check exitCode == QuitSuccess
      check output.contains("Before build")
      check output.contains("After build")
      let lines = output.strip.processOutput()
      for line in lines:
        if lines[3].startsWith("Before PkgDir:"):
          check line.endsWith("tests" / "nimscript")
      check lines[^1].startsWith("After PkgDir:")
      check lines[^1].endsWith("tests" / "nimbleDir" / "pkgs" / "nimscript-0.1.0")

  test "before/after on build":
    cd "nimscript":
      let (output, exitCode) = execNimble([
        "build", "--nim:" & findExe("nim"), "--silent"])
      check exitCode == QuitSuccess
      check output.contains("Before build")
      check output.contains("After build")
      check not output.contains("Verifying")

  test "can execute nimscript tasks":
    cd "nimscript":
      let (output, exitCode) = execNimble("--verbose", "work")
      let lines = output.strip.processOutput()
      check exitCode == QuitSuccess
      check lines[^1] == "10"

  test "can use nimscript's setCommand":
    cd "nimscript":
      let (output, exitCode) = execNimble("--verbose", "cTest")
      let lines = output.strip.processOutput()
      check exitCode == QuitSuccess
      check "Execution finished".normalize in lines[^1].normalize

  test "can use nimscript's setCommand with flags":
    cd "nimscript":
      let (output, exitCode) = execNimble("--debug", "cr")
      let lines = output.strip.processOutput()
      check exitCode == QuitSuccess
      check inLines(lines, "Hello World")

  test "can use nimscript with repeated flags (issue #329)":
    cd "nimscript":
      let (output, exitCode) = execNimble("--debug", "repeated")
      let lines = output.strip.processOutput()
      check exitCode == QuitSuccess
      var found = false
      for line in lines:
        if line.contains("--define:foo"):
          found = true
      check found == true

  test "can list nimscript tasks":
    cd "nimscript":
      let (output, exitCode) = execNimble("tasks")
      check "work".normalize in output.normalize
      check "test description".normalize in output.normalize
      check exitCode == QuitSuccess

  test "can use pre/post hooks":
    cd "nimscript":
      let (output, exitCode) = execNimble("hooks")
      let lines = output.strip.processOutput()
      check exitCode == QuitSuccess
      check inLines(lines, "First")
      check inLines(lines, "middle")
      check inLines(lines, "last")

  test "pre hook can prevent action":
    cd "nimscript":
      let (output, exitCode) = execNimble("hooks2")
      let lines = output.strip.processOutput()
      check exitCode == QuitFailure
      check(not inLines(lines, "Shouldn't happen"))
      check inLines(lines, "Hook prevented further execution")

  test "nimble script api":
    cd "nimscript":
      let (output, exitCode) = execNimble("api")
      let lines = output.strip.processOutput()
      check exitCode == QuitSuccess
      check inLines(lines, "thisDirCT: " & getCurrentDir())
      check inLines(lines, "PKG_DIR: " & getCurrentDir())
      check inLines(lines, "thisDir: " & getCurrentDir())

  test "nimscript evaluation error message":
    cd "invalidPackage":
      let (output, exitCode) = execNimble("check")
      let lines = output.strip.processOutput()
      check(lines[^2].contains("undeclared identifier: 'thisFieldDoesNotExist'"))
      check exitCode == QuitFailure

  test "can accept short flags (#329)":
    cd "nimscript":
      check execNimble("c", "-d:release", "nimscript.nim").exitCode == QuitSuccess

suite "uninstall":
  test "can install packagebin2":
    let args = ["install", "https://github.com/nimble-test/packagebin2.git"]
    check execNimbleYes(args).exitCode == QuitSuccess

  test "can reject same version dependencies":
    let (outp, exitCode) = execNimbleYes(
        "install", "https://github.com/nimble-test/packagebin.git")
    # We look at the error output here to avoid out-of-order problems caused by
    # stderr output being generated and flushed without first flushing stdout
    let ls = outp.strip.processOutput()
    check exitCode != QuitSuccess
    check "Cannot satisfy the dependency on PackageA 0.2.0 and PackageA 0.5.0" in
          ls[ls.len-1]

  test "issue #27":
    # Install b
    cd "issue27/b":
      check execNimbleYes("install").exitCode == QuitSuccess

    # Install a
    cd "issue27/a":
      check execNimbleYes("install").exitCode == QuitSuccess

    cd "issue27":
      check execNimbleYes("install").exitCode == QuitSuccess

  test "can uninstall":
    block:
      let (outp, exitCode) = execNimbleYes("uninstall", "issue27b")

      let ls = outp.strip.processOutput()
      check exitCode != QuitSuccess
      check inLines(ls, "Cannot uninstall issue27b (0.1.0) because issue27a (0.1.0) depends")

      check execNimbleYes("uninstall", "issue27").exitCode == QuitSuccess
      check execNimbleYes("uninstall", "issue27a").exitCode == QuitSuccess

    # Remove Package*
    check execNimbleYes("uninstall", "PackageA@0.5").exitCode == QuitSuccess

    let (outp, exitCode) = execNimbleYes("uninstall", "PackageA")
    check exitCode != QuitSuccess
    let ls = outp.processOutput()
    check inLines(ls, "Cannot uninstall PackageA (0.2.0)")
    check inLines(ls, "Cannot uninstall PackageA (0.6.0)")
    check execNimbleYes("uninstall", "PackageBin2").exitCode == QuitSuccess

    # Case insensitive
    check execNimbleYes("uninstall", "packagea").exitCode == QuitSuccess
    check execNimbleYes("uninstall", "PackageA").exitCode != QuitSuccess

    # Remove the rest of the installed packages.
    check execNimbleYes("uninstall", "PackageB").exitCode == QuitSuccess

    check execNimbleYes("uninstall", "PackageA@0.2", "issue27b").exitCode ==
        QuitSuccess
    check(not dirExists(installDir / "pkgs" / "PackageA-0.2.0"))

    check execNimbleYes("uninstall", "nimscript").exitCode == QuitSuccess

suite "nimble dump":
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
      check: execNimbleYes("install").exitCode == 0
    defer:
      discard execNimbleYes("remove", "testdump")

    # Otherwise we might find subdirectory instead
    cd "..":
      let (outp, exitCode) = execNimble("dump", "testdump")
      check: exitCode == 0
      check: outp.processOutput.inLines("desc: \"Test package for dump command\"")

  test "can dump when explicitly asking for INI format":
    const outpExpected = """
name: "testdump"
version: "0.1.0"
author: "nigredo-tori"
desc: "Test package for dump command"
license: "BSD"
skipDirs: ""
skipFiles: ""
skipExt: ""
installDirs: ""
installFiles: ""
installExt: ""
requires: ""
bin: ""
binDir: ""
srcDir: ""
backend: "c"
"""
    let (outp, exitCode) = execNimble("dump", "--ini", "testdump")
    check: exitCode == 0
    check: outp == outpExpected

  test "can dump in JSON format":
    const outpExpected = """
{
  "name": "testdump",
  "version": "0.1.0",
  "author": "nigredo-tori",
  "desc": "Test package for dump command",
  "license": "BSD",
  "skipDirs": [],
  "skipFiles": [],
  "skipExt": [],
  "installDirs": [],
  "installFiles": [],
  "installExt": [],
  "requires": [],
  "bin": [],
  "binDir": "",
  "srcDir": "",
  "backend": "c"
}
"""
    let (outp, exitCode) = execNimble("dump", "--json", "testdump")
    check: exitCode == 0
    check: outp == outpExpected

suite "can handle two binary versions":
  setup:
    cd "binaryPackage/v1":
      check execNimbleYes("install").exitCode == QuitSuccess

    cd "binaryPackage/v2":
      check execNimbleYes("install").exitCode == QuitSuccess

  test "can execute v2":
    let (output, exitCode) = execBin("binaryPackage")
    check exitCode == QuitSuccess
    check output.strip() == "v2"

  test "can update symlink to earlier version after removal":
    check execNimbleYes("remove", "binaryPackage@2.0").exitCode==QuitSuccess

    let (output, exitCode) = execBin("binaryPackage")
    check exitCode == QuitSuccess
    check output.strip() == "v1"

  test "can keep symlink version after earlier version removal":
    check execNimbleYes("remove", "binaryPackage@1.0").exitCode==QuitSuccess

    let (output, exitCode) = execBin("binaryPackage")
    check exitCode == QuitSuccess
    check output.strip() == "v2"

suite "reverse dependencies":
  test "basic test":
    cd "revdep/mydep":
      verify execNimbleYes("install")

    cd "revdep/pkgWithDep":
      verify execNimbleYes("install")

    verify execNimbleYes("remove", "pkgA")
    verify execNimbleYes("remove", "mydep")

  test "revdep fail test":
    cd "revdep/mydep":
      verify execNimbleYes("install")

    cd "revdep/pkgWithDep":
      verify execNimbleYes("install")

    let (output, exitCode) = execNimble("uninstall", "mydep")
    checkpoint output
    check output.processOutput.inLines("cannot uninstall mydep")
    check exitCode == QuitFailure

  test "revdep -i test":
    cd "revdep/mydep":
      verify execNimbleYes("install")

    cd "revdep/pkgWithDep":
      verify execNimbleYes("install")

    verify execNimbleYes("remove", "mydep", "-i")

  test "issue #373":
    cd "revdep/mydep":
      verify execNimbleYes("install")

    cd "revdep/pkgWithDep":
      verify execNimbleYes("install")

    cd "revdep/pkgNoDep":
      verify execNimbleYes("install")

    verify execNimbleYes("remove", "mydep")

  test "remove skips packages with revDeps (#504)":
    check execNimbleYes("install", "nimboost@0.5.5", "nimfp@0.4.4").exitCode == QuitSuccess

    var (output, exitCode) = execNimble("uninstall", "nimboost", "nimfp", "-n")
    var lines = output.strip.processOutput()
    check inLines(lines, "Cannot uninstall nimboost")

    (output, exitCode) = execNimbleYes("uninstall", "nimfp", "nimboost")
    lines = output.strip.processOutput()
    check (not inLines(lines, "Cannot uninstall nimboost"))

    check execNimble("path", "nimboost").exitCode != QuitSuccess
    check execNimble("path", "nimfp").exitCode != QuitSuccess

suite "develop feature":
  test "can reject binary packages":
    cd "develop/binary":
      let (output, exitCode) = execNimble("develop")
      checkpoint output
      check output.processOutput.inLines("cannot develop packages")
      check exitCode == QuitFailure

  test "can develop hybrid":
    cd "develop/hybrid":
      let (output, exitCode) = execNimble("develop")
      checkpoint output
      check output.processOutput.inLines("will not be compiled")
      check exitCode == QuitSuccess

      let path = installDir / "pkgs" / "hybrid-#head" / "hybrid.nimble-link"
      check fileExists(path)
      let split = readFile(path).processOutput()
      check split.len == 2
      check split[0].endsWith("develop" / "hybrid" / "hybrid.nimble")
      check split[1].endsWith("develop" / "hybrid")

  test "can develop with srcDir":
    cd "develop/srcdirtest":
      let (output, exitCode) = execNimble("develop")
      checkpoint output
      check(not output.processOutput.inLines("will not be compiled"))
      check exitCode == QuitSuccess

      let path = installDir / "pkgs" / "srcdirtest-#head" /
                 "srcdirtest.nimble-link"
      check fileExists(path)
      let split = readFile(path).processOutput()
      check split.len == 2
      check split[0].endsWith("develop" / "srcdirtest" / "srcdirtest.nimble")
      check split[1].endsWith("develop" / "srcdirtest" / "src")

    cd "develop/dependent":
      let (output, exitCode) = execNimble("c", "-r", "src" / "dependent.nim")
      checkpoint output
      check(output.processOutput.inLines("hello"))
      check exitCode == QuitSuccess

  test "can uninstall linked package":
    cd "develop/srcdirtest":
      let (_, exitCode) = execNimbleYes("develop")
      check exitCode == QuitSuccess

    let (output, exitCode) = execNimbleYes("uninstall", "srcdirtest")
    checkpoint(output)
    check exitCode == QuitSuccess
    check(not output.processOutput.inLines("warning"))

  test "can git clone for develop":
    let cloneDir = installDir / "developTmp"
    createDir(cloneDir)
    cd cloneDir:
      let url = "https://github.com/nimble-test/packagea.git"
      let (_, exitCode) = execNimbleYes("develop", url)
      check exitCode == QuitSuccess

  test "nimble path points to develop":
    cd "develop/srcdirtest":
      var (output, exitCode) = execNimble("develop")
      checkpoint output
      check exitCode == QuitSuccess

      (output, exitCode) = execNimble("path", "srcdirtest")

      checkpoint output
      check exitCode == QuitSuccess
      check output.strip() == getCurrentDir() / "src"

  test "can get correct path for srcDir (#531)":
    check execNimbleYes("uninstall", "srcdirtest").exitCode == QuitSuccess
    cd "develop/srcdirtest":
      let (_, exitCode) = execNimbleYes("install")
      check exitCode == QuitSuccess
    let (output, _) = execNimble("path", "srcdirtest")
    check output.strip() == installDir / "pkgs" / "srcdirtest-1.0"

suite "test command":
  test "Runs passing unit tests":
    cd "testCommand/testsPass":
      # Pass flags to test #726, #757
      let (outp, exitCode) = execNimble("test", "-d:CUSTOM")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("First test")
      check outp.processOutput.inLines("Second test")
      check outp.processOutput.inLines("Third test")
      check outp.processOutput.inLines("Executing my func")

  test "Runs failing unit tests":
    cd "testCommand/testsFail":
      let (outp, exitCode) = execNimble("test")
      check exitCode == QuitFailure
      check outp.processOutput.inLines("First test")
      check outp.processOutput.inLines("Failing Second test")
      check(not outp.processOutput.inLines("Third test"))

  test "test command can be overriden":
    cd "testCommand/testOverride":
      let (outp, exitCode) = execNimble("-d:CUSTOM", "test", "--runflag")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("overriden")
      check outp.processOutput.inLines("true")

  test "certain files are ignored":
    cd "testCommand/testsIgnore":
      let (outp, exitCode) = execNimble("test")
      check exitCode == QuitSuccess
      check(not outp.processOutput.inLines("Should be ignored"))
      check outp.processOutput.inLines("First test")

  test "CWD is root of package":
    cd "testCommand/testsCWD":
      let (outp, exitCode) = execNimble("test")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines(getCurrentDir())

suite "check command":
  test "can succeed package":
    cd "binaryPackage/v1":
      let (outp, exitCode) = execNimble("check")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("success")
      check outp.processOutput.inLines("binaryPackage is valid")

    cd "packageStructure/a":
      let (outp, exitCode) = execNimble("check")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("success")
      check outp.processOutput.inLines("a is valid")

    cd "packageStructure/b":
      let (outp, exitCode) = execNimble("check")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("success")
      check outp.processOutput.inLines("b is valid")

    cd "packageStructure/c":
      let (outp, exitCode) = execNimble("check")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("success")
      check outp.processOutput.inLines("c is valid")

  test "can fail package":
    cd "packageStructure/x":
      let (outp, exitCode) = execNimble("check")
      check exitCode == QuitFailure
      check outp.processOutput.inLines("failure")
      check outp.processOutput.inLines("validation failed")
      check outp.processOutput.inLines("package 'x' has an incorrect structure")

suite "multi":
  test "can install package from git subdir":
    var
      args = @["install", "https://github.com/nimble-test/multi?subdir=alpha"]
      (output, exitCode) = execNimbleYes(args)
    check exitCode == QuitSuccess

    # Issue 785
    args.add @["https://github.com/nimble-test/multi?subdir=beta", "-n"]
    (output, exitCode) = execNimble(args)
    check exitCode == QuitSuccess
    check output.contains("forced no")
    check output.contains("beta installed successfully")

  test "can develop package from git subdir":
    removeDir("multi")
    let args = ["develop", "https://github.com/nimble-test/multi?subdir=beta"]
    check execNimbleYes(args).exitCode == QuitSuccess

suite "Module tests":
  test "version":
    cd "..":
      check execCmdEx("nim c -r src/nimblepkg/version").exitCode == QuitSuccess

  test "reversedeps":
    cd "..":
      check execCmdEx("nim c -r src/nimblepkg/reversedeps").exitCode == QuitSuccess

  test "packageparser":
    cd "..":
      check execCmdEx("nim c -r src/nimblepkg/packageparser").exitCode == QuitSuccess

  test "packageinfo":
    cd "..":
      check execCmdEx("nim c -r src/nimblepkg/packageinfo").exitCode == QuitSuccess

  test "cli":
    cd "..":
      check execCmdEx("nim c -r src/nimblepkg/cli").exitCode == QuitSuccess

  test "download":
    cd "..":
      check execCmdEx("nim c -r src/nimblepkg/download").exitCode == QuitSuccess

suite "nimble run":
  test "Invalid binary":
    cd "run":
      let (output, exitCode) = execNimble(
        "--debug", # Flag to enable debug verbosity in Nimble
        "run", # Run command invokation
        "blahblah", # The command to run
      )
      check exitCode == QuitFailure
      check output.contains("Binary '$1' is not defined in 'run' package." %
                            "blahblah".changeFileExt(ExeExt))

  test "Parameters passed to executable":
    cd "run":
      let (output, exitCode) = execNimble(
        "--debug", # Flag to enable debug verbosity in Nimble
        "run", # Run command invokation
        "run", # The command to run
        "--test", # First argument passed to the executed command
        "check" # Second argument passed to the executed command.
      )
      check exitCode == QuitSuccess
      check output.contains("tests$1run$1$2 --test check" %
                            [$DirSep, "run".changeFileExt(ExeExt)])
      check output.contains("""Testing `nimble run`: @["--test", "check"]""")

  test "Parameters not passed to single executable":
    cd "run":
      let (output, exitCode) = execNimble(
        "--debug", # Flag to enable debug verbosity in Nimble
        "run", # Run command invokation
        "--", # Separator for arguments
        "--test" # First argument passed to the executed command
      )
      check exitCode == QuitSuccess
      check output.contains("tests$1run$1$2 --test" %
                            [$DirSep, "run".changeFileExt(ExeExt)])
      check output.contains("""Testing `nimble run`: @["--test"]""")

  test "Parameters passed to single executable":
    cd "run":
      let (output, exitCode) = execNimble(
        "--debug", # Flag to enable debug verbosity in Nimble
        "run", # Run command invokation
        "--", # Flag to set run file to "" before next argument
        "--test", # First argument passed to the executed command
        "check" # Second argument passed to the executed command.
      )
      check exitCode == QuitSuccess
      check output.contains("tests$1run$1$2 --test check" %
                            [$DirSep, "run".changeFileExt(ExeExt)])
      check output.contains("""Testing `nimble run`: @["--test", "check"]""")

  test "Executable output is shown even when not debugging":
    cd "run":
      let (output, exitCode) =
        execNimble("run", "run", "--option1", "arg1")
      check exitCode == QuitSuccess
      check output.contains("""Testing `nimble run`: @["--option1", "arg1"]""")

  test "Quotes and whitespace are well handled":
    cd "run":
      let (output, exitCode) = execNimble(
        "run", "run", "\"", "\'", "\t", "arg with spaces"
      )
      check exitCode == QuitSuccess
      check output.contains(
        """Testing `nimble run`: @["\"", "\'", "\t", "arg with spaces"]"""
      )

  test "Compile flags before executable name":
    cd "run":
      let (output, exitCode) = execNimble(
        "run", # Run command invokation
        "--debug", # Flag to enable debug verbosity in Nimble
        "run", # The executable to run
        "--test" # First argument passed to the executed command
      )
      check exitCode == QuitSuccess
      check output.contains("tests$1run$1$2 --test" %
                            [$DirSep, "run".changeFileExt(ExeExt)])
      echo output
      check output.contains("""Testing `nimble run`: @["--test"]""")

  test "Compile flags before --":
    cd "run":
      let (output, exitCode) = execNimble(
        "run", # Run command invokation
        "--debug", # Flag to enable debug verbosity in Nimble
        "--", # Separator for arguments
        "--test" # First argument passed to the executed command
      )
      check exitCode == QuitSuccess
      check output.contains("tests$1run$1$2 --test" %
                            [$DirSep, "run".changeFileExt(ExeExt)])
      echo output
      check output.contains("""Testing `nimble run`: @["--test"]""")

suite "project local deps mode":
  test "nimbledeps exists":
    cd "localdeps":
      removeDir("nimbledeps")
      createDir("nimbledeps")
      let (output, exitCode) = execCmdEx(nimblePath & " install -y")
      check exitCode == QuitSuccess
      check output.contains("project local deps mode")
      check output.contains("Succeeded")

  test "--localdeps flag":
    cd "localdeps":
      removeDir("nimbledeps")
      let (output, exitCode) = execCmdEx(nimblePath & " install -y -l")
      check exitCode == QuitSuccess
      check output.contains("project local deps mode")
      check output.contains("Succeeded")

  test "localdeps develop":
    removeDir("packagea")
    let (_, exitCode) = execCmdEx(nimblePath & " develop https://github.com/nimble-test/packagea --localdeps -y")
    check exitCode == QuitSuccess
    check dirExists("packagea" / "nimbledeps")
    check not dirExists("nimbledeps")

suite "misc tests":
  test "depsOnly + flag order test":
    let (output, exitCode) = execNimbleYes(
      "--depsOnly", "install", "https://github.com/nimble-test/packagebin2"
    )
    check(not output.contains("Success: packagebin2 installed successfully."))
    check exitCode == QuitSuccess

  test "caching of nims and ini detects changes":
    cd "caching":
      var (output, exitCode) = execNimble("dump")
      check output.contains("0.1.0")
      let
        nfile = "caching.nimble"
      writeFile(nfile, readFile(nfile).replace("0.1.0", "0.2.0"))
      (output, exitCode) = execNimble("dump")
      check output.contains("0.2.0")
      writeFile(nfile, readFile(nfile).replace("0.2.0", "0.1.0"))

      # Verify cached .nims runs project dir specific commands correctly
      (output, exitCode) = execNimble("testpath")
      check exitCode == QuitSuccess
      check output.contains("imported")
      check output.contains("tests/caching")
      check output.contains("copied")
      check output.contains("removed")

  test "tasks can be called recursively":
    cd "recursive":
      check execNimble("recurse").exitCode == QuitSuccess

  test "picks #head when looking for packages":
    cd "versionClashes" / "aporiaScenario":
      let (output, exitCode) = execNimbleYes("install", "--verbose")
      checkpoint output
      check exitCode == QuitSuccess
      check execNimbleYes("remove", "aporiascenario").exitCode == QuitSuccess
      check execNimbleYes("remove", "packagea").exitCode == QuitSuccess

  test "pass options to the compiler with `nimble install`":
    cd "passNimFlags":
      check execNimble("install", "--passNim:-d:passNimIsWorking").exitCode == QuitSuccess

  test "NimbleVersion is defined":
    cd "nimbleVersionDefine":
      let (output, exitCode) = execNimble("c", "-r", "src/nimbleVersionDefine.nim")
      check output.contains("0.1.0")
      check exitCode == QuitSuccess

      let (output2, exitCode2) = execNimble("run", "nimbleVersionDefine")
      check output2.contains("0.1.0")
      check exitCode2 == QuitSuccess

  test "compilation without warnings":
    const buildDir = "./buildDir/"
    const filesToBuild = [
      "../src/nimble.nim",
      "./tester.nim",
      ]

    proc execBuild(fileName: string): tuple[output: string, exitCode: int] =
      result = execCmdEx(
        fmt"nim c -o:{buildDir/fileName.splitFile.name} {fileName}")

    proc checkOutput(output: string): uint =
      const warningsToCheck = [
        "[UnusedImport]",
        "[Deprecated]",
        "[XDeclaredButNotUsed]",
        ]

      for line in output.splitLines():
        for warning in warningsToCheck:
          if line.find(warning) != stringNotFound:
            once: checkpoint("Detected warnings:")
            checkpoint(line)
            inc(result)

    removeDir(buildDir)

    var linesWithWarningsCount: uint = 0
    for file in filesToBuild:
      let (output, exitCode) = execBuild(file)
      check exitCode == QuitSuccess
      linesWithWarningsCount += checkOutput(output)
    check linesWithWarningsCount == 0

  test "can update":
    check execNimble("update").exitCode == QuitSuccess

  test "can list":
    check execNimble("list").exitCode == QuitSuccess

    check execNimble("list", "-i").exitCode == QuitSuccess

suite "issues":
  test "issue 801":
    cd "issue801":
      let (output, exitCode) = execNimbleYes("test")
      check exitCode == QuitSuccess

      # Verify hooks work
      check output.contains("before test")
      check output.contains("after test")

  # When building, any newly installed packages should be referenced via the path that they get permanently installed at.
  test "issue 799":
    cd "issue799":
      let (build_output, build_code) = execNimbleYes("--verbose", "build")
      check build_code == 0
      var build_results = processOutput(build_output)
      build_results.keepItIf(unindent(it).startsWith("Executing"))
      for build_line in build_results:
        if build_line.contains("issue799"):
          let pkg_installed_path = "--path:" & (installDir / "pkgs" / "nimble-#head").quoteShell
          check build_line.contains(pkg_installed_path)

  test "issue 793":
    cd "issue793":
      var (output, exitCode) = execNimble("build")
      check exitCode == QuitSuccess
      check output.contains("before build")
      check output.contains("after build")

      # Issue 776
      (output, exitCode) = execNimble("doc", "src/issue793")
      check output.contains("before doc")
      check output.contains("after doc")

  test "issue 727":
    cd "issue727":
      var (output, exitCode) = execNimbleYes("c", "src/abc")
      check exitCode == QuitSuccess
      check fileExists("src/abc".addFileExt(ExeExt))
      check not fileExists("src/def".addFileExt(ExeExt))

      (output, exitCode) = execNimbleYes("uninstall", "-i", "timezones")
      check exitCode == QuitSuccess

      (output, exitCode) = execNimbleYes("run", "def")
      check exitCode == QuitSuccess
      check output.contains("def727")
      check not fileExists("abc".addFileExt(ExeExt))
      check fileExists("def".addFileExt(ExeExt))

      (output, exitCode) = execNimbleYes("uninstall", "-i", "timezones")
      check exitCode == QuitSuccess

  test "issue 708":
    cd "issue708":
      # TODO: We need a way to filter out compiler messages from the messages
      # written by our nimble scripts.
      let (output, exitCode) = execNimbleYes("install", "--verbose")
      check exitCode == QuitSuccess
      let lines = output.strip.processOutput()
      check(inLines(lines, "hello"))
      check(inLines(lines, "hello2"))

  test "do not install single dependency multiple times (#678)":
    # for the test to be correct, the tested package and its dependencies must not
    # exist in the local cache
    removeDir("nimbleDir")
    cd "issue678":
      testRefresh():
        writeFile(configFile, """
          [PackageList]
          name = "local"
          path = "$1"
        """.unindent % (getCurrentDir() / "packages.json").replace("\\", "\\\\"))
        check execNimble(["refresh"]).exitCode == QuitSuccess
        let (output, exitCode) = execNimbleYes("install")
        check exitCode == QuitSuccess
        let index = output.find("issue678_dependency_1@0.1.0 already exists")
        check index == stringNotFound

  test "Passing command line arguments to a task (#633)":
    cd "issue633":
      let (output, exitCode) = execNimble("testTask", "--testTask")
      check exitCode == QuitSuccess
      check output.contains("Got it")

  test "error if `bin` is a source file (#597)":
    cd "issue597":
      let (output, exitCode) = execNimble("build")
      check exitCode != QuitSuccess
      check output.contains("entry should not be a source file: test.nim")

  test "init does not overwrite existing files (#581)":
    createDir("issue581/src")
    cd "issue581":
      const Src = "echo \"OK\""
      writeFile("src/issue581.nim", Src)
      check execNimbleYes("init").exitCode == QuitSuccess
      check readFile("src/issue581.nim") == Src
    removeDir("issue581")

  test "issue 564":
    cd "issue564":
      let (_, exitCode) = execNimble("build")
      check exitCode == QuitSuccess

  test "issues #280 and #524":
    check execNimbleYes("install", "https://github.com/nimble-test/issue280and524.git").exitCode == 0

  test "issues #308 and #515":
    let
      ext = when defined(Windows): ExeExt else: "out"
    cd "issue308515" / "v1":
      var (output, exitCode) = execNimble(["run", "binname", "--silent"])
      check exitCode == QuitSuccess
      check output.contains "binname"

      (output, exitCode) = execNimble(["run", "binname-2", "--silent"])
      check exitCode == QuitSuccess
      check output.contains "binname-2"

      # Install v1 and check
      (output, exitCode) = execNimbleYes(["install", "--verbose"])
      check exitCode == QuitSuccess
      check output.contains "binname-0.1.0" / "binname".addFileExt(ext)
      check output.contains "binname-0.1.0" / "binname-2"

      (output, exitCode) = execBin("binname")
      check exitCode == QuitSuccess
      check output.contains "binname 0.1.0"
      (output, exitCode) = execBin("binname-2")
      check exitCode == QuitSuccess
      check output.contains "binname-2 0.1.0"

    cd "issue308515" / "v2":
      # Install v2 and check
      var (output, exitCode) = execNimbleYes(["install", "--verbose"])
      check exitCode == QuitSuccess
      check output.contains "binname-0.2.0" / "binname".addFileExt(ext)
      check output.contains "binname-0.2.0" / "binname-2"

      (output, exitCode) = execBin("binname")
      check exitCode == QuitSuccess
      check output.contains "binname 0.2.0"
      (output, exitCode) = execBin("binname-2")
      check exitCode == QuitSuccess
      check output.contains "binname-2 0.2.0"

      # Uninstall and check v1 back
      (output, exitCode) = execNimbleYes("uninstall", "binname@0.2.0")
      check exitCode == QuitSuccess

      (output, exitCode) = execBin("binname")
      check exitCode == QuitSuccess
      check output.contains "binname 0.1.0"
      (output, exitCode) = execBin("binname-2")
      check exitCode == QuitSuccess
      check output.contains "binname-2 0.1.0"

  test "issue 432":
    cd "issue432":
      check execNimbleYes("install", "--depsOnly").exitCode == QuitSuccess
      check execNimbleYes("install", "--depsOnly").exitCode == QuitSuccess

  test "issue #428":
    cd "issue428":
      # Note: Can't use execNimble because it patches nimbleDir
      check execCmdEx(nimblePath & " -y --nimbleDir=./nimbleDir install").exitCode == QuitSuccess
      check dirExists("nimbleDir/pkgs/dummy-0.1.0")
      check(not dirExists("nimbleDir/pkgs/dummy-0.1.0/nimbleDir"))

  test "issue 399":
    cd "issue399":
      var (output, exitCode) = execNimbleYes("install")
      check exitCode == QuitSuccess

      (output, exitCode) = execBin("subbin")
      check exitCode == QuitSuccess
      check output.contains("subbin-1")

  test "can pass args with spaces to Nim (#351)":
    cd "binaryPackage/v2":
      let (output, exitCode) = execCmdEx(nimblePath &
                                        " c -r" &
                                        " -d:myVar=\"string with spaces\"" &
                                        " binaryPackage")
      checkpoint output
      check exitCode == QuitSuccess

  test "issue #349":
    let reservedNames = [
      "CON",
      "PRN",
      "AUX",
      "NUL",
      "COM1",
      "COM2",
      "COM3",
      "COM4",
      "COM5",
      "COM6",
      "COM7",
      "COM8",
      "COM9",
      "LPT1",
      "LPT2",
      "LPT3",
      "LPT4",
      "LPT5",
      "LPT6",
      "LPT7",
      "LPT8",
      "LPT9",
    ]

    proc checkName(name: string) =
      let (outp, code) = execNimbleYes("init", name)
      let msg = outp.strip.processOutput()
      check code == QuitFailure
      check inLines(msg,
        "\"$1\" is an invalid package name: reserved name" % name)
      try:
        removeFile(name.changeFileExt("nimble"))
        removeDir("src")
        removeDir("tests")
      except OSError:
        discard

    for reserved in reservedNames:
      checkName(reserved.toUpperAscii())
      checkName(reserved.toLowerAscii())

  test "issue #338":
    cd "issue338":
      check execNimbleYes("install").exitCode == QuitSuccess

  test "can distinguish package reading in nimbleDir vs. other dirs (#304)":
    cd "issue304" / "package-test":
      check execNimble("tasks").exitCode == QuitSuccess

  test "can build with #head and versioned package (#289)":
    cd "issue289":
      check execNimbleYes("install").exitCode == QuitSuccess

    check execNimbleYes(["uninstall", "issue289"]).exitCode == QuitSuccess
    check execNimbleYes(["uninstall", "packagea"]).exitCode == QuitSuccess

  test "issue #206":
    cd "issue206":
      var (output, exitCode) = execNimbleYes("install")
      check exitCode == QuitSuccess
      (output, exitCode) = execNimbleYes("install")
      check exitCode == QuitSuccess

  test "can install diamond deps (#184)":
    cd "diamond_deps":
      cd "d":
        check execNimbleYes("install").exitCode == 0
      cd "c":
        check execNimbleYes("install").exitCode == 0
      cd "b":
        check execNimbleYes("install").exitCode == 0
      cd "a":
        # TODO: This doesn't really test anything. But I couldn't quite
        # reproduce #184.
        let (output, exitCode) = execNimbleYes("install")
        checkpoint(output)
        check exitCode == 0

  test "can validate package structure (#144)":
    # Test that no warnings are produced for correctly structured packages.
    for package in ["a", "b", "c", "validBinary", "softened"]:
      cd "packageStructure/" & package:
        let (output, exitCode) = execNimbleYes("install")
        check exitCode == QuitSuccess
        let lines = output.strip.processOutput()
        check(not lines.hasLineStartingWith("Warning:"))

    # Test that warnings are produced for the incorrectly structured packages.
    for package in ["x", "y", "z"]:
      cd "packageStructure/" & package:
        let (output, exitCode) = execNimbleYes("install")
        check exitCode == QuitSuccess
        let lines = output.strip.processOutput()
        checkpoint(output)
        case package
        of "x":
          check lines.hasLineStartingWith(
            "Warning: Package 'x' has an incorrect structure. It should" &
            " contain a single directory hierarchy for source files," &
            " named 'x', but file 'foobar.nim' is in a directory named" &
            " 'incorrect' instead.")
        of "y":
          check lines.hasLineStartingWith(
            "Warning: Package 'y' has an incorrect structure. It should" &
            " contain a single directory hierarchy for source files," &
            " named 'ypkg', but file 'foobar.nim' is in a directory named" &
            " 'yWrong' instead.")
        of "z":
          check lines.hasLineStartingWith(
            "Warning: Package 'z' has an incorrect structure. The top level" &
            " of the package source directory should contain at most one module," &
            " named 'z.nim', but a file named 'incorrect.nim' was found.")
        else:
          assert false

  test "issue 129 (installing commit hash)":
    let arguments = @["install",
                    "https://github.com/nimble-test/packagea.git@#1f9cb289c89"]
    check execNimbleYes(arguments).exitCode == QuitSuccess
    # Verify that it was installed correctly.
    check dirExists(installDir / "pkgs" / "PackageA-#1f9cb289c89")
    # Remove it so that it doesn't interfere with the uninstall tests.
    check execNimbleYes("uninstall", "packagea@#1f9cb289c89").exitCode ==
          QuitSuccess

  test "issue #126":
    cd "issue126/a":
      let (output, exitCode) = execNimbleYes("install")
      let lines = output.strip.processOutput()
      check exitCode != QuitSuccess # TODO
      check inLines(lines, "issue-126 is an invalid package name: cannot contain '-'")

    cd "issue126/b":
      let (output1, exitCode1) = execNimbleYes("install")
      let lines1 = output1.strip.processOutput()
      check exitCode1 != QuitSuccess
      check inLines(lines1, "The .nimble file name must match name specified inside")

  test "issue 113 (uninstallation problems)":
    cd "issue113/c":
      check execNimbleYes("install").exitCode == QuitSuccess
    cd "issue113/b":
      check execNimbleYes("install").exitCode == QuitSuccess
    cd "issue113/a":
      check execNimbleYes("install").exitCode == QuitSuccess

    # Try to remove c.
    let (output, exitCode) = execNimbleYes(["remove", "c"])
    let lines = output.strip.processOutput()
    check exitCode != QuitSuccess
    check inLines(lines, "cannot uninstall c (0.1.0) because b (0.1.0) depends on it")

    check execNimbleYes(["remove", "a"]).exitCode == QuitSuccess
    check execNimbleYes(["remove", "b"]).exitCode == QuitSuccess

    cd "issue113/buildfail":
      check execNimbleYes("install").exitCode != QuitSuccess

    check execNimbleYes(["remove", "c"]).exitCode == QuitSuccess

  test "issue #108":
    cd "issue108":
      let (output, exitCode) = execNimble("build")
      let lines = output.strip.processOutput()
      check exitCode != QuitSuccess
      check inLines(lines, "Nothing to build")
