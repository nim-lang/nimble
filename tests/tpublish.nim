# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, strformat, json, strutils

import testscommon

import nimblepkg/sha1hashes
import nimblepkg/paths

from nimblepkg/common import cd, dump, cdNewDir
from nimblepkg/tools import tryDoCmdEx, doCmdEx
from nimblepkg/packageinfotypes import DownloadMethod
from nimblepkg/lockfile import LockFileJsonKeys

suite "publish":
  type
    PackagesListFileRecord = object
      name: string
      url: string
      `method`: DownloadMethod
      tags: seq[string]
      description: string
      license: string

    # PackagesListFileContent = seq[PackagesListFileRecord]

    PkgIdent {.pure.} = enum
      main = "main"
      bad1 = "bad1"
      bad2 = "bad2"
      nonAll = "nonAll"

  template definePackageConstants(pkgName: PkgIdent) =
    ## By given dependency number defines all relevant constants for it.

    const
      `pkgName"PkgName"` {.used, inject.} = $pkgName
      `pkgName"PkgNimbleFileName"` {.used, inject.} =
        `pkgName"PkgName"` & ".nimble"
      `pkgName"PkgRepoPath"` {.used, inject.} = tempDir / `pkgName"PkgName"`
      `pkgName"PkgOriginRepoPath"`{.used, inject.} =
        originsDirPath / `pkgName"PkgName"`
      `pkgName"PkgRemoteName"` {.used, inject.} =
        `pkgName"PkgName"` & "Remote"
      `pkgName"PkgRemotePath"` {.used, inject.} =
        additionalRemotesDirPath / `pkgName"PkgRemoteName"`
      `pkgName"PkgOriginRemoteName"` {.used, inject.} =
        `pkgName"PkgName"` & "OriginRemote"
      `pkgName"PkgOriginRemotePath"` {.used, inject.} =
        additionalRemotesDirPath / `pkgName"PkgOriginRemoteName"`

      `pkgName"PkgListFileRecord"` {.used, inject.} = PackagesListFileRecord(
        name: `pkgName"PkgName"`,
        url: `pkgName"PkgOriginRepoPath"`,
        `method`: DownloadMethod.git,
        tags: @["test"],
        description: "This is a test package.",
        license: "MIT")

  const
    tempDir = getTempDir() / "tlockfile"

    originsDirName = "origins"
    originsDirPath = tempDir / originsDirName

    additionalRemotesDirName = "remotes"
    additionalRemotesDirPath = tempDir / additionalRemotesDirName

    # pkgListFileName = "packages.json"
    # pkgListFilePath = tempDir / pkgListFileName

    nimbleFileTemplate = """

version       = "$1"
author        = "Ivan Bobev"
description   = "A new awesome nimble package"
license       = "MIT"
requires "nim >= 1.5.1"
"""

  definePackageConstants(PkgIdent.main)
  definePackageConstants(PkgIdent.bad1)
  definePackageConstants(PkgIdent.bad2)
  definePackageConstants(PkgIdent.nonAll)

  proc newNimbleFileContent(fileTemplate: string,
                            version: string): string =
    result = fileTemplate % [version]

  proc addFiles(files: varargs[string]) =
    var filesStr = ""
    for file in files:
      filesStr &= file & " "
    tryDoCmdEx("git add " & filesStr)

  proc commit(msg: string) =
    tryDoCmdEx("git commit -am " & msg.quoteShell)

  proc configUserAndEmail =
    tryDoCmdEx("git config user.name \"John Doe\"")
    tryDoCmdEx("git config user.email \"john.doe@example.com\"")

  proc initRepo(isBare = false) =
    let bare = if isBare: "--bare" else: ""
    tryDoCmdEx("git init " & bare)
    configUserAndEmail()

  proc getRepoRevision: string =
    result = tryDoCmdEx("git rev-parse HEAD").replace("\n", "")

  proc initNewNimbleFile(dir: string, version: string): string =
    let pkgName = dir.splitPath.tail
    let nimbleFileName = pkgName & ".nimble"
    let nimbleFileContent = newNimbleFileContent(nimbleFileTemplate, version)
    writeFile(nimbleFileName, nimbleFileContent)
    return nimbleFileName

  proc addAdditionalFileToTheRepo(fileName, fileContent: string) =
    writeFile(fileName, fileContent)
    addFiles(fileName)
    commit("Add additional file")

  proc initNewNimblePackage(dir: string, versions: seq[string], tags: seq[string] = @[]) =
    cdNewDir dir:
      initRepo()
      echo "created repo at: ", dir
      for idx, version in versions:
        let nimbleFileName = dir.initNewNimbleFile(version)
        addFiles(nimbleFileName)
        commit("commit $1" % version)
        # echo "created package version ", version
        let commit = getRepoRevision()
        if version in tags:
          echo "tagging version ", version, " tag ", commit
          tryDoCmdEx("git tag " & "v$1" % version.quoteShell())
        if idx in [0, 1, versions.len() - 2]:
          addAdditionalFileToTheRepo("test.txt", $idx)
          

  # template filesAndDirsToRemove() =
  #   removeFile pkgListFilePath
  #   removeDir installDir
  #   removeDir tempDir

  # template cleanUp() =
  #   filesAndDirsToRemove()
  #   defer: filesAndDirsToRemove()

  test "test publishVersions basic find versions":
    # cleanUp()
    let versions = @["0.1.0", "0.1.1", "0.1.2", "0.2.1", "1.0.0"]
    initNewNimblePackage(mainPkgRepoPath, versions)
    cd mainPkgRepoPath:
      echo "mainPkgRepoPath: ", mainPkgRepoPath
      echo "getCurrentDir: ", getCurrentDir()

      let (output, exitCode) = execNimbleYes("-y", "publishVersions")

      check exitCode == QuitSuccess
      for version in versions[1..^1]:
        check output.contains("Found new version $1" % version)

  test "test warning publishVersions non-monotonic versions":
    # cleanUp()
    let versions = @["0.1.0", "0.1.1", "0.1.2", "2.1.0", "0.2.1", "1.0.0"]
    initNewNimblePackage(bad1PkgRepoPath, versions)
    cd bad1PkgRepoPath:
      echo "mainPkgRepoPath: ", bad1PkgRepoPath
      echo "getCurrentDir: ", getCurrentDir()

      let (output, exitCode) = execNimbleYes("-y", "publishVersions")

      check output.contains("Non-monotonic (decreasing) version found between tag v2.1.0")

      check exitCode == QuitSuccess
      for version in versions[1..^1]:
        check output.contains("Found new version $1" % version)

  test "test skipping publishVersions non-monotonic versions":
    # cleanUp()
    let versions = @["0.1.0", "0.1.1", "2.1.0", "0.2.1", "1.0.0"]
    # initNewNimblePackage(bad1PkgRepoPath, versions)
    cd bad1PkgRepoPath:
      echo "mainPkgRepoPath: ", bad1PkgRepoPath
      echo "getCurrentDir: ", getCurrentDir()

      let (output, exitCode) = execNimbleYes("publishVersions", "--create")

      check output.contains("Non-monotonic (decreasing) version found between tag v2.1.0")

      check exitCode == QuitSuccess
      for version in versions[1..^1]:
        if version == "2.1.0":
          continue
        check output.contains("Creating tag for new version $1" % version)

  test "test skipping publishVersions non-monotonic versions 2 ":
    # cleanUp()
    let versions = @["0.1.0", "0.1.1", "0.2.3", "2.1.0", "0.2.2", "0.2.4"]
    initNewNimblePackage(bad2PkgRepoPath, versions)
    cd bad2PkgRepoPath:
      echo "mainPkgRepoPath: ", bad2PkgRepoPath
      echo "getCurrentDir: ", getCurrentDir()

      let (output, exitCode) = execNimbleYes("publishVersions", "--create")

      check output.contains("Non-monotonic (decreasing) version found between tag v2.1.0")
      check output.contains("Non-monotonic (decreasing) version found between tag v0.2.3")

      check exitCode == QuitSuccess
      for version in versions[1..^1]:
        if version in ["2.1.0", "0.2.3"]:
          continue
        check output.contains("Creating tag for new version $1" % version)

  test "test non-all ":
    # cleanUp()
    let versions = @["0.1.0", "0.2.3", "2.1.0", "0.3.2", "0.3.3", "0.3.4", "0.3.5"]
    initNewNimblePackage(nonAllPkgRepoPath, versions, tags = @["0.3.3"])
    cd nonAllPkgRepoPath:
      echo "mainPkgRepoPath: ", nonAllPkgRepoPath
      echo "getCurrentDir: ", getCurrentDir()

      let (output, exitCode) = execNimbleYes("publishVersions", "--create")

      check not output.contains("Non-monotonic (decreasing) version found between tag v2.1.0")
      check not output.contains("Non-monotonic (decreasing) version found between tag v0.2.3")

      check exitCode == QuitSuccess
      for version in versions:
        if version in @["0.3.4", "0.3.5"]:
          checkpoint("Checking for version $1" % version)
          check output.contains("Creating tag for new version $1" % version)
        else:
          checkpoint("Checking version $1 is not found" % version)
          check not output.contains("Creating tag for new version $1" % version)

  test "test all":
    # cleanUp()
    let versions = @["0.1.0", "0.2.3", "2.1.0", "0.3.2", "0.3.3", "0.3.4", "0.3.5"]
    cd nonAllPkgRepoPath:
      echo "mainPkgRepoPath: ", nonAllPkgRepoPath
      echo "getCurrentDir: ", getCurrentDir()

      let (output, exitCode) = execNimbleYes("publishVersions", "--create", "--all")

      check output.contains("Non-monotonic (decreasing) version found between tag v2.1.0")
      check output.contains("Skipping creating tag for non-monotonic 2.1.0")

      check exitCode == QuitSuccess
      for version in versions[1..^1]:
        if version in ["0.3.3", "0.3.4", "0.3.5"]:
          checkpoint("Checking version $1 is not found" % version)
          check not output.contains("Creating tag for new version $1" % version)
        elif version in ["2.1.0"]:
          discard
        else:
          checkpoint("Checking for version $1" % version)
          check output.contains("Creating tag for new version $1" % version)
