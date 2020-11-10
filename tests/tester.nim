# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
import osproc, unittest, strutils, os, sequtils, sugar, json, std/sha1,
       strformat, macros, sets

import nimblepkg/common, nimblepkg/displaymessages, nimblepkg/paths

from nimblepkg/developfile import
  developFileName, developFileVersion, pkgFoundMoreThanOnceMsg
from nimblepkg/nimbledatafile import
  loadNimbleData, nimbleDataFileName, NimbleDataJsonKeys
from nimblepkg/version import VersionRange, parseVersionRange

# TODO: Each test should start off with a clean slate. Currently installed
# packages are shared between each test which causes a multitude of issues
# and is really fragile.

const
  stringNotFound = -1
  pkgAUrl = "https://github.com/nimble-test/packagea.git"
  pkgBUrl = "https://github.com/nimble-test/packageb.git"
  pkgBinUrl = "https://github.com/nimble-test/packagebin.git"
  pkgBin2Url = "https://github.com/nimble-test/packagebin2.git"
  pkgMultiUrl = "https://github.com/nimble-test/multi"
  pkgMultiAlphaUrl = &"{pkgMultiUrl}?subdir=alpha"
  pkgMultiBetaUrl = &"{pkgMultiUrl}?subdir=beta"

let
  rootDir = getCurrentDir().parentDir()
  nimblePath = rootDir / "src" / addFileExt("nimble", ExeExt)
  installDir = rootDir / "tests" / "nimbleDir"
  buildTests = rootDir / "buildTests"
  pkgsDir = installDir / nimblePackagesDirName

# Set env var to propagate nimble binary path
putEnv("NIMBLE_TEST_BINARY_PATH", nimblePath)

# Always recompile.
doAssert execCmdEx("nim c -d:danger " & nimblePath).exitCode == QuitSuccess

proc execNimble(args: varargs[string]): ProcessOutput =
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

proc execNimbleYes(args: varargs[string]): ProcessOutput =
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

macro defineInLinesProc(procName, extraLine: untyped): untyped  =
  var LinesType = quote do: seq[string]
  if extraLine[0].kind != nnkDiscardStmt:
    LinesType = newTree(nnkVarTy, LinesType)

  let linesParam = ident("lines")
  let linesLoopCounter = ident("i")

  result = quote do:
    proc `procName`(`linesParam`: `LinesType`, msg: string): bool =
      let msgLines = msg.splitLines
      for msgLine in msgLines:
        let msgLine = msgLine.normalize
        var msgLineFound = false
        for `linesLoopCounter`, line in `linesParam`:
          if msgLine in line.normalize:
            msgLineFound = true
            `extraLine`
            break
        if not msgLineFound:
          return false
      return true

defineInLinesProc(inLines): discard
defineInLinesProc(inLinesOrdered): lines = lines[i + 1 .. ^1]

proc hasLineStartingWith(lines: seq[string], prefix: string): bool =
  for line in lines:
    if line.strip(trailing = false).startsWith(prefix):
      return true
  return false

proc getPackageDir(pkgCacheDir, pkgDirPrefix: string, fullPath = true): string =
  for kind, dir in walkDir(pkgCacheDir):
    if kind != pcDir or not dir.startsWith(pkgCacheDir / pkgDirPrefix):
      continue
    let pkgChecksumStartIndex = dir.rfind('-')
    if pkgChecksumStartIndex == -1:
      continue
    let pkgChecksum = dir[pkgChecksumStartIndex + 1 .. ^1]
    if pkgChecksum.isValidSha1Hash():
      return if fullPath: dir else: dir.splitPath.tail
  return ""

proc packageDirExists(pkgCacheDir, pkgDirPrefix: string): bool =
  getPackageDir(pkgCacheDir, pkgDirPrefix).len > 0

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
  else:
    # If the old config doesn't exist, we should still get rid of this new
    # config to not screw up the other tests.
    removeFile(configFile)

proc beforeSuite() =
  # Clear nimble dir.
  removeDir(installDir)
  createDir(installDir)

template usePackageListFile(fileName: string, body: untyped) =
  testRefresh():
    writeFile(configFile, """
      [PackageList]
      name = "local"
      path = "$1"
    """.unindent % (fileName).replace("\\", "\\\\"))
    check execNimble(["refresh"]).exitCode == QuitSuccess
    body

template cleanFile(fileName: string) =
  removeFile fileName
  defer: removeFile fileName

macro cleanFiles(fileNames: varargs[string]) =
  result = newStmtList()
  for fn in fileNames:
    result.add quote do: cleanFile(`fn`)

template cleanDir(dirName: string) =
  removeDir dirName
  defer: removeDir dirName

template createTempDir(dirName: string) =
  createDir dirName
  defer: removeDir dirName

template cdCleanDir(dirName: string, body: untyped) =
  cleanDir dirName
  createDir dirName
  cd dirName:
    body

suite "nimble refresh":
  beforeSuite()

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
  beforeSuite()

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
      let packageDir = getPackageDir(pkgsDir, "nimscript-0.1.0")
      check lines[^1].strip(leading = false).endsWith(packageDir)

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
      let (output, exitCode) = execNimble("work")
      let lines = output.strip.processOutput()
      check exitCode == QuitSuccess
      check lines[^1] == "10"

  test "can use nimscript's setCommand":
    cd "nimscript":
      let (output, exitCode) = execNimble("cTest")
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
      check lines.inLines("undeclared identifier: 'thisFieldDoesNotExist'")
      check exitCode == QuitFailure

  test "can accept short flags (#329)":
    cd "nimscript":
      check execNimble("c", "-d:release", "nimscript.nim").exitCode == QuitSuccess

suite "uninstall":
  beforeSuite()

  test "can install packagebin2":
    let args = ["install", pkgBin2Url]
    check execNimbleYes(args).exitCode == QuitSuccess

  proc cannotSatisfyMsg(v1, v2: string): string =
     &"Cannot satisfy the dependency on PackageA {v1} and PackageA {v2}"

  test "can reject same version dependencies":
    let (outp, exitCode) = execNimbleYes("install", pkgBinUrl)
    # We look at the error output here to avoid out-of-order problems caused by
    # stderr output being generated and flushed without first flushing stdout
    let ls = outp.strip.processOutput()
    check exitCode != QuitSuccess
    check ls.inLines(cannotSatisfyMsg("0.2.0", "0.5.0")) or
          ls.inLines(cannotSatisfyMsg("0.5.0", "0.2.0"))

  proc setupIssue27Packages() =
    # Install b
    cd "issue27/b":
      check execNimbleYes("install").exitCode == QuitSuccess
    # Install a
    cd "issue27/a":
      check execNimbleYes("install").exitCode == QuitSuccess
    cd "issue27":
      check execNimbleYes("install").exitCode == QuitSuccess

  test "issue #27":
    setupIssue27Packages()

  test "can uninstall":
    # setup test environment
    cleanDir(installDir)
    setupIssue27Packages()
    check execNimbleYes("install", &"{pkgAUrl}@0.2").exitCode == QuitSuccess
    check execNimbleYes("install", &"{pkgAUrl}@0.5").exitCode == QuitSuccess
    check execNimbleYes("install", &"{pkgAUrl}@0.6").exitCode == QuitSuccess
    check execNimbleYes("install", pkgBin2Url).exitCode == QuitSuccess
    check execNimbleYes("install", pkgBUrl).exitCode == QuitSuccess
    cd "nimscript": check execNimbleYes("install").exitCode == QuitSuccess

    block:
      let (outp, exitCode) = execNimbleYes("uninstall", "issue27b")
      check exitCode != QuitSuccess
      var ls = outp.strip.processOutput()
      let pkg27ADir = getPackageDir(pkgsDir, "issue27a-0.1.0", false)
      let expectedMsg = cannotUninstallPkgMsg("issue27b", "0.1.0", @[pkg27ADir])
      check ls.inLinesOrdered(expectedMsg)

      check execNimbleYes("uninstall", "issue27").exitCode == QuitSuccess
      check execNimbleYes("uninstall", "issue27a").exitCode == QuitSuccess

    # Remove Package*
    check execNimbleYes("uninstall", "PackageA@0.5").exitCode == QuitSuccess

    let (outp, exitCode) = execNimbleYes("uninstall", "PackageA")
    check exitCode != QuitSuccess
    let ls = outp.processOutput()
    let
      pkgBin2Dir = getPackageDir(pkgsDir, "packagebin2-0.1.0", false)
      pkgBDir = getPackageDir(pkgsDir, "packageb-0.1.0", false)
      expectedMsgForPkgA0dot6 = cannotUninstallPkgMsg(
        "PackageA", "0.6.0", @[pkgBin2Dir])
      expectedMsgForPkgA0dot2 = cannotUninstallPkgMsg(
        "PackageA", "0.2.0", @[pkgBDir])
    check ls.inLines(expectedMsgForPkgA0dot6)
    check ls.inLines(expectedMsgForPkgA0dot2)

    check execNimbleYes("uninstall", "PackageBin2").exitCode == QuitSuccess

    # Case insensitive
    check execNimbleYes("uninstall", "packagea").exitCode == QuitSuccess
    check execNimbleYes("uninstall", "PackageA").exitCode != QuitSuccess

    # Remove the rest of the installed packages.
    check execNimbleYes("uninstall", "PackageB").exitCode == QuitSuccess

    check execNimbleYes("uninstall", "PackageA@0.2", "issue27b").exitCode ==
        QuitSuccess
    check(not dirExists(installDir / "pkgs" / "PackageA-0.2.0"))

suite "nimble dump":
  beforeSuite()

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
  beforeSuite()

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
  beforeSuite()

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
    check execNimbleYes("--debug", "install", "nimboost@0.5.5", "nimfp@0.4.4").exitCode == QuitSuccess

    var (output, exitCode) = execNimble("uninstall", "nimboost", "nimfp", "-n")
    var lines = output.strip.processOutput()
    check inLines(lines, "Cannot uninstall nimboost")

    (output, exitCode) = execNimbleYes("uninstall", "nimfp", "nimboost")
    lines = output.strip.processOutput()
    check (not inLines(lines, "Cannot uninstall nimboost"))

    check execNimble("path", "nimboost").exitCode != QuitSuccess
    check execNimble("path", "nimfp").exitCode != QuitSuccess

  test "old format conversion":
    const oldNimbleDataFileName =
      "./revdep/nimbleData/old_nimble_data.json".normalizedPath
    const newNimbleDataFileName =
      "./revdep/nimbleData/new_nimble_data.json".normalizedPath

    doAssert fileExists(oldNimbleDataFileName)
    doAssert fileExists(newNimbleDataFileName)

    let oldNimbleData = loadNimbleData(oldNimbleDataFileName)
    let newNimbleData = loadNimbleData(newNimbleDataFileName)

    doAssert oldNimbleData == newNimbleData

suite "develop feature":
  proc filesList(filesNames: seq[string]): string =
    for fileName in filesNames:
      result.addQuoted fileName
      result.add ','

  proc developFile(includes: seq[string], dependencies: seq[string]): string =
    result = """{"version":"$#","includes":[$#],"dependencies":[$#]}""" %
      [developFileVersion, filesList(includes), filesList(dependencies)]

  const
    pkgListFileName = "packages.json"
    dependentPkgName = "dependent"
    dependentPkgVersion = "1.0"
    dependentPkgNameAndVersion = &"{dependentPkgName}@{dependentPkgVersion}"
    dependentPkgPath = "develop/dependent".normalizedPath
    includeFileName = "included.develop"
    pkgAName = "packagea"
    pkgBName = "packageb"
    pkgSrcDirTestName = "srcdirtest"
    pkgHybridName = "hybrid"
    depPath = "../dependency".normalizedPath
    depName = "dependency"
    depVersion = "0.1.0"
    depNameAndVersion = &"{depName}@{depVersion}"
    dep2Path = "../dependency2".normalizedPath
    emptyDevelopFileContent = developFile(@[], @[])
  
  let anyVersion = parseVersionRange("")

  test "can develop from dir with srcDir":
    cd &"develop/{pkgSrcDirTestName}":
      let (output, exitCode) = execNimble("develop")
      check exitCode == QuitSuccess
      let lines = output.processOutput
      check not lines.inLines("will not be compiled")
      check lines.inLines(pkgSetupInDevModeMsg(
        pkgSrcDirTestName, getCurrentDir()))

  test "can git clone for develop":
    cdCleanDir installDir:
      let (output, exitCode) = execNimble("develop", pkgAUrl)
      check exitCode == QuitSuccess
      check output.processOutput.inLines(
        pkgSetupInDevModeMsg(pkgAName, installDir / pkgAName))

  test "can develop from package name":
    cdCleanDir installDir:
      usePackageListFile &"../develop/{pkgListFileName}":
        let (output, exitCode) = execNimble("develop", pkgBName)
        check exitCode == QuitSuccess
        var lines = output.processOutput
        check lines.inLinesOrdered(pkgInstalledMsg(pkgAName))
        check lines.inLinesOrdered(
          pkgSetupInDevModeMsg(pkgBName, installDir / pkgBName))

  test "can develop list of packages":
    cdCleanDir installDir:
      usePackageListFile &"../develop/{pkgListFileName}":
        let (output, exitCode) = execNimble(
          "develop", pkgAName, pkgBName)
        check exitCode == QuitSuccess
        var lines = output.processOutput
        check lines.inLinesOrdered(pkgSetupInDevModeMsg(
          pkgAName, installDir / pkgAName))
        check lines.inLinesOrdered(pkgInstalledMsg(pkgAName))
        check lines.inLinesOrdered(pkgSetupInDevModeMsg(
          pkgBName, installDir / pkgBName))

  test "cannot remove package with develop reverse dependency":
    cdCleanDir installDir:
      usePackageListFile &"../develop/{pkgListFileName}":
        check execNimble("develop", pkgBName).exitCode == QuitSuccess
        let (output, exitCode) = execNimble("remove", pkgAName)
        check exitCode == QuitFailure
        var lines = output.processOutput
        check lines.inLinesOrdered(
          cannotUninstallPkgMsg(pkgAName, "0.2.0", @[installDir / pkgBName]))

  test "can reject binary packages":
    cd "develop/binary":
      let (output, exitCode) = execNimble("develop")
      check output.processOutput.inLines("cannot develop packages")
      check exitCode == QuitFailure

  test "can develop hybrid":
    cd &"develop/{pkgHybridName}":
      let (output, exitCode) = execNimble("develop")
      check exitCode == QuitSuccess
      var lines = output.processOutput
      check lines.inLinesOrdered("will not be compiled")
      check lines.inLinesOrdered(
        pkgSetupInDevModeMsg(pkgHybridName, getCurrentDir()))

  test "can specify different absolute clone dir":
    let otherDir = installDir / "./some/other/dir"
    cleanDir otherDir
    let (output, exitCode) = execNimble(
      "develop", &"-p:{otherDir}", pkgAUrl)
    check exitCode == QuitSuccess
    check output.processOutput.inLines(
      pkgSetupInDevModeMsg(pkgAName, otherDir / pkgAName))

  test "can specify different relative clone dir":
    const otherDir = "./some/other/dir"
    cdCleanDir installDir:
      let (output, exitCode) = execNimble(
        "develop", &"-p:{otherDir}", pkgAUrl)
      check exitCode == QuitSuccess
      check output.processOutput.inLines(
        pkgSetupInDevModeMsg(pkgAName, installDir / otherDir / pkgAName))

  test "do not allow multiple path options":
    let
      developDir = installDir / "./some/dir"
      anotherDevelopDir = installDir / "./some/other/dir"
    defer:
      # cleanup in the case of test failure
      removeDir developDir
      removeDir anotherDevelopDir
    let (output, exitCode) = execNimble(
      "develop", &"-p:{developDir}", &"-p:{anotherDevelopDir}", pkgAUrl)
    check exitCode == QuitFailure
    check output.processOutput.inLines("Multiple path options are given")
    check not developDir.dirExists
    check not anotherDevelopDir.dirExists

  test "do not allow path option without packages to download":
    let developDir = installDir / "./some/dir"
    let (output, exitCode) = execNimble("develop", &"-p:{developDir}")
    check exitCode == QuitFailure
    check output.processOutput.inLines(pathGivenButNoPkgsToDownloadMsg)
    check not developDir.dirExists

  test "do not allow add/remove options out of package directory":
    cleanFile developFileName
    let (output, exitCode) = execNimble("develop", "-a:./develop/dependency/")
    check exitCode == QuitFailure
    check output.processOutput.inLines(developOptionsOutOfPkgDirectoryMsg)

  test "cannot load invalid develop file":
    cd dependentPkgPath:
      cleanFile developFileName
      writeFile(developFileName, "this is not a develop file")
      let (output, exitCode) = execNimble("check")
      check exitCode == QuitFailure
      var lines = output.processOutput
      check lines.inLinesOrdered(
        notAValidDevFileJsonMsg(getCurrentDir() / developFileName))
      check lines.inLinesOrdered(validationFailedMsg)

  test "add downloaded package to the develop file":
    cleanDir installDir
    cd "develop/dependency":
      usePackageListFile &"../{pkgListFileName}":
        cleanFile developFileName
        let
          (output, exitCode) = execNimble(
            "develop", &"-p:{installDir}", pkgAName)
          pkgAAbsPath = installDir / pkgAName
          developFileContent = developFile(@[], @[pkgAAbsPath])
        check exitCode == QuitSuccess
        check parseFile(developFileName) == parseJson(developFileContent)
        var lines = output.processOutput
        check lines.inLinesOrdered(pkgSetupInDevModeMsg(pkgAName, pkgAAbsPath))
        check lines.inLinesOrdered(
          pkgAddedInDevModeMsg(&"{pkgAName}@0.6.0", pkgAAbsPath))

  test "cannot add not a dependency downloaded package to the develop file":
    cleanDir installDir
    cd "develop/dependency":
      usePackageListFile &"../{pkgListFileName}":
        cleanFile developFileName
        let
          (output, exitCode) = execNimble(
            "develop", &"-p:{installDir}", pkgAName, pkgBName)
          pkgAAbsPath = installDir / pkgAName
          pkgBAbsPath = installDir / pkgBName
          developFileContent = developFile(@[], @[pkgAAbsPath])
        check exitCode == QuitFailure
        check parseFile(developFileName) == parseJson(developFileContent)
        var lines = output.processOutput
        check lines.inLinesOrdered(pkgSetupInDevModeMsg(pkgAName, pkgAAbsPath))
        check lines.inLinesOrdered(pkgSetupInDevModeMsg(pkgBName, pkgBAbsPath))
        check lines.inLinesOrdered(
          pkgAddedInDevModeMsg(&"{pkgAName}@0.6.0", pkgAAbsPath))
        check lines.inLinesOrdered(
          notADependencyErrorMsg(&"{pkgBName}@0.2.0", depNameAndVersion))

  test "add package to develop file":
    cleanDir installDir
    cd dependentPkgPath:
      usePackageListFile &"../{pkgListFileName}":
        cleanFiles developFileName, dependentPkgName.addFileExt(ExeExt)
        var (output, exitCode) = execNimble("develop", &"-a:{depPath}")
        check exitCode == QuitSuccess
        check developFileName.fileExists
        check output.processOutput.inLines(
          pkgAddedInDevModeMsg(depNameAndVersion, depPath))
        const expectedDevelopFile = developFile(@[], @[depPath])
        check parseFile(developFileName) == parseJson(expectedDevelopFile)
        (output, exitCode) = execNimble("run")
        check exitCode == QuitSuccess
        check output.processOutput.inLines(pkgInstalledMsg(pkgAName))

  test "warning on attempt to add the same package twice":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      let (output, exitCode) = execNimble("develop", &"-a:{depPath}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(
        pkgAlreadyInDevModeMsg(depNameAndVersion, depPath))
      check parseFile(developFileName) ==  parseJson(developFileContent)

  test "cannot add invalid package to develop file":
    cd dependentPkgPath:
      cleanFile developFileName
      const invalidPkgDir = "../invalidPkg".normalizedPath
      createTempDir invalidPkgDir
      let (output, exitCode) = execNimble("develop", &"-a:{invalidPkgDir}")
      check exitCode == QuitFailure
      check output.processOutput.inLines(invalidPkgMsg(invalidPkgDir))
      check not developFileName.fileExists

  test "cannot add not a dependency to develop file":
    cd dependentPkgPath:
      cleanFile developFileName
      let (output, exitCode) = execNimble("develop", "-a:../srcdirtest/")
      check exitCode == QuitFailure
      check output.processOutput.inLines(
        notADependencyErrorMsg(&"{pkgSrcDirTestName}@1.0", "dependent@1.0"))
      check not developFileName.fileExists

  test "cannot add two packages with the same name to develop file":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      let (output, exitCode) = execNimble("develop", &"-a:{dep2Path}")
      check exitCode == QuitFailure
      check output.processOutput.inLines(
        pkgAlreadyPresentAtDifferentPathMsg(depName, depPath.absolutePath))
      check parseFile(developFileName) == parseJson(developFileContent)

  test "found two packages with the same name in the develop file":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(
        @[], @[depPath, dep2Path])
      writeFile(developFileName, developFileContent)

      let
        (output, exitCode) = execNimble("check")
        developFilePath = getCurrentDir() / developFileName

      check exitCode == QuitFailure
      var lines = output.processOutput
      check lines.inLinesOrdered(failedToLoadFileMsg(developFilePath))
      check lines.inLinesOrdered(pkgFoundMoreThanOnceMsg(depName,
        [(depPath.absolutePath.Path, developFilePath.Path), 
         (dep2Path.absolutePath.Path, developFilePath.Path)].toHashSet))
      check lines.inLinesOrdered(validationFailedMsg)

  test "remove package from develop file by path":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      let (output, exitCode) = execNimble("develop", &"-r:{depPath}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(
        pkgRemovedFromDevModeMsg(depNameAndVersion, depPath))
      check parseFile(developFileName) == parseJson(emptyDevelopFileContent)

  test "warning on attempt to remove not existing package path":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      let (output, exitCode) = execNimble("develop", &"-r:{dep2Path}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(pkgPathNotInDevFileMsg(dep2Path))
      check parseFile(developFileName) == parseJson(developFileContent)

  test "remove package from develop file by name":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      let (output, exitCode) = execNimble("develop", &"-n:{depName}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(
        pkgRemovedFromDevModeMsg(depNameAndVersion, depPath.absolutePath))
      check parseFile(developFileName) == parseJson(emptyDevelopFileContent)

  test "warning on attempt to remove not existing package name":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      const notExistingPkgName = "dependency2"
      let (output, exitCode) = execNimble("develop", &"-n:{notExistingPkgName}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(
        pkgNameNotInDevFileMsg(notExistingPkgName))
      check parseFile(developFileName) == parseJson(developFileContent)

  test "include develop file":
    cleanDir installDir
    cd dependentPkgPath:
      usePackageListFile &"../{pkgListFileName}":
        cleanFiles developFileName, includeFileName,
                   dependentPkgName.addFileExt(ExeExt)
        const includeFileContent = developFile(@[], @[depPath])
        writeFile(includeFileName, includeFileContent)
        var (output, exitCode) = execNimble("develop", &"-i:{includeFileName}")
        check exitCode == QuitSuccess
        check developFileName.fileExists
        check output.processOutput.inLines(inclInDevFileMsg(includeFileName))
        const expectedDevelopFile = developFile(@[includeFileName], @[])
        check parseFile(developFileName) == parseJson(expectedDevelopFile)
        (output, exitCode) = execNimble("run")
        check exitCode == QuitSuccess
        check output.processOutput.inLines(pkgInstalledMsg(pkgAName))

  test "warning on attempt to include already included develop file":
    cd dependentPkgPath:
      cleanFiles developFileName, includeFileName
      const developFileContent = developFile(@[includeFileName], @[])
      writeFile(developFileName, developFileContent)
      const includeFileContent = developFile(@[], @[depPath])
      writeFile(includeFileName, includeFileContent)

      let (output, exitCode) = execNimble("develop", &"-i:{includeFileName}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(
        alreadyInclInDevFileMsg(includeFileName))
      check parseFile(developFileName) == parseJson(developFileContent)

  test "cannot include invalid develop file":
    cd dependentPkgPath:
      cleanFiles developFileName, includeFileName
      writeFile(includeFileName, """{"some": "json"}""")
      let (output, exitCode) = execNimble("develop", &"-i:{includeFileName}")
      check exitCode == QuitFailure
      check not developFileName.fileExists
      check output.processOutput.inLines(failedToLoadFileMsg(includeFileName))

  test "cannot load a develop file with an invalid include file in it":
    cd dependentPkgPath:
      cleanFiles developFileName, includeFileName
      const developFileContent = developFile(@[includeFileName], @[])
      writeFile(developFileName, developFileContent)
      let (output, exitCode) = execNimble("check")
      check exitCode == QuitFailure
      let developFilePath = getCurrentDir() / developFileName
      var lines = output.processOutput()
      check lines.inLinesOrdered(failedToLoadFileMsg(developFilePath))
      check lines.inLinesOrdered(invalidDevFileMsg(developFilePath))
      check lines.inLinesOrdered(&"cannot read from file: {includeFileName}")
      check lines.inLinesOrdered(validationFailedMsg)

  test "can include file pointing to the same package":
    cleanDir installDir
    cd dependentPkgPath:
      usePackageListFile &"../{pkgListFileName}":
        cleanFiles developFileName, includeFileName,
                   dependentPkgName.addFileExt(ExeExt)
        const fileContent = developFile(@[], @[depPath])
        writeFile(developFileName, fileContent)
        writeFile(includeFileName, fileContent)
        var (output, exitCode) = execNimble("develop", &"-i:{includeFileName}")
        check exitCode == QuitSuccess
        check output.processOutput.inLines(inclInDevFileMsg(includeFileName))
        const expectedFileContent = developFile(
          @[includeFileName], @[depPath])
        check parseFile(developFileName) == parseJson(expectedFileContent)
        (output, exitCode) = execNimble("run")
        check exitCode == QuitSuccess
        check output.processOutput.inLines(pkgInstalledMsg(pkgAName))

  test "cannot include conflicting develop file":
    cd dependentPkgPath:
      cleanFiles developFileName, includeFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      const includeFileContent = developFile(@[], @[dep2Path])
      writeFile(includeFileName, includeFileContent)

      let
        (output, exitCode) = execNimble("develop", &"-i:{includeFileName}")
        developFilePath = getCurrentDir() / developFileName

      check exitCode == QuitFailure
      var lines = output.processOutput
      check lines.inLinesOrdered(
        failedToInclInDevFileMsg(includeFileName, developFilePath))
      check lines.inLinesOrdered(pkgFoundMoreThanOnceMsg(depName,
        [(depPath.absolutePath.Path, developFilePath.Path),
         (dep2Path.Path, includeFileName.Path)].toHashSet))
      check parseFile(developFileName) == parseJson(developFileContent)

  test "validate included dependencies version":
    cd &"{dependentPkgPath}2":
      cleanFiles developFileName, includeFileName
      const includeFileContent = developFile(@[], @[dep2Path])
      writeFile(includeFileName, includeFileContent)
      let (output, exitCode) = execNimble("develop", &"-i:{includeFileName}")
      check exitCode == QuitFailure
      var lines = output.processOutput
      let developFilePath = getCurrentDir() / developFileName
      check lines.inLinesOrdered(
        failedToInclInDevFileMsg(includeFileName, developFilePath))
      check lines.inLinesOrdered(invalidPkgMsg(dep2Path))
      check lines.inLinesOrdered(dependencyNotInRangeErrorMsg(
        depNameAndVersion, dependentPkgNameAndVersion,
        parseVersionRange(">= 0.2.0")))
      check not developFileName.fileExists

  test "exclude develop file":
    cd dependentPkgPath:
      cleanFiles developFileName, includeFileName
      const developFileContent = developFile(@[includeFileName], @[])
      writeFile(developFileName, developFileContent)
      const includeFileContent = developFile(@[], @[depPath])
      writeFile(includeFileName, includeFileContent)
      let (output, exitCode) = execNimble("develop", &"-e:{includeFileName}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(exclFromDevFileMsg(includeFileName))
      check parseFile(developFileName) == parseJson(emptyDevelopFileContent)

  test "warning on attempt to exclude not included develop file":
    cd dependentPkgPath:
      cleanFiles developFileName, includeFileName
      const developFileContent = developFile(@[includeFileName], @[])
      writeFile(developFileName, developFileContent)
      const includeFileContent = developFile(@[], @[depPath])
      writeFile(includeFileName, includeFileContent)
      let (output, exitCode) = execNimble("develop", &"-e:../{includeFileName}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(
        notInclInDevFileMsg((&"../{includeFileName}").normalizedPath))
      check parseFile(developFileName) == parseJson(developFileContent)

  test "relative paths in the develop file and absolute from the command line":
    cd dependentPkgPath:
      cleanFiles developFileName, includeFileName
      const developFileContent = developFile(
        @[includeFileName], @[depPath])
      writeFile(developFileName, developFileContent)
      const includeFileContent = developFile(@[], @[depPath])
      writeFile(includeFileName, includeFileContent)

      let
        includeFileAbsolutePath = includeFileName.absolutePath
        dependencyPkgAbsolutePath = "../dependency".absolutePath
        (output, exitCode) = execNimble("develop",
          &"-e:{includeFileAbsolutePath}", &"-r:{dependencyPkgAbsolutePath}")

      check exitCode == QuitSuccess
      var lines = output.processOutput
      check lines.inLinesOrdered(exclFromDevFileMsg(includeFileAbsolutePath))
      check lines.inLinesOrdered(
        pkgRemovedFromDevModeMsg(depNameAndVersion, dependencyPkgAbsolutePath))
      check parseFile(developFileName) == parseJson(emptyDevelopFileContent)

  test "absolute paths in the develop file and relative from the command line":
    cd dependentPkgPath:
      let
        currentDir = getCurrentDir()
        includeFileAbsPath = currentDir / includeFileName
        dependencyAbsPath = currentDir / depPath
        developFileContent = developFile(
          @[includeFileAbsPath], @[dependencyAbsPath])
        includeFileContent = developFile(@[], @[depPath])

      cleanFiles developFileName, includeFileName
      writeFile(developFileName, developFileContent)
      writeFile(includeFileName, includeFileContent)

      let (output, exitCode) = execNimble("develop",
        &"-e:{includeFileName}", &"-r:{depPath}")

      check exitCode == QuitSuccess
      var lines = output.processOutput
      check lines.inLinesOrdered(exclFromDevFileMsg(includeFileName))
      check lines.inLinesOrdered(
        pkgRemovedFromDevModeMsg(depNameAndVersion, depPath))
      check parseFile(developFileName) == parseJson(emptyDevelopFileContent)

  test "uninstall package with develop reverse dependencies":
    cleanDir installDir
    cd dependentPkgPath:
      usePackageListFile &"../{pkgListFileName}":
        const developFileContent = developFile(@[], @[depPath])
        cleanFiles developFileName, "dependent"
        writeFile(developFileName, developFileContent)

        block checkSuccessfulInstallAndReverseDependencyAddedToNimbleData:
          let
            (_, exitCode) = execNimble("install")
            nimbleData = parseFile(installDir / nimbleDataFileName)
            packageDir = getPackageDir(pkgsDir, "PackageA-0.5.0")
            checksum = packageDir[packageDir.rfind('-') + 1 .. ^1]
            devRevDepPath = nimbleData{$ndjkRevDep}{pkgAName}{"0.5.0"}{
              checksum}{0}{$ndjkRevDepPath}
            depAbsPath = getCurrentDir() / depPath

          check exitCode == QuitSuccess
          check not devRevDepPath.isNil
          check devRevDepPath.str == depAbsPath

        block checkSuccessfulUninstallAndRemovalFromNimbleData:
          let
            (_, exitCode) = execNimble("uninstall", "-i", pkgAName, "-y")
            nimbleData = parseFile(installDir / nimbleDataFileName)

          check exitCode == QuitSuccess
          check not nimbleData[$ndjkRevDep].hasKey(pkgAName)

  test "follow develop dependency's develop file":
    cd "develop":
      const pkg1DevFilePath = "pkg1" / developFileName
      const pkg2DevFilePath = "pkg2" / developFileName
      cleanFiles pkg1DevFilePath, pkg2DevFilePath
      const pkg1DevFileContent = developFile(@[], @["../pkg2"])
      writeFile(pkg1DevFilePath, pkg1DevFileContent)
      const pkg2DevFileContent = developFile(@[], @["../pkg3"])
      writeFile(pkg2DevFilePath, pkg2DevFileContent)
      cd "pkg1":
        cleanFile "pkg1".addFileExt(ExeExt)
        let (_, exitCode) = execNimble("run", "-n")
        check exitCode == QuitSuccess

  test "version clash from followed develop file":
    cd "develop":
      const pkg1DevFilePath = "pkg1" / developFileName
      const pkg2DevFilePath = "pkg2" / developFileName
      cleanFiles pkg1DevFilePath, pkg2DevFilePath
      const pkg1DevFileContent = developFile(@[], @["../pkg2", "../pkg3"])
      writeFile(pkg1DevFilePath, pkg1DevFileContent)
      const pkg2DevFileContent = developFile(@[], @["../pkg3.2"])
      writeFile(pkg2DevFilePath, pkg2DevFileContent)

      let
        currentDir = getCurrentDir()
        pkg1DevFileAbsPath = currentDir / pkg1DevFilePath
        pkg2DevFileAbsPath = currentDir / pkg2DevFilePath
        pkg3AbsPath = currentDir / "pkg3"
        pkg32AbsPath = currentDir / "pkg3.2"

      cd "pkg1":
        cleanFile "pkg1".addFileExt(ExeExt)
        let (output, exitCode) = execNimble("run", "-n")
        check exitCode == QuitFailure
        var lines = output.processOutput
        check lines.inLinesOrdered(failedToLoadFileMsg(pkg1DevFileAbsPath))
        check lines.inLinesOrdered(pkgFoundMoreThanOnceMsg("pkg3",
          [(pkg3AbsPath.Path, pkg1DevFileAbsPath.Path),
           (pkg32AbsPath.Path, pkg2DevFileAbsPath.Path)].toHashSet))

  test "relative include paths are followed from the file's directory":
    cd dependentPkgPath:
      const includeFilePath = &"../{includeFileName}"
      cleanFiles includeFilePath, developFileName, dependentPkgName.addFileExt(ExeExt)
      const developFileContent = developFile(@[includeFilePath], @[])
      writeFile(developFileName, developFileContent)
      const includeFileContent = developFile(@[], @["./dependency2/"])
      writeFile(includeFilePath, includeFileContent)
      let (_, errorCode) = execNimble("run", "-n")
      check errorCode == QuitSuccess

  test "filter not used included develop dependencies":
    # +--------------------------+                +--------------------------+
    # |           pkg1           |  +------------>|           pkg2           |
    # +--------------------------+  | dependency  +--------------------------+
    # | requires "pkg2", "pkg3"  |  |             |      nimble.develop      |
    # +--------------------------+  |             +--------------------------+
    # |      nimble.develop      |--+                           |
    # +--------------------------+                     includes |
    #                                                           v
    #                                                   +---------------+
    #                                                   | develop.json  |
    #                                                   +---------------+
    #                                                           |
    #                                                dependency |
    #                                                           v
    #                                                +---------------------+
    #                                                |         pkg3        |
    #                                                +---------------------+
    #                                                |  version = "0.2.0"  |
    #                                                +---------------------+

    # Here the build must fail because "pkg3" coming from develop file included
    # in "pkg2"'s develop file is not a dependency of "pkg2" itself and it must
    # be filtered. In this way "pkg1"'s dependency to "pkg3" is not satisfied.

    cd "develop":
      const
        pkg1DevFilePath = "pkg1" / developFileName
        pkg2DevFilePath = "pkg2.2" / developFileName
        freeDevFileName = "develop.json"
        pkg1DevFileContent = developFile(@[], @["../pkg2.2"])
        pkg2DevFileContent = developFile(@[&"../{freeDevFileName}"], @[])
        freeDevFileContent = developFile(@[], @["./pkg3.2"])

      cleanFiles pkg1DevFilePath, pkg2DevFilePath, freeDevFileName
      writeFile(pkg1DevFilePath, pkg1DevFileContent)
      writeFile(pkg2DevFilePath, pkg2DevFileContent)
      writeFile(freeDevFileName, freeDevFileContent)

      cd "pkg1":
        cleanFile "pkg1".addFileExt(ExeExt)
        let (output, exitCode) = execNimble("run", "-n")
        check exitCode == QuitFailure
        var lines = output.processOutput
        check lines.inLinesOrdered(
          pkgDepsAlreadySatisfiedMsg(("pkg2", anyVersion)))
        check lines.inLinesOrdered(pkgNotFoundMsg(("pkg3", anyVersion)))

  test "do not filter used included develop dependencies":
    # +--------------------------+                +--------------------------+
    # |           pkg1           |  +------------>+           pkg2           |
    # +--------------------------+  | dependency  +--------------------------+
    # | requires "pkg2", "pkg3"  |  |             | requires "pkg3"          |
    # +--------------------------+  |             +--------------------------+
    # |      nimble.develop      |--+             |      nimble.develop      |
    # +--------------------------+                +--------------------------+
    #                                                          |
    #                                                 includes |
    #                                                          v
    #                                                  +---------------+
    #                                                  | develop.json  |
    #                                                  +---------------+
    #                                                          |
    #                                               dependency |
    #                                                          v
    #                                                +---------------------+
    #                                                |        pkg3         |
    #                                                +---------------------+
    #                                                |  version = "0.2.0"  |
    #                                                +---------------------+

    # Here the build must pass because "pkg3" coming form develop file included
    # in "pkg2"'s develop file is a dependency of "pkg2" and it will be used,
    # in this way satisfying also "pkg1"'s requirements.

    cd "develop":
      const
        pkg1DevFilePath = "pkg1" / developFileName
        pkg2DevFilePath = "pkg2" / developFileName
        freeDevFileName = "develop.json"
        pkg1DevFileContent = developFile(@[], @["../pkg2"])
        pkg2DevFileContent = developFile(@[&"../{freeDevFileName}"], @[])
        freeDevFileContent = developFile(@[], @["./pkg3.2"])

      cleanFiles pkg1DevFilePath, pkg2DevFilePath, freeDevFileName
      writeFile(pkg1DevFilePath, pkg1DevFileContent)
      writeFile(pkg2DevFilePath, pkg2DevFileContent)
      writeFile(freeDevFileName, freeDevFileContent)

      cd "pkg1":
        cleanFile "pkg1".addFileExt(ExeExt)
        let (output, exitCode) = execNimble("run", "-n")
        check exitCode == QuitSuccess
        var lines = output.processOutput
        check lines.inLinesOrdered(
          pkgDepsAlreadySatisfiedMsg(("pkg2", anyVersion)))
        check lines.inLinesOrdered(
          pkgDepsAlreadySatisfiedMsg(("pkg3", anyVersion)))
        check lines.inLinesOrdered(
          pkgDepsAlreadySatisfiedMsg(("pkg3", anyVersion)))

  test "no version clash with filtered not used included develop dependencies":
    # +--------------------------+                +--------------------------+
    # |           pkg1           |  +------------>|           pkg2           |
    # +--------------------------+  | dependency  +--------------------------+
    # | requires "pkg2", "pkg3"  |  |             |      nimble.develop      |
    # +--------------------------+  |             +--------------------------+
    # |      nimble.develop      |--+                           |
    # +--------------------------+                     includes |
    #             |                                             v
    #    includes |                                     +---------------+
    #             v                                     | develop2.json |
    #     +---------------+                             +-------+-------+
    #     | develop1.json |                                     |
    #     +---------------+                          dependency |
    #             |                                             v
    #  dependency |                                  +---------------------+
    #             v                                  |        pkg3         |
    #   +-------------------+                        +---------------------+
    #   |       pkg3        |                        |  version = "0.2.0"  |
    #   +-------------------+                        +---------------------+
    #   | version = "0.1.0" |
    #   +-------------------+

    # Here the build must pass because only the version of "pkg3" included via
    # "develop1.json" must be taken into account, since "pkg2" does not depend
    # on "pkg3" and the version coming from "develop2.json" must be filtered.

    cd "develop":
      const
        pkg1DevFilePath = "pkg1" / developFileName
        pkg2DevFilePath = "pkg2.2" / developFileName
        freeDevFile1Name = "develop1.json"
        freeDevFile2Name = "develop2.json"
        pkg1DevFileContent = developFile(
          @[&"../{freeDevFile1Name}"], @["../pkg2.2"])
        pkg2DevFileContent = developFile(@[&"../{freeDevFile2Name}"], @[])
        freeDevFile1Content = developFile(@[], @["./pkg3"])
        freeDevFile2Content = developFile(@[], @["./pkg3.2"])

      cleanFiles pkg1DevFilePath, pkg2DevFilePath,
                 freeDevFile1Name, freeDevFile2Name
      writeFile(pkg1DevFilePath, pkg1DevFileContent)
      writeFile(pkg2DevFilePath, pkg2DevFileContent)
      writeFile(freeDevFile1Name, freeDevFile1Content)
      writeFile(freeDevFile2Name, freeDevFile2Content)

      cd "pkg1":
        cleanFile "pkg1".addFileExt(ExeExt)
        let (output, exitCode) = execNimble("run", "-n")
        check exitCode == QuitSuccess
        var lines = output.processOutput
        check lines.inLinesOrdered(
          pkgDepsAlreadySatisfiedMsg(("pkg2", anyVersion)))
        check lines.inLinesOrdered(
          pkgDepsAlreadySatisfiedMsg(("pkg3", anyVersion)))

  test "version clash with used included develop dependencies":
    # +--------------------------+                +--------------------------+
    # |           pkg1           |  +------------>|           pkg2           |
    # +--------------------------+  | dependency  +--------------------------+
    # | requires "pkg2", "pkg3"  |  |             | requires "pkg3"          |
    # +--------------------------+  |             +--------------------------+
    # |      nimble.develop      |--+             |      nimble.develop      |
    # +--------------------------+                +--------------------------+
    #             |                                             |
    #    includes |                                    includes |
    #             v                                             v
    #     +-------+-------+                             +---------------+
    #     | develop1.json |                             | develop2.json |
    #     +-------+-------+                             +---------------+
    #             |                                             |
    #  dependency |                                  dependency |
    #             v                                             v
    #   +-------------------+                        +---------------------+
    #   |       pkg3        |                        |         pkg3        |
    #   +-------------------+                        +---------------------+
    #   | version = "0.1.0" |                        |  version = "0.2.0"  |
    #   +-------------------+                        +---------------------+

    # Here the build must fail because since "pkg3" is dependency of both "pkg1"
    # and "pkg2", both versions coming from "develop1.json" and "develop2.json"
    # must be taken into account, but they are different."
    
    cd "develop":
      const
        pkg1DevFilePath = "pkg1" / developFileName
        pkg2DevFilePath = "pkg2" / developFileName
        freeDevFile1Name = "develop1.json"
        freeDevFile2Name = "develop2.json"
        pkg1DevFileContent = developFile(
          @[&"../{freeDevFile1Name}"], @["../pkg2"])
        pkg2DevFileContent = developFile(@[&"../{freeDevFile2Name}"], @[])
        freeDevFile1Content = developFile(@[], @["./pkg3"])
        freeDevFile2Content = developFile(@[], @["./pkg3.2"])

      cleanFiles pkg1DevFilePath, pkg2DevFilePath,
                 freeDevFile1Name, freeDevFile2Name
      writeFile(pkg1DevFilePath, pkg1DevFileContent)
      writeFile(pkg2DevFilePath, pkg2DevFileContent)
      writeFile(freeDevFile1Name, freeDevFile1Content)
      writeFile(freeDevFile2Name, freeDevFile2Content)

      cd "pkg1":
        cleanFile "pkg1".addFileExt(ExeExt)
        let (output, exitCode) = execNimble("run", "-n")
        check exitCode == QuitFailure
        var lines = output.processOutput
        check lines.inLinesOrdered(failedToLoadFileMsg(
          getCurrentDir() / developFileName))
        check lines.inLinesOrdered(pkgFoundMoreThanOnceMsg("pkg3",
          [("../pkg3".Path, (&"../{freeDevFile1Name}").Path),
           ("../pkg3.2".Path, (&"../{freeDevFile2Name}").Path)].toHashSet))

  test "create an empty develop file with default name in the current dir":
    cd dependentPkgPath:
      cleanFile developFileName
      let (output, errorCode) = execNimble("develop", "-c")
      check errorCode == QuitSuccess
      check parseFile(developFileName) == parseJson(emptyDevelopFileContent)
      check output.processOutput.inLines(
        emptyDevFileCreatedMsg(developFileName))

  test "create an empty develop file in some dir":
    cleanDir installDir
    let filePath = installDir / "develop.json"
    cleanFile filePath
    createDir installDir
    let (output, errorCode) = execNimble("develop", &"-c:{filePath}")
    check errorCode == QuitSuccess
    check parseFile(filePath) == parseJson(emptyDevelopFileContent)
    check output.processOutput.inLines(emptyDevFileCreatedMsg(filePath))

  test "try to create an empty develop file with already existing name":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      let
        filePath = getCurrentDir() / developFileName
        (output, errorCode) = execNimble("develop", &"-c:{filePath}")
      check errorCode == QuitFailure
      check output.processOutput.inLines(fileAlreadyExistsMsg(filePath))
      check parseFile(developFileName) == parseJson(developFileContent)

  test "try to create an empty develop file in not existing dir":
    let filePath = installDir / "some/not/existing/dir/develop.json"
    cleanFile filePath
    let (output, errorCode) = execNimble("develop", &"-c:{filePath}")
    check errorCode == QuitFailure
    check output.processOutput.inLines(&"cannot open: {filePath}")

  test "partial success when some operations in single command failed":
    cleanDir installDir
    cd dependentPkgPath:
      usePackageListFile &"../{pkgListFileName}":
        const
          dep2DevelopFilePath = dep2Path / developFileName
          includeFileContent = developFile(@[], @[dep2Path])
          invalidInclFilePath = "/some/not/existing/file/path".normalizedPath

        cleanFiles developFileName, includeFileName, dep2DevelopFilePath
        writeFile(includeFileName, includeFileContent)

        let
          developFilePath = getCurrentDir() / developFileName
          (output, errorCode) = execNimble("develop", &"-p:{installDir}",
            pkgAName,                    # fail because not a direct dependency
             "-c",                       # success
            &"-a:{depPath}",             # success
            &"-a:{dep2Path}",            # fail because of names collision
            &"-i:{includeFileName}",     # fail because of names collision
            &"-n:{depName}",             # success
            &"-c:{developFilePath}",     # fail because the file already exists
            &"-a:{dep2Path}",            # success
            &"-i:{includeFileName}",     # success
            &"-i:{invalidInclFilePath}", # fail
            &"-c:{dep2DevelopFilePath}") # success

        check errorCode == QuitFailure
        var lines = output.processOutput
        check lines.inLinesOrdered(pkgSetupInDevModeMsg(
          pkgAName, installDir / pkgAName))
        check lines.inLinesOrdered(emptyDevFileCreatedMsg(developFileName))
        check lines.inLinesOrdered(
          pkgAddedInDevModeMsg(depNameAndVersion, depPath))
        check lines.inLinesOrdered(
          pkgAlreadyPresentAtDifferentPathMsg(depName, depPath))
        check lines.inLinesOrdered(
          failedToInclInDevFileMsg(includeFileName, developFilePath))
        check lines.inLinesOrdered(pkgFoundMoreThanOnceMsg(depName,
          [(depPath.Path, developFilePath.Path),
           (dep2Path.Path, includeFileName.Path)].toHashSet))
        check lines.inLinesOrdered(
          pkgRemovedFromDevModeMsg(depNameAndVersion, depPath))
        check lines.inLinesOrdered(fileAlreadyExistsMsg(developFilePath))
        check lines.inLinesOrdered(
          pkgAddedInDevModeMsg(depNameAndVersion, dep2Path))
        check lines.inLinesOrdered(inclInDevFileMsg(includeFileName))
        check lines.inLinesOrdered(failedToLoadFileMsg(invalidInclFilePath))
        check lines.inLinesOrdered(emptyDevFileCreatedMsg(dep2DevelopFilePath))
        check parseFile(dep2DevelopFilePath) ==
              parseJson(emptyDevelopFileContent)
        check lines.inLinesOrdered(notADependencyErrorMsg(
          &"{pkgAName}@0.6.0", dependentPkgNameAndVersion))
        const expectedDevelopFileContent = developFile(
          @[includeFileName], @[dep2Path])
        check parseFile(developFileName) ==
              parseJson(expectedDevelopFileContent)

suite "path command":
  test "can get correct path for srcDir (#531)":
    cd "develop/srcdirtest":
      let (_, exitCode) = execNimbleYes("install")
      check exitCode == QuitSuccess
    let (output, _) = execNimble("path", "srcdirtest")
    let packageDir = getPackageDir(pkgsDir, "srcdirtest-1.0")
    check output.strip() == packageDir

  # test "nimble path points to develop":
  #   cd "develop/srcdirtest":
  #     var (output, exitCode) = execNimble("develop")
  #     checkpoint output
  #     check exitCode == QuitSuccess

  #     (output, exitCode) = execNimble("path", "srcdirtest")

  #     checkpoint output
  #     check exitCode == QuitSuccess
  #     check output.strip() == getCurrentDir() / "src"

suite "test command":
  beforeSuite()

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
  beforeSuite()

  test "can succeed package":
    cd "binaryPackage/v1":
      let (outp, exitCode) = execNimble("check")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("success")
      check outp.processOutput.inLines("\"binaryPackage\" is valid")

    cd "packageStructure/a":
      let (outp, exitCode) = execNimble("check")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("success")
      check outp.processOutput.inLines("\"a\" is valid")

    cd "packageStructure/b":
      let (outp, exitCode) = execNimble("check")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("success")
      check outp.processOutput.inLines("\"b\" is valid")

    cd "packageStructure/c":
      let (outp, exitCode) = execNimble("check")
      check exitCode == QuitSuccess
      check outp.processOutput.inLines("success")
      check outp.processOutput.inLines("\"c\" is valid")

  test "can fail package":
    cd "packageStructure/x":
      let (outp, exitCode) = execNimble("check")
      check exitCode == QuitFailure
      check outp.processOutput.inLines("failure")
      check outp.processOutput.inLines("validation failed")
      check outp.processOutput.inLines("package 'x' has an incorrect structure")

suite "multi":
  beforeSuite()

  test "can install package from git subdir":
    var
      args = @["install", pkgMultiAlphaUrl]
      (output, exitCode) = execNimbleYes(args)
    check exitCode == QuitSuccess

    # Issue 785
    args.add @[pkgMultiBetaUrl, "-n"]
    (output, exitCode) = execNimble(args)
    check exitCode == QuitSuccess
    check output.contains("forced no")
    check output.contains("beta installed successfully")

  test "can develop package from git subdir":
    cleanDir "beta"
    check execNimbleYes("develop", pkgMultiBetaUrl).exitCode == QuitSuccess

suite "Module tests":
  template moduleTest(moduleName: string) =
    test moduleName:
      cd "..":
        check execCmdEx("nim c -r src/nimblepkg/" & moduleName).
          exitCode == QuitSuccess

  moduleTest "aliasthis"
  moduleTest "common"
  moduleTest "counttables"
  moduleTest "download"
  moduleTest "jsonhelpers"
  moduleTest "packageinfo"
  moduleTest "packageparser"
  moduleTest "reversedeps"
  moduleTest "topologicalsort"
  moduleTest "version"

suite "nimble run":
  beforeSuite()

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

  test "Nimble options before executable name":
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
      check output.contains("""Testing `nimble run`: @["--test"]""")

  test "Nimble options before --":
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
      check output.contains("""Testing `nimble run`: @["--test"]""")

  test "Compilation flags before run command":
    cd "run":
      let (output, exitCode) = execNimble(
        "-d:sayWhee", # Compile flag to define a conditional symbol
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
      check output.contains("""Whee!""")

  test "Compilation flags before executable name":
    cd "run":
      let (output, exitCode) = execNimble(
        "--debug", # Flag to enable debug verbosity in Nimble
        "run", # Run command invokation
        "-d:sayWhee", # Compile flag to define a conditional symbol
        "run", # The executable to run
        "--test" # First argument passed to the executed command
      )
      check exitCode == QuitSuccess
      check output.contains("tests$1run$1$2 --test" %
                            [$DirSep, "run".changeFileExt(ExeExt)])
      echo output
      check output.contains("""Testing `nimble run`: @["--test"]""")
      check output.contains("""Whee!""")

  test "Compilation flags before --":
    cd "run":
      let (output, exitCode) = execNimble(
        "run", # Run command invokation
        "-d:sayWhee", # Compile flag to define a conditional symbol
        "--debug", # Flag to enable debug verbosity in Nimble
        "--", # Separator for arguments
        "--test" # First argument passed to the executed command
      )
      check exitCode == QuitSuccess
      check output.contains("tests$1run$1$2 --test" %
                            [$DirSep, "run".changeFileExt(ExeExt)])
      echo output
      check output.contains("""Testing `nimble run`: @["--test"]""")
      check output.contains("""Whee!""")

  test "Order of compilation flags before and after run command":
    cd "run":
      let (output, exitCode) = execNimble(
        "-d:compileFlagBeforeRunCommand", # Compile flag to define a conditional symbol
        "run", # Run command invokation
        "-d:sayWhee", # Compile flag to define a conditional symbol
        "--debug", # Flag to enable debug verbosity in Nimble
        "--", # Separator for arguments
        "--test" # First argument passed to the executed command
      )
      check exitCode == QuitSuccess
      check output.contains("-d:compileFlagBeforeRunCommand -d:sayWhee")
      check output.contains("tests$1run$1$2 --test" %
                            [$DirSep, "run".changeFileExt(ExeExt)])
      echo output
      check output.contains("""Testing `nimble run`: @["--test"]""")
      check output.contains("""Whee!""")

suite "project local deps mode":
  beforeSuite()

  test "nimbledeps exists":
    cd "localdeps":
      cleanDir("nimbledeps")
      createDir("nimbledeps")
      let (output, exitCode) = execCmdEx(nimblePath & " install -y")
      check exitCode == QuitSuccess
      check output.contains("project local deps mode")
      check output.contains("Succeeded")

  test "--localdeps flag":
    cd "localdeps":
      cleanDir("nimbledeps")
      let (output, exitCode) = execCmdEx(nimblePath & " install -y -l")
      check exitCode == QuitSuccess
      check output.contains("project local deps mode")
      check output.contains("Succeeded")

  test "localdeps develop":
    cleanDir("packagea")
    let (_, exitCode) = execCmdEx(nimblePath &
      &" develop {pkgAUrl} --localdeps -y")
    check exitCode == QuitSuccess
    check dirExists("packagea" / "nimbledeps")
    check not dirExists("nimbledeps")

suite "misc tests":
  beforeSuite()

  test "depsOnly + flag order test":
    let (output, exitCode) = execNimbleYes("--depsOnly", "install", pkgBin2Url)
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
    removeDir installDir
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
        &"nim c -o:{buildDir/fileName.splitFile.name} {fileName}")

    proc checkOutput(output: string): uint =
      const warningsToCheck = [
        "[UnusedImport]",
        "[Deprecated]",
        "[XDeclaredButNotUsed]",
        "[Spacing]",
        "[ConvFromXtoItselfNotNeeded]",
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
  beforeSuite()

  test "issue 801":
    cd "issue801":
      let (output, exitCode) = execNimbleYes("--debug", "test")
      check exitCode == QuitSuccess

      # Verify hooks work
      check output.contains("before test")
      check output.contains("after test")

  test "issue 799":
    # When building, any newly installed packages should be referenced via the
    # path that they get permanently installed at.
    cleanDir installDir
    cd "issue799":
      let (output, exitCode) = execNimbleYes("build")
      check exitCode == QuitSuccess
      var lines = output.processOutput
      lines.keepItIf(unindent(it).startsWith("Executing"))

      for line in lines:
        if line.contains("issue799"):
          let nimbleInstallDir = getPackageDir(
            pkgsDir, &"nimble-{nimbleVersion}")
          dump(nimbleInstallDir)
          let pkgInstalledPath = "--path:'" & nimble_install_dir & "'"
          dump(pkgInstalledPath)
          check line.contains(pkgInstalledPath)

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
      var (output, exitCode) = execNimbleYes("--debug", "c", "src/abc")
      check exitCode == QuitSuccess
      check fileExists(buildTests / "abc".addFileExt(ExeExt))
      check not fileExists("src/def".addFileExt(ExeExt))
      check not fileExists(buildTests / "def".addFileExt(ExeExt))

      (output, exitCode) = execNimbleYes("--debug", "uninstall", "-i", "timezones")
      check exitCode == QuitSuccess

      (output, exitCode) = execNimbleYes("--debug", "run", "def")
      check exitCode == QuitSuccess
      check output.contains("def727")
      check not fileExists("abc".addFileExt(ExeExt))
      check fileExists("def".addFileExt(ExeExt))

      (output, exitCode) = execNimbleYes("--debug", "uninstall", "-i", "timezones")
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
      check output.contains getPackageDir(pkgsDir, "binname-0.1.0") /
                            "binname".addFileExt(ext)
      check output.contains getPackageDir(pkgsDir, "binname-0.1.0") /
                            "binname-2"

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
      check output.contains getPackageDir(pkgsDir, "binname-0.2.0") /
                            "binname".addFileExt(ext)
      check output.contains getPackageDir(pkgsDir, "binname-0.2.0") /
                            "binname-2"

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
      let (_, exitCode) = execCmdEx(
        nimblePath & " -y --nimbleDir=./nimbleDir install")
      check exitCode == QuitSuccess
      let dummyPkgDir = getPackageDir(
        "nimbleDir" / nimblePackagesDirName, "dummy-0.1.0")
      check dummyPkgDir.dirExists
      check not (dummyPkgDir / "nimbleDir").dirExists

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
    cleanDir(installDir)
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
    cleanDir(installDir)
    let arguments = @["install", &"{pkgAUrl}@#1f9cb289c89"]
    check execNimbleYes(arguments).exitCode == QuitSuccess
    # Verify that it was installed correctly.
    check packageDirExists(pkgsDir, "PackageA-0.6.0")
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
    cleanDir(installDir)

    cd "issue113/c":
      check execNimbleYes("install").exitCode == QuitSuccess
    cd "issue113/b":
      check execNimbleYes("install").exitCode == QuitSuccess
    cd "issue113/a":
      check execNimbleYes("install").exitCode == QuitSuccess

    # Try to remove c.
    let
      (output, exitCode) = execNimbleYes(["remove", "c"])
      lines = output.strip.processOutput()
      pkgBInstallDir = getPackageDir(pkgsDir, "b-0.1.0").splitPath.tail

    check exitCode != QuitSuccess
    check lines.inLines(cannotUninstallPkgMsg("c", "0.1.0", @[pkgBInstallDir]))

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

suite "nimble tasks":
  beforeSuite()

  test "can list tasks even with no tasks defined in nimble file":
    cd "tasks/empty":
      let (_, exitCode) = execNimble("tasks")
      check exitCode == QuitSuccess

  test "tasks with no descriptions are correctly displayed":
    cd "tasks/nodesc":
      let (output, exitCode) = execNimble("tasks")
      check output.contains("nodesc")
      check exitCode == QuitSuccess

  test "task descriptions are correctly aligned to longer name":
    cd "tasks/max":
      let (output, exitCode) = execNimble("tasks")
      check output.contains("task1           Description1")
      check output.contains("very_long_task  This is a task with a long name")
      check output.contains("aaa             A task with a small name")
      check exitCode == QuitSuccess

  test "task descriptions are correctly aligned to minimum (10 chars)":
    cd "tasks/min":
      let (output, exitCode) = execNimble("tasks")
      check output.contains("a         Description for a")
      check exitCode == QuitSuccess
