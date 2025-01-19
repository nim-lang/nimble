# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, strformat, json, strutils, sequtils

import testscommon

import nimblepkg/displaymessages
import nimblepkg/sha1hashes
import nimblepkg/paths
import nimblepkg/vcstools

from nimblepkg/common import cd, dump, cdNewDir
from nimblepkg/tools import tryDoCmdEx, doCmdEx
from nimblepkg/packageinfotypes import DownloadMethod
from nimblepkg/lockfile import LockFileJsonKeys
from nimblepkg/options import defaultLockFileName
from nimblepkg/developfile import ValidationError, ValidationErrorKind,
  developFileName, getValidationErrorMessage

suite "publish":
  const
    tempDir = getTempDir() / "tpublish"

    originsDirName = "origins"
    originsDirPath = tempDir / originsDirName

    nimbleFileTemplate = """

version       = "$1"
author        = "Ivan Bobev"
description   = "A new awesome nimble package"
license       = "MIT"
requires "nim >= 1.5.1"
"""

  proc newNimbleFileContent(pkgName, fileTemplate: string,
                            deps: seq[string]): string =
    result = fileTemplate % pkgName
    if deps.len == 0:
      return
    result &= "requires "
    for i, dep in deps:
      result &= &"\"{dep}\""
      if i != deps.len - 1:
        result &= ","

  proc addFiles(files: varargs[string]) =
    var filesStr = ""
    for file in files:
      filesStr &= file & " "
    tryDoCmdEx("git add " & filesStr)

  proc commit(msg: string) =
    tryDoCmdEx("git commit -am " & msg.quoteShell)

  proc push(remote: string) =
    tryDoCmdEx(
      &"git push --set-upstream {remote} {vcsTypeGit.getVcsDefaultBranchName}")

  proc pull(remote: string) =
    tryDoCmdEx("git pull " & remote)

  proc addRemote(remoteName, remoteUrl: string) =
    tryDoCmdEx(&"git remote add {remoteName} {remoteUrl}")

  proc configUserAndEmail =
    tryDoCmdEx("git config user.name \"John Doe\"")
    tryDoCmdEx("git config user.email \"john.doe@example.com\"")

  proc initRepo(isBare = false) =
    let bare = if isBare: "--bare" else: ""
    tryDoCmdEx("git init " & bare)
    configUserAndEmail()

  proc clone(urlFrom, pathTo: string) =
    tryDoCmdEx(&"git clone {urlFrom} {pathTo}")
    cd pathTo: configUserAndEmail()

  proc branch(branchName: string) =
    tryDoCmdEx(&"git branch {branchName}")

  proc checkout(what: string) =
    tryDoCmdEx(&"git checkout {what}")

  proc createBranchAndSwitchToIt(branchName: string) =
    if branchName.len > 0:
      branch(branchName)
      checkout(branchName)

  proc initNewNimbleFile(dir: string, deps: seq[string] = @[]): string =
    let pkgName = dir.splitPath.tail
    let nimbleFileName = pkgName & ".nimble"
    let nimbleFileContent = newNimbleFileContent(
      pkgName, nimbleFileTemplate, deps)
    writeFile(nimbleFileName, nimbleFileContent)
    return nimbleFileName

  proc initNewNimblePackage(dir, clonePath: string, deps: seq[string] = @[]) =
    cdNewDir dir:
      initRepo()
      let nimbleFileName = dir.initNewNimbleFile(deps)
      addFiles(nimbleFileName)
      commit("Initial commit")

    clone(dir, clonePath)

  proc addAdditionalFileToTheRepo(fileName, fileContent: string) =
    writeFile(fileName, fileContent)
    addFiles(fileName)
    commit("Add additional file")

  proc testLockedVcsRevisions(deps: seq[tuple[name, path: string]], lockFileName = defaultLockFileName) =
    check lockFileName.fileExists

    let json = lockFileName.readFile.parseJson
    for (depName, depPath) in deps:
      let expectedVcsRevision = depPath.getVcsRevision
      check depName in json{$lfjkPackages}
      let lockedVcsRevision =
        json{$lfjkPackages}{depName}{$lfjkPkgVcsRevision}.str.initSha1Hash
      check lockedVcsRevision == expectedVcsRevision

  proc testLockFile(deps: seq[tuple[name, path: string]], isNew: bool, lockFileName = defaultLockFileName) =
    ## Generates or updates a lock file and tests whether it contains
    ## dependencies with given names at given repository paths and whether their
    ## VCS revisions match the written in the lock file ones.
    ##
    ## `isNew` - indicates whether it is expected a new lock file to be
    ## generated if its value is `true` or already existing lock file to be
    ## updated otherwise.

    if isNew:
      check not fileExists(lockFileName)
    else:
      check fileExists(lockFileName)

    let (output, exitCode) = if lockFileName == defaultLockFileName:
        execNimbleYes("lock")
      else:
        execNimbleYes("--lock-file=" & lockFileName, "lock")

    check exitCode == QuitSuccess

    var lines = output.processOutput
    if isNew:
      check lines.inLinesOrdered(generatingTheLockFileMsg)
      check lines.inLinesOrdered(lockFileIsGeneratedMsg)
    else:
      check lines.inLinesOrdered(updatingTheLockFileMsg)
      check lines.inLinesOrdered(lockFileIsUpdatedMsg)

    testLockedVcsRevisions(deps, lockFileName)

  template filesAndDirsToRemove() =
    removeFile pkgListFilePath
    removeDir installDir
    removeDir tempDir

  template cleanUp() =
    filesAndDirsToRemove()
    defer: filesAndDirsToRemove()

  proc writePackageListFile(path: string, content: PackagesListFileContent) =
    let dir = path.splitPath.head
    createDir dir
    writeFile(path, (%content).pretty)

  template withPkgListFile(body: untyped) =
    writePackageListFile(
      pkgListFilePath, @[dep1PkgListFileRecord, dep2PkgListFileRecord])
    usePackageListFile pkgListFilePath:
      body

  proc getRepoRevision: string =
    result = tryDoCmdEx("git rev-parse HEAD").replace("\n", "")

  proc getRevision(dep: string, lockFileName = defaultLockFileName): string =
    result = lockFileName.readFile.parseJson{$lfjkPackages}{dep}{$lfjkPkgVcsRevision}.str

  proc addAdditionalFileAndPushToRemote(
      repoPath, remoteName, remotePath, fileContent: string) =
    cdNewDir remotePath:
      initRepo(isBare = true)
    cd repoPath:
      # Add commit to the dependency.
      addAdditionalFileToTheRepo("dep1.nim", fileContent)
      addRemote(remoteName, remotePath)
      # Push it to the newly added remote to be able to lock.
      push(remoteName)

  proc testDepsSync =
    let (output, exitCode) = execNimbleYes("sync")
    check exitCode == QuitSuccess
    let lines = output.processOutput
    check lines.inLines(
      pkgWorkingCopyIsSyncedMsg(dep1PkgName, dep1PkgRepoPath))
    check lines.inLines(
      pkgWorkingCopyIsSyncedMsg(dep2PkgName, dep2PkgRepoPath))

    cd mainPkgRepoPath:
      # After successful sync the revisions written in the lock file must
      # match those in the lock file.
      testLockedVcsRevisions(@[(dep1PkgName, dep1PkgRepoPath),
                                (dep2PkgName, dep2PkgRepoPath)])

  test "test publishVersions":
    cleanUp()
    cd "nimdep":
      removeFile "nimble.develop"
      removeFile "nimble.lock"
      removeDir "Nim"

      check execNimbleYes("-y", "develop", "nim").exitCode == QuitSuccess
      cd "Nim":
        let (_, exitCode) = execNimbleYes("-y", "install")
        check exitCode == QuitSuccess

      # check if the compiler version will be used when doing build
      testLockFile(@[("nim", "Nim")], isNew = true)
      removeFile "nimble.develop"
      removeDir "Nim"

      let (output, exitCodeInstall) = execNimbleYes("-y", "build")
      check exitCodeInstall == QuitSuccess
      let usingNim = when defined(Windows): "nim.exe for compilation" else: "bin/nim for compilation"
      check output.contains(usingNim)

      # check the nim version
      let (outputVersion, _) = execNimble("version")
      check outputVersion.contains(getRevision("nim"))

      let (outputGlobalNim, exitCodeGlobalNim) = execNimbleYes("-y", "--use-system-nim", "build")
      check exitCodeGlobalNim == QuitSuccess
      check not outputGlobalNim.contains(usingNim)
