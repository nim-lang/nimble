# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, osproc, strutils, strformat, json, sets
import testscommon, nimblepkg/displaymessages, nimblepkg/paths

from nimblepkg/common import cd
from nimblepkg/packageinfo import lockFileHasNim
from nimblepkg/options import initOptions
from nimblepkg/developfile import developFileName, pkgFoundMoreThanOnceMsg
from nimblepkg/version import newVersion, parseVersionRange
from nimblepkg/nimbledatafile import nimbleDataFileName, NimbleDataJsonKeys

suite "develop feature":
  const
    pkgListFileName = "packages.json"
    dependentPkgName = "dependent"
    dependentPkgPath = "develop/dependent".normalizedPath
    includeFileName = "included.develop"
    pkgAName = "PackageA"
    pkgBName = "PackageB"
    pkgSrcDirTestName = "srcdirtest"
    pkgHybridName = "hybrid"
    depPath = "../dependency".normalizedPath
    depName = "dependency"
    depVersion = "0.1.0"
    depNameAndVersion = &"{depName}@{depVersion}"
    dep2Path = "../dependency2".normalizedPath
    emptyDevelopFileContent = developFile(@[], @[])
    defaultPath = "vendor"
  
  let anyVersion = parseVersionRange("")
  # Absolute path to the develop package list fixture. Tests below `cd` into
  # installDir (outside the repo), so the old cwd-relative `../develop/...`
  # spelling no longer resolves to tests/develop/. Anchor it absolutely.
  let developPkgList = testsDir / "develop" / pkgListFileName

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
      # No host project + single package: PackageA is cloned as the root (./PackageA).
      check dirExists(installDir / pkgAName.toLowerAscii)
      check output.processOutput.inLines(
        pkgSetupInDevModeMsg(pkgAName, installDir / pkgAName.toLowerAscii))

  test "can develop from package name":
    cdCleanDir installDir:
      usePackageListFile developPkgList:
        let (output, exitCode) = execNimble("develop", pkgBName)
        check exitCode == QuitSuccess
        # Single pkg, no host: PackageB is the root; bare (no --with-dependencies)
        # so its dep PackageA is installed normally, NOT vendored under PackageB/.
        check dirExists(installDir / pkgBName.toLowerAscii)
        check not dirExists(
          installDir / pkgBName.toLowerAscii / defaultPath / pkgAName.toLowerAscii)
        check output.processOutput.inLines(
          pkgSetupInDevModeMsg(pkgBName, installDir / pkgBName.toLowerAscii))

  test "develop multiple pkgs outside a project records a free develop file":
    cdCleanDir installDir:
      usePackageListFile developPkgList:
        # Multiple packages with no host project fall back to a parent free
        # develop file — there's no single root to attach them to.
        let (_, exitCode) = execNimble("develop", pkgAName, pkgBName)
        check exitCode == QuitSuccess
        check fileExists(developFileName)
        let dev = readFile(developFileName).toLowerAscii
        check pkgAName.toLowerAscii in dev
        check pkgBName.toLowerAscii in dev

  test "explicit --developFile wins over the default free develop file":
    cdCleanDir installDir:
      usePackageListFile developPkgList:
        let (_, exitCode) = execNimble(
          "develop", pkgBName, "--developFile:custom.develop")
        check exitCode == QuitSuccess
        check fileExists("custom.develop")
        check not fileExists(developFileName)

  test "develop <pkg> --with-dependencies (no host) makes the pkg the root":
    # `nimble develop PackageB --with-dependencies` in a dir with no host project
    # is equivalent to `git clone PackageB && cd PackageB && nimble develop
    # --with-dependencies`: PackageB is cloned as the root (./PackageB, not under
    # vendor/) and its dependency PackageA is vendored under PackageB/vendor/.
    cdCleanDir installDir:
      usePackageListFile developPkgList:
        let (_, exitCode) = execNimble(
          "develop", "--with-dependencies", pkgBName)
        check exitCode == QuitSuccess
        let pkgBRoot = installDir / pkgBName.toLowerAscii
        # PackageB is the root (./PackageB), NOT vendored under ./vendor/
        check dirExists(pkgBRoot)
        check not dirExists(installDir / defaultPath / pkgBName.toLowerAscii)
        # its dependency PackageA is vendored under PackageB/vendor/
        check dirExists(pkgBRoot / defaultPath / pkgAName.toLowerAscii)
        # paths file is generated inside the root package
        check fileExists(pkgBRoot / "nimble.paths")

  test "develop --with-dependencies does not vendor nim without a nim lock entry":
    # nim (the compiler) is vendored only when the project's nimble.lock pins it.
    # PackageB has no lock file, so nim must not be cloned into vendor/.
    cdCleanDir installDir:
      usePackageListFile developPkgList:
        let (_, exitCode) = execNimble(
          "develop", "--with-dependencies", pkgBName)
        check exitCode == QuitSuccess
        let vendorDir = installDir / pkgBName.toLowerAscii / defaultPath
        check dirExists(vendorDir)          # its library dep IS vendored
        check not dirExists(vendorDir / "nim")

  test "develop --with-dependencies --useSystemNim does not vendor nim":
    # --useSystemNim must never vendor nim, even if a lock pinned it: the system
    # nim may be a binary-only install with no sources to develop against.
    cdCleanDir installDir:
      usePackageListFile developPkgList:
        let (_, exitCode) = execNimble(
          "--useSystemNim", "develop", "--with-dependencies", pkgBName)
        check exitCode == QuitSuccess
        let vendorDir = installDir / pkgBName.toLowerAscii / defaultPath
        check not dirExists(vendorDir / "nim")

  test "lockFileHasNim gates nim vendoring (positive case, no clone)":
    # Unit-level check of the predicate that decides nim vendoring, without the
    # cost of actually cloning Nim: a lock that pins nim -> true; a lock without
    # nim, or a missing lock -> false.
    let opts = initOptions()
    let tmp = getTempDir() / "tdevelop_lockhasnim"
    createDir tmp
    defer: removeDir tmp

    let lockWithNim = tmp / "with_nim.lock"
    writeFile(lockWithNim, """{
  "version": 1,
  "packages": {
    "nim": {
      "version": "2.0.8",
      "vcsRevision": "28021a6356119aad32a00815e1dc63b934c5cb40",
      "url": "https://github.com/nim-lang/Nim.git",
      "downloadMethod": "git",
      "dependencies": [],
      "checksums": { "sha1": "83c1d893cb997417565b7208e3cbebb8f93222cb" }
    }
  },
  "tasks": {}
}""")
    check lockFileHasNim(lockWithNim, opts)

    let lockNoNim = tmp / "no_nim.lock"
    writeFile(lockNoNim, """{
  "version": 1,
  "packages": {
    "results": {
      "version": "0.5.1",
      "vcsRevision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "url": "https://github.com/arnetheduck/nim-results",
      "downloadMethod": "git",
      "dependencies": [],
      "checksums": { "sha1": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
    }
  },
  "tasks": {}
}""")
    check not lockFileHasNim(lockNoNim, opts)
    check not lockFileHasNim(tmp / "missing.lock", opts)

  test "develop inside a vendored package clones deps flat (no nesting)":
    cdCleanDir installDir:
      usePackageListFile developPkgList:
        # Host project so `develop packageb` records packageb in the project's
        # nimble.develop (does not rely on the no-host free-develop-file feature).
        writeFile("host.nimble", """
version = "0.1.0"
author = "Test"
description = "host"
license = "MIT"
requires "nim"
""")
        let (_, e1) = execNimble("develop", pkgBName)
        check e1 == QuitSuccess
        check fileExists(developFileName)
        var pkgBDir = ""
        for kind, d in walkDir(installDir / defaultPath):
          if kind == pcDir and d.splitPath.tail.toLowerAscii.contains("packageb"):
            pkgBDir = d
        check pkgBDir.len > 0
        cd pkgBDir:
          let (_, e2) = execNimble("develop", "--with-dependencies")
          check e2 == QuitSuccess
        var packageaFlat = false
        var anyNested = false
        for kind, d in walkDir(installDir / defaultPath):
          if kind != pcDir: continue
          if d.splitPath.tail.toLowerAscii.contains("packagea"):
            packageaFlat = true
          if dirExists(d / defaultPath):
            anyNested = true
        check packageaFlat
        check not anyNested

  test "develop inside a vendored package respects an explicit --path":
    cdCleanDir installDir:
      usePackageListFile developPkgList:
        writeFile("host.nimble", """
version = "0.1.0"
author = "Test"
description = "host"
license = "MIT"
requires "nim"
""")
        let (_, e1) = execNimble("develop", pkgBName)
        check e1 == QuitSuccess
        var pkgBDir = ""
        for kind, d in walkDir(installDir / defaultPath):
          if kind == pcDir and d.splitPath.tail.toLowerAscii.contains("packageb"):
            pkgBDir = d
        check pkgBDir.len > 0
        cd pkgBDir:
          let (_, e2) = execNimble("develop", "--with-dependencies", "--path:mydeps")
          check e2 == QuitSuccess
          check dirExists("mydeps")
        var packageaFlat = false
        for kind, d in walkDir(installDir / defaultPath):
          if kind == pcDir and d.splitPath.tail.toLowerAscii.contains("packagea"):
            packageaFlat = true
        check not packageaFlat

  test "develop with dependencies generates nimble.paths with vendor paths":
    cdCleanDir installDir:
      usePackageListFile developPkgList:
        # Create a project that requires packagea (available in the test package list)
        writeFile("testproject.nimble", &"""
version = "0.1.0"
author = "Test"
description = "Test"
license = "MIT"
requires "nim >= 1.6.0", "packagea"
""")
        # develop --withDependencies from a project dir clones deps into vendor/
        # and should generate nimble.paths with vendor paths
        let (_, exitCode) = execNimble(
          "develop", "--with-dependencies")
        check exitCode == QuitSuccess
        # Check nimble.paths was generated with vendor paths
        check fileExists("nimble.paths")
        let pathsContent = readFile("nimble.paths")
        check pathsContent.contains(defaultPath)
        check pathsContent.toLowerAscii.contains("packagea")
        # Ensure paths point to vendor directory, not to pkgs2
        check not pathsContent.contains("pkgs2")

  test "develop --withDeps vendors all deps even when some are in pkgs2":
    cleanDir installDir
    # Step 1: Pre-install packagea into pkgs2/ so it's "cached"
    usePackageListFile &"develop/{pkgListFileName}":
      let (_, installExitCode) = execNimbleYes("install", pkgAUrl)
      check installExitCode == QuitSuccess
      check getPackageDir(pkgsDir, "packagea-").len > 0 or
            getPackageDir(pkgsDir, "PackageA-").len > 0
    # Step 2: Create a project that requires packagea and run develop --withDeps
    cdCleanDir installDir / "testproject":
      usePackageListFile developPkgList:
        writeFile("testproject.nimble", """
version = "0.1.0"
author = "Test"
description = "Test"
license = "MIT"
requires "nim >= 1.6.0", "packagea"
""")
        let (_, exitCode) = execNimble(
          "develop", "--with-dependencies")
        check exitCode == QuitSuccess
        # packagea should be cloned into vendor/
        let vendorPkgADir = getCurrentDir() / defaultPath / "packagea"
        check dirExists(vendorPkgADir)
        # nimble.paths should reference vendor, not pkgs2
        check fileExists("nimble.paths")
        let pathsContent = readFile("nimble.paths")
        check pathsContent.toLowerAscii.contains("packagea")
        check pathsContent.contains(defaultPath)
        check not pathsContent.contains("pkgs2")

  test "develop prefers vendor over cached versions (hasVersion shadowing bug)":
    cdCleanDir installDir:
      usePackageListFile developPkgList:
        # Seed tagged_versions.json cache with packagea
        let pkgCacheDir = installDir / "pkgcache"
        createDir(pkgCacheDir)
        let taggedVersionsFile = pkgCacheDir / "tagged_versions.json"
        cleanFile taggedVersionsFile
        writeFile(taggedVersionsFile, $(%*{
          "packagea": [
            {"name": "PackageA",
             "version": {"version": "0.2.0", "speSemanticVersion": nil},
             "requires": ["nim >= 0.11.0"],
             "isRoot": false,
             "url": "https://github.com/jmgomez/packagea.git"}
          ]
        }))
        writeFile("testproject.nimble", &"""
version = "0.1.0"
author = "Test"
description = "Test"
license = "MIT"
requires "nim >= 1.6.0", "packagea"
""")
        let (_, devExitCode) = execNimble(
          "develop", "--with-dependencies")
        check devExitCode == QuitSuccess
        check fileExists("nimble.paths")
        let pathsContent = readFile("nimble.paths")
        check pathsContent.toLowerAscii.contains("packagea")
        check pathsContent.contains(defaultPath)
        check not pathsContent.contains("pkgs2")

  test "bare 'nimble develop' installs deps without vendoring (#1510)":
    # Only `--with-dependencies` creates a vendor/. Bare `nimble develop` in a
    # project installs its dependencies through the regular (non-develop) route
    # and generates nimble.paths pointing at pkgs2 — no vendor/ is created.
    # `-l` forces local mode (test infra otherwise injects --global).
    cdCleanDir installDir:
      usePackageListFile developPkgList:
        writeFile("testproject.nimble", &"""
version = "0.1.0"
author = "Test"
description = "Test"
license = "MIT"
requires "nim >= 1.6.0", "packagea"
""")
        let (_, exitCode) = execNimble("develop", "-l")
        check exitCode == QuitSuccess
        # bare ⇒ no vendor/ is created
        check not dirExists(getCurrentDir() / defaultPath / "packagea")
        check fileExists("nimble.paths")
        let pathsContent = readFile("nimble.paths")
        check pathsContent.toLowerAscii.contains("packagea")
        # deps come from the regular install location, not a vendor
        check pathsContent.contains("pkgs2")

  test "nimble path respects develop file (#1344)":
    # `nimble path <pkg>` only consulted installed packages in pkgs2/,
    # ignoring the develop file. After `develop --with-dependencies`, asking
    # for the path of a vendored dep should return the vendor path, not a
    # cached pkgs2/ copy (and must succeed even if pkgs2/ has no entry).
    cdCleanDir installDir:
      usePackageListFile developPkgList:
        writeFile("testproject.nimble", &"""
version = "0.1.0"
author = "Test"
description = "Test"
license = "MIT"
requires "nim >= 1.6.0", "packagea"
""")
        let (_, devExit) = execNimble("develop", "-l", "--with-dependencies")
        check devExit == QuitSuccess
        let vendorPkgA = getCurrentDir() / defaultPath / "packagea"
        check dirExists(vendorPkgA)

        let (pathOut, pathExit) = execNimble("path", "-l", "packagea")
        check pathExit == QuitSuccess
        check pathOut.contains(defaultPath)
        check not pathOut.contains("pkgs2")

  test "develop --withDeps vendors under canonical name not git repo name (#1508)":
    let repoDir = getTempDir() / "nim-funkylib-repo"
    let pkgListFile = getTempDir() / "t1508_packages.json"
    cleanDir repoDir
    createDir repoDir
    writeFile(repoDir / "funkylib.nimble", """
version = "0.1.0"
author = "Test"
description = "Test"
license = "MIT"
""")
    cd repoDir:
      check execCmdEx("git init -q").exitCode == 0
      check execCmdEx("git config user.name t").exitCode == 0
      check execCmdEx("git config user.email t@t").exitCode == 0
      check execCmdEx("git add .").exitCode == 0
      check execCmdEx("git commit -q -m initial").exitCode == 0
      check execCmdEx("git tag v0.1.0").exitCode == 0
    let pkgList = %* [{
      "name": "funkylib",
      "url": "file://" & repoDir,
      "method": "git",
      "tags": ["test"],
      "description": "Test",
      "license": "MIT"
    }]
    writeFile(pkgListFile, $pkgList)
    defer:
      removeDir repoDir
      removeFile pkgListFile
    cdCleanDir installDir:
      usePackageListFile pkgListFile:
        writeFile("testproject.nimble", """
version = "0.1.0"
author = "Test"
description = "Test"
license = "MIT"
requires "nim >= 1.6.0", "funkylib"
""")
        let (_, exitCode) = execNimble("develop", "-l", "--with-dependencies")
        check exitCode == QuitSuccess
        # Vendor dir must use canonical name "funkylib", not URL tail "nim-funkylib-repo".
        check dirExists(getCurrentDir() / defaultPath / "funkylib")
        check not dirExists(getCurrentDir() / defaultPath / "nim-funkylib-repo")

  test "nimble setup after develop --withDeps reuses vendor packages (#1566)":
    # After `nimble develop --with-dependencies` clones deps into vendor/ and
    # writes nimble.develop, a follow-up `nimble setup` should NOT re-download
    # the same packages from git. Vendor copies must be reused.
    let topRepo = getTempDir() / "t1566-t1566lib-repo"
    let depRepo = getTempDir() / "t1566-t1566dep-repo"
    let pkgListFile = getTempDir() / "t1566_packages.json"
    removeDir topRepo
    removeDir depRepo
    createDir topRepo
    createDir depRepo
    writeFile(depRepo / "t1566dep.nimble", """
version = "0.1.0"
author = "Test"
description = "Test"
license = "MIT"
""")
    writeFile(topRepo / "t1566lib.nimble", """
version = "0.1.0"
author = "Test"
description = "Test"
license = "MIT"
requires "nim >= 1.6.0", "t1566dep"
""")
    proc initRepo(d: string) =
      cd d:
        check execCmdEx("git init -q").exitCode == 0
        check execCmdEx("git config user.name t").exitCode == 0
        check execCmdEx("git config user.email t@t").exitCode == 0
        check execCmdEx("git add .").exitCode == 0
        check execCmdEx("git commit -q -m initial").exitCode == 0
        check execCmdEx("git tag v0.1.0").exitCode == 0
    initRepo(depRepo)
    initRepo(topRepo)
    # Build a Windows-safe file URL. On Windows the path has a drive
    # letter; the double-slash form (file://C:/...) breaks because
    # parseUri treats `C` as the host and re-serializes without the
    # colon — git then sees `file://C/...` and fails. The triple-slash
    # form (file:///C:/...) parses with empty host + full path and
    # round-trips intact. On unix the double-slash form is correct.
    proc toFileUrl(p: string): string =
      when defined(windows): "file:///" & p.replace('\\', '/')
      else: "file://" & p
    let topUrl = toFileUrl(topRepo)
    let depUrl = toFileUrl(depRepo)
    let pkgList = %* [
      {"name": "t1566lib", "url": topUrl, "method": "git",
       "tags": ["test"], "description": "Test", "license": "MIT"},
      {"name": "t1566dep", "url": depUrl, "method": "git",
       "tags": ["test"], "description": "Test", "license": "MIT"}
    ]
    writeFile(pkgListFile, $pkgList)
    defer:
      removeDir topRepo
      removeDir depRepo
      removeFile pkgListFile
    cdCleanDir installDir:
      usePackageListFile pkgListFile:
        # Pre-install t1566dep into pkgs2/ to mimic "this dep was already
        # cached from prior work" — closer to arnetheduck's nora-poc state,
        # where some deps are already installed before `develop --withDeps`
        # runs. If develop short-circuits transitive discovery for already-
        # installed deps, t1566dep would still end up missing from vendor/.
        let (_, instExit) = execNimbleYes("install", "t1566dep")
        check instExit == QuitSuccess
        writeFile("testproject.nimble", """
version = "0.1.0"
author = "Test"
description = "Test"
license = "MIT"
requires "nim >= 1.6.0", "t1566lib"
""")
        let (_, devExit) = execNimble("develop", "-l", "--with-dependencies")
        check devExit == QuitSuccess
        check dirExists(getCurrentDir() / defaultPath / "t1566lib")
        check dirExists(getCurrentDir() / defaultPath / "t1566dep")
        # Now run setup: it must NOT re-download t1566lib or t1566dep.
        let (setupOut, setupExit) = execNimble("setup", "-l")
        check setupExit == QuitSuccess
        check not setupOut.contains("Downloading file://")
        check dirExists(getCurrentDir() / defaultPath / "t1566lib")
        check dirExists(getCurrentDir() / defaultPath / "t1566dep")

  test "develop overrides == pinned dependency (#1000)":
    let depDir = getTempDir() / "nimble_t1000_depa"
    cleanDir depDir
    createDir depDir
    writeFile(depDir / "depa.nimble", """
version = "0.5.0"
author = "Test"
description = "Test"
license = "MIT"
""")
    cdCleanDir installDir:
      writeFile("testproject.nimble", """
version = "0.1.0"
author = "Test"
description = "Test"
license = "MIT"
requires "nim >= 1.6.0", "depa == 0.1.0"
""")
      let (addOut, addExit) = execNimble("develop", "-l", "--add:" & depDir)
      check addExit == QuitSuccess
      check not addOut.contains("are not in the required")
      check fileExists("nimble.develop")
      # A follow-up command that re-validates develop deps must also pass.
      let (checkOut, checkExit) = execNimble("check", "-l")
      check checkExit == QuitSuccess
      check not checkOut.contains("are not in the required")

  test "develop --withDeps handles URL deps with branch refs (#1567)":
    # Regression for nim-lang/nimble#1567 / develop_issues.md #2:
    # When the root requires a URL dep with a branch ref (`.git#branch`), the
    # SAT solver resolves it to a special version (e.g. `#head`). Previously,
    # developFromSolution built a PkgTuple via `parseVersionRange("== " & $ver)`
    # which produced the invalid string `== #head` and crashed with
    # "Unexpected char in version range '== #head': #".
    cdCleanDir installDir:
      usePackageListFile developPkgList:
        writeFile("testproject.nimble", &"""
version = "0.1.0"
author = "Test"
description = "Test"
license = "MIT"
requires "nim >= 1.6.0", "https://github.com/jmgomez/packagea.git#head"
""")
        let (output, exitCode) = execNimble("develop", "-l", "--with-dependencies")
        check exitCode == QuitSuccess
        check not output.contains("Unexpected char in version range")
        check dirExists(getCurrentDir() / defaultPath / "packagea")
        check fileExists("nimble.develop")

  test "develop works in a directory not under version control (#1509)":
    # Regression for nim-lang/nimble#1509 / develop_issues.md #5:
    # Running `nimble develop --add:<pkg>` in a non-VCS directory failed with
    # "Sync file require current working directory to be under some supported
    # type of version control." The sync file is only meaningful when there's
    # a VCS to record revisions against — a vendor folder in a plain directory
    # should work without it.
    # Uses /tmp so that `getVcsTypeAndSpecialDirPath`'s parent walk doesn't
    # find the nimble repo's own .git as an ancestor.
    let noVcsDir = getTempDir() / "nimble_t1509"
    cleanDir noVcsDir
    createDir noVcsDir
    let depDir = getTempDir() / "nimble_t1509_dep"
    cleanDir depDir
    createDir depDir
    writeFile(depDir / "depa.nimble", """
version = "0.1.0"
author = "Test"
description = "Test"
license = "MIT"
""")
    cd noVcsDir:
      writeFile("testproject.nimble", """
version = "0.1.0"
author = "Test"
description = "Test"
license = "MIT"
requires "nim >= 1.6.0"
""")
      let (output, exitCode) = execNimble("develop", "-l", "--add:" & depDir)
      check exitCode == QuitSuccess
      check not output.contains("supported type of version control")
      check fileExists("nimble.develop")

  test "can develop list of packages":
    cdCleanDir installDir:
      usePackageListFile developPkgList:
        let (output, exitCode) = execNimble(
          "develop", pkgAName, pkgBName)
        check exitCode == QuitSuccess
        var lines = output.processOutput
        check lines.inLines(pkgSetupInDevModeMsg(
          pkgAName, installDir / defaultPath / pkgAName))
        check lines.inLines(pkgSetupInDevModeMsg(
          pkgBName, installDir / defaultPath / pkgBName))

  # Skipped: In vnext, develop does not install dependencies to pkgs2,
  # so the "remove" command can't find them. This reverse-dependency check
  # only applies to packages installed via "nimble install".
  # test "cannot remove package with develop reverse dependency":

  test "can develop binary packages":
    cd "develop/binary":
      let (output, exitCode) = execNimble("develop")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(
        pkgSetupInDevModeMsg("binary", getCurrentDir()))

  test "develop lib + bin simultaneously picks up live lib changes (#1165)":
    # Regression for nim-lang/nimble#1165: a binary linked via
    # `develop -a:` to a local library must observe edits to that library
    # without re-installing it. Builds the bin once with the lib at "v1",
    # edits the lib source to "v2", rebuilds, and asserts the bin's runtime
    # output reflects the edit — proving the develop link is live.
    cdCleanDir installDir:
      # Lib package: exports a single proc returning a literal.
      createDir(installDir / "mylib" / "src")
      writeFile(installDir / "mylib" / "mylib.nimble", """
version = "0.1.0"
author = "Test"
description = "lib"
license = "MIT"
srcDir = "src"
requires "nim >= 1.6.0"
""")
      writeFile(installDir / "mylib" / "src" / "mylib.nim",
                "proc greet*(): string = \"v1\"\n")
      # Bin package: imports the lib and echoes its return value.
      createDir(installDir / "myapp" / "src")
      writeFile(installDir / "myapp" / "myapp.nimble", """
version = "0.1.0"
author = "Test"
description = "bin"
license = "MIT"
srcDir = "src"
bin = @["myapp"]
requires "nim >= 1.6.0", "mylib"
""")
      writeFile(installDir / "myapp" / "src" / "myapp.nim",
                "import mylib\necho greet()\n")

      cd installDir / "myapp":
        let (_, devExit) = execNimble("develop", "-l", "-a:" & (installDir / "mylib"))
        check devExit == QuitSuccess
        # First run: bin should print "v1".
        let (out1, run1Exit) = execNimble("run", "-l")
        check run1Exit == QuitSuccess
        check out1.contains("v1")
        # Edit the lib source — develop link must point at this exact file.
        writeFile(installDir / "mylib" / "src" / "mylib.nim",
                  "proc greet*(): string = \"v2\"\n")
        # Second run: bin must reflect the lib edit, not the previous build.
        let (out2, run2Exit) = execNimble("run", "-l")
        check run2Exit == QuitSuccess
        check out2.contains("v2")

  test "can develop hybrid":
    cd &"develop/{pkgHybridName}":
      let (output, exitCode) = execNimble("develop")
      check exitCode == QuitSuccess
      var lines = output.processOutput
      # #853: the misleading "binaries will not be compiled" warning was
      # removed for binary and hybrid packages. `nimble build` still builds
      # the binary; develop only sets up dependencies.
      check not lines.inLines("will not be compiled")
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
    check output.processOutput.inLines(developOptionsWithoutDevelopFileMsg)

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
          pkgAAbsPath = installDir / pkgAName.toLower
          developFileContent = developFile(@[], @[pkgAAbsPath])
        check exitCode == QuitSuccess
        check parseFile(developFileName) == parseJson(developFileContent)
        var lines = output.processOutput
        check lines.inLinesOrdered(pkgSetupInDevModeMsg(pkgAName, pkgAAbsPath))
        check lines.inLinesOrdered(pkgAddedInDevFileMsg(
          &"{pkgAName}@0.6.0", pkgAAbsPath, developFileName))

  test "can add not a dependency downloaded package to the develop file":
    cleanDir installDir
    cd "develop/dependency":
      usePackageListFile &"../{pkgListFileName}":
        cleanFile developFileName
        let
          (output, exitCode) = execNimble(
            "develop", &"-p:{installDir}", pkgAName, pkgBName)
          pkgAAbsPath = installDir / pkgAName.toLower
          pkgBAbsPath = installDir / pkgBName.toLower
          developFileContent = developFile(@[], @[pkgAAbsPath, pkgBAbsPath])
        check exitCode == QuitSuccess
        check parseFile(developFileName) == parseJson(developFileContent)
        var lines = output.processOutput
        check lines.inLinesOrdered(pkgSetupInDevModeMsg(pkgAName, pkgAAbsPath))
        check lines.inLinesOrdered(pkgSetupInDevModeMsg(pkgBName, pkgBAbsPath))
        check lines.inLinesOrdered(pkgAddedInDevFileMsg(
          &"{pkgAName}@0.6.0", pkgAAbsPath, developFileName))
        check lines.inLinesOrdered(pkgAddedInDevFileMsg(
          &"{pkgBName}@0.2.0", pkgBAbsPath, developFileName))

  test "add package to develop file":
    cleanDir installDir
    cd dependentPkgPath:
      usePackageListFile &"../{pkgListFileName}":
        cleanFiles developFileName, dependentPkgName.addFileExt(ExeExt)
        var (output, exitCode) = execNimble("develop", &"-a:{depPath}")
        check exitCode == QuitSuccess
        check developFileName.fileExists
        check output.processOutput.inLines(pkgAddedInDevFileMsg(
          depNameAndVersion, depPath, developFileName))
        const expectedDevelopFile = developFile(@[], @[depPath])
        check parseFile(developFileName) == parseJson(expectedDevelopFile)
        (output, exitCode) = execNimble("run")
        check exitCode == QuitSuccess
        check packageDirExists(pkgsDir, pkgAName & "-0.5.0")

  test "build reports which deps are develop-linked (#405)":
    # Regression for nim-lang/nimble#405: it's hard to tell whether a
    # `develop -a:` link is actually being consumed by a build. The output
    # must name the develop-linked dependency together with its source
    # directory so users can confirm the link is active without inspecting
    # nimble.paths by hand.
    cleanDir installDir
    cd dependentPkgPath:
      usePackageListFile &"../{pkgListFileName}":
        cleanFiles developFileName, dependentPkgName.addFileExt(ExeExt)
        let (_, devExit) = execNimble("develop", &"-a:{depPath}")
        check devExit == QuitSuccess
        let (output, runExit) = execNimble("run")
        check runExit == QuitSuccess
        let lines = output.processOutput
        # Develop status surfaced for the linked dep at default verbosity.
        let depAbs = depPath.absolutePath.normalizedPath
        check lines.inLines(&"{depName} [develop: {depAbs}]")

  test "warning on attempt to add the same package twice":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      let (output, exitCode) = execNimble("develop", &"-a:{depPath}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(pkgAlreadyInDevFileMsg(
        depNameAndVersion, depPath, developFileName))
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

  test "can add not a dependency to develop file":
    cd dependentPkgPath:
      cleanFile developFileName
      const srcDirTestPath = "../srcdirtest".normalizedPath
      let (output, exitCode) = execNimble("develop", &"-a:{srcDirTestPath}")
      check exitCode == QuitSuccess
      let lines = output.processOutput
      check lines.inLines(pkgAddedInDevFileMsg(
        "srcdirtest@1.0", srcDirTestPath, developFileName))
      const developFileContent = developFile(@[], @[srcDirTestPath])
      check parseFile(developFileName) == parseJson(developFileContent)

  test "cannot add two packages with the same name to develop file":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      let (output, exitCode) = execNimble("develop", &"-a:{dep2Path}")
      check exitCode == QuitFailure
      check output.processOutput.inLines(pkgAlreadyPresentAtDifferentPathMsg(
        depName, depPath, developFileName))
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
      check output.processOutput.inLines(pkgRemovedFromDevFileMsg(
        depNameAndVersion, depPath, developFileName))
      check parseFile(developFileName) == parseJson(emptyDevelopFileContent)

  test "warning on attempt to remove not existing package path":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      let (output, exitCode) = execNimble("develop", &"-r:{dep2Path}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(pkgPathNotInDevFileMsg(
        dep2Path, developFileName))
      check parseFile(developFileName) == parseJson(developFileContent)

  test "remove package from develop file by name":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      let (output, exitCode) = execNimble("develop", &"-n:{depName}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(pkgRemovedFromDevFileMsg(
        depNameAndVersion, depPath, developFileName))
      check parseFile(developFileName) == parseJson(emptyDevelopFileContent)

  test "warning on attempt to remove not existing package name":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      const notExistingPkgName = "dependency2"
      let (output, exitCode) = execNimble("develop", &"-n:{notExistingPkgName}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(pkgNameNotInDevFileMsg(
        notExistingPkgName, developFileName))
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
        check output.processOutput.inLines(inclInDevFileMsg(
          includeFileName, developFileName))
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
      check output.processOutput.inLines(alreadyInclInDevFileMsg(
        includeFileName, developFileName))
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
        check output.processOutput.inLines(inclInDevFileMsg(
          includeFileName, developFileName))
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

      let (output, exitCode) = execNimble("develop", &"-i:{includeFileName}")

      check exitCode == QuitFailure
      var lines = output.processOutput
      check lines.inLinesOrdered(
        failedToInclInDevFileMsg(includeFileName, developFileName))
      check lines.inLinesOrdered(pkgFoundMoreThanOnceMsg(depName,
        [(depPath.Path, developFileName.Path),
         (dep2Path.Path, includeFileName.Path)].toHashSet))
      check parseFile(developFileName) == parseJson(developFileContent)

  test "exclude develop file":
    cd dependentPkgPath:
      cleanFiles developFileName, includeFileName
      const developFileContent = developFile(@[includeFileName], @[])
      writeFile(developFileName, developFileContent)
      const includeFileContent = developFile(@[], @[depPath])
      writeFile(includeFileName, includeFileContent)
      let (output, exitCode) = execNimble("develop", &"-e:{includeFileName}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(exclFromDevFileMsg(
        includeFileName, developFileName))
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
      check output.processOutput.inLines(notInclInDevFileMsg(
        (&"../{includeFileName}").normalizedPath, developFileName))
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
      check lines.inLinesOrdered(exclFromDevFileMsg(
        includeFileAbsolutePath, developFileName))
      check lines.inLinesOrdered(pkgRemovedFromDevFileMsg(
        depNameAndVersion, dependencyPkgAbsolutePath, developFileName))
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
      check lines.inLinesOrdered(exclFromDevFileMsg(
        includeFileName, developFileName))
      check lines.inLinesOrdered(pkgRemovedFromDevFileMsg(
        depNameAndVersion, depPath, developFileName))
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

        block checkSuccessfulUninstallButNotRemoveFromNimbleData:
          let
            (_, exitCode) = execNimbleYes("uninstall", "-i", pkgAName)
            nimbleData = parseFile(installDir / nimbleDataFileName)

          check exitCode == QuitSuccess
          # The package should remain in the Nimble data because in the case it
          # is installed again it should continue to block its uninstalling
          # without the "-i" option until all reverse dependencies (leaf nodes
          # of the JSON object) are uninstalled.
          check nimbleData[$ndjkRevDep].hasKey(pkgAName)

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
        let (_, exitCode) = execNimble("run", "-y")
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

  # test "relative include paths are followed from the file's directory":
  #   cd dependentPkgPath:
  #     const includeFilePath = &"../{includeFileName}"
  #     cleanFiles includeFilePath, developFileName, dependentPkgName.addFileExt(ExeExt)
  #     const developFileContent = developFile(@[includeFilePath], @[])
  #     writeFile(developFileName, developFileContent)
  #     const includeFileContent = developFile(@[], @["./dependency2/"])
  #     writeFile(includeFilePath, includeFileContent)
  #     let (_, errorCode) = execNimble("run", "-y")
  #     check errorCode == QuitSuccess

  test "do not filter not used included develop dependencies":
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
        let (output, exitCode) = execNimble("run", "-y", "--verbose")
        check exitCode == QuitSuccess
        var lines = output.processOutput
        check lines.inLinesOrdered(
          pkgDepsAlreadySatisfiedMsg(("pkg2", anyVersion)))
        check lines.inLinesOrdered(
          pkgDepsAlreadySatisfiedMsg(("pkg3", anyVersion)))

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
        let (output, exitCode) = execNimble("run", "-n", "--verbose")
        check exitCode == QuitSuccess
        var lines = output.processOutput
        check lines.inLinesOrdered(
          pkgDepsAlreadySatisfiedMsg(("pkg3", anyVersion)))
        check lines.inLinesOrdered(
          pkgDepsAlreadySatisfiedMsg(("pkg2", anyVersion)))
        check lines.inLinesOrdered(
          pkgDepsAlreadySatisfiedMsg(("pkg3", anyVersion)))       

  test "version clash with not used included develop dependencies":
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

    # Here the build must fail because both the version of "pkg3" included via
    # "develop1.json" and the version of "pkg3" included via "develop2.json" are
    # taken into account.

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
        pkg3Path = (".." / "pkg3").Path
        pkg32Path = (".." / "pkg3.2").Path
        freeDevFile1Path = (".." / freeDevFile1Name).Path
        freeDevFile2Path = (".." / freeDevFile2Name).Path

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
        check lines.inLinesOrdered(pkgFoundMoreThanOnceMsg("pkg3",
          [(pkg3Path, freeDevFile1Path),
           (pkg32Path, freeDevFile2Path)].toHashSet))

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

        let
          pkg3Path = (".." / "pkg3").Path
          pkg32Path = (".." / "pkg3.2").Path
          freeDevFile1Path = (".." / freeDevFile1Name).Path
          freeDevFile2Path = (".." / freeDevFile2Name).Path

        check lines.inLinesOrdered(pkgFoundMoreThanOnceMsg("pkg3",
          [(pkg3Path, freeDevFile1Path),
           (pkg32Path, freeDevFile2Path)].toHashSet))

  test "create an empty develop file in some dir":
    cleanDir installDir
    let filePath = installDir / "develop.json"
    cleanFile filePath
    createDir installDir
    let (output, errorCode) = execNimble(
      "--debug", "develop", &"--develop-file:{filePath}")
    check errorCode == QuitSuccess
    check parseFile(filePath) == parseJson(emptyDevelopFileContent)
    check output.processOutput.inLines(developFileSavedMsg(filePath))

  test "try to create a develop file in not existing dir":
    let filePath = installDir / "some/not/existing/dir/develop.json"
    cleanFile filePath
    let (output, errorCode) = execNimble(
      "--debug", "develop", &"--develop-file:{filePath}")
    check errorCode == QuitFailure
    check output.processOutput.inLines(&"cannot open: {filePath}")

  test "can manipulate a free develop file":
    cleanDir installDir
    cd dependentPkgPath:
      usePackageListFile &"../{pkgListFileName}":
        const
          developFileName = "develop.json"
          includeFileName = "include.json"
          includeFileContent = developFile(@[], @[depPath])
        cleanFiles developFileName, includeFileName
        writeFile(includeFileName, includeFileContent)
        var (output, exitCode) = execNimble(
          "develop", &"--develop-file:{developFileName}",
          &"-a:{depPath}", &"-i:{includeFileName}")
        check exitCode == QuitSuccess
        var lines = output.processOutput
        check lines.inLinesOrdered(pkgAddedInDevFileMsg(
          depNameAndVersion, depPath, developFileName))
        check lines.inLinesOrdered(inclInDevFileMsg(
          includeFileName, developFileName))
        const expectedDevelopFile = developFile(@[includeFileName], @[depPath])
        check parseFile(developFileName) == parseJson(expectedDevelopFile)

  test "add develop --with-dependencies packages to free develop file":
    cdCleanDir installDir:
      const developFile = "develop.json"
      usePackageListFile developPkgList:
        let (output, exitCode) = execNimble("--debug", "develop",
          "--with-dependencies", &"--develop-file:{developFile}", pkgBName)
        check exitCode == QuitSuccess
        let 
          pkgAPath = installDir / defaultPath / pkgAName.toLower
          pkgBPath = installDir / defaultPath / pkgBName.toLower
        var lines = output.processOutput
        check lines.inLines(pkgSetupInDevModeMsg(pkgAName, pkgAPath))
        check lines.inLines(pkgSetupInDevModeMsg(pkgBName, pkgBPath))
        check lines.inLines(pkgAddedInDevFileMsg(
          &"{pkgBName}@0.2.0", pkgBPath, developFile))
        check lines.inLines(developFileSavedMsg(developFile))
        # Verify develop file contains at least PackageB
        let devFileJson = parseFile(developFile)
        check devFileJson["dependencies"].len >= 1

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

        let (output, errorCode) = execNimble("develop", &"-p:{installDir}",
          pkgAName,                    # success
          &"-a:{depPath}",             # success
          &"-a:{dep2Path}",            # fail because of names collision
          &"-i:{includeFileName}",     # fail because of names collision
          &"-n:{depName}",             # success
          &"-a:{dep2Path}",            # success
          &"-i:{includeFileName}",     # success
          &"-i:{invalidInclFilePath}") # fail

        check errorCode == QuitFailure
        var lines = output.processOutput
        check lines.inLinesOrdered(pkgSetupInDevModeMsg(
          pkgAName, installDir / pkgAName.toLower))
        check lines.inLinesOrdered(pkgAddedInDevFileMsg(
          depNameAndVersion, depPath, developFileName))
        check lines.inLinesOrdered(pkgAlreadyPresentAtDifferentPathMsg(
          depName, depPath, developFileName))
        check lines.inLinesOrdered(
          failedToInclInDevFileMsg(includeFileName, developFileName))
        check lines.inLinesOrdered(pkgFoundMoreThanOnceMsg(depName,
          [(depPath.Path, developFileName.Path),
           (dep2Path.Path, includeFileName.Path)].toHashSet))
        check lines.inLinesOrdered(pkgRemovedFromDevFileMsg(
          depNameAndVersion, depPath, developFileName))
        check lines.inLinesOrdered(pkgAddedInDevFileMsg(
          depNameAndVersion, dep2Path, developFileName))
        check lines.inLinesOrdered(inclInDevFileMsg(
          includeFileName, developFileName))
        check lines.inLinesOrdered(failedToLoadFileMsg(invalidInclFilePath))
        let expectedDevelopFileContent = developFile(
          @[includeFileName], @[dep2Path, installDir / pkgAName.toLower])
        check parseFile(developFileName) ==
              parseJson(expectedDevelopFileContent)
