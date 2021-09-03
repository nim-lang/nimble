# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, strformat, json, strutils

import testscommon

import nimblepkg/displaymessages
import nimblepkg/sha1hashes
import nimblepkg/paths
import nimblepkg/vcstools

from nimblepkg/common import cd, dump, cdNewDir
from nimblepkg/tools import tryDoCmdEx, doCmdEx
from nimblepkg/packageinfotypes import DownloadMethod
from nimblepkg/lockfile import lockFileName, LockFileJsonKeys
from nimblepkg/developfile import ValidationError, ValidationErrorKind,
  developFileName, getValidationErrorMessage

suite "lock file":
  type
    PackagesListFileRecord = object
      name: string
      url: string
      `method`: DownloadMethod
      tags: seq[string]
      description: string
      license: string

    PackagesListFileContent = seq[PackagesListFileRecord]

    PkgIdent {.pure.} = enum
      main = "main"
      dep1 = "dep1"
      dep2 = "dep2"

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

    pkgListFileName = "packages.json"
    pkgListFilePath = tempDir / pkgListFileName

    nimbleFileTemplate = """
version       = "0.1.0"
author        = "Ivan Bobev"
description   = "A new awesome nimble package"
license       = "MIT"
requires "nim >= 1.5.1"
"""
    additionalFileContent = "proc foo() =\n  echo \"foo\"\n"
    alternativeAdditionalFileContent = "proc bar() =\n  echo \"bar\"\n"

  definePackageConstants(PkgIdent.main)
  definePackageConstants(PkgIdent.dep1)
  definePackageConstants(PkgIdent.dep2)

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
    tryDoCmdEx("git commit -m " & msg.quoteShell)

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

  proc testLockedVcsRevisions(deps: seq[tuple[name, path: string]]) =
    check lockFileName.fileExists

    let json = lockFileName.readFile.parseJson
    for (depName, depPath) in deps:
      let expectedVcsRevision = depPath.getVcsRevision
      let lockedVcsRevision =
        json{$lfjkPackages}{depName}{$lfjkPkgVcsRevision}.str.initSha1Hash
      check lockedVcsRevision == expectedVcsRevision

  proc testLockFile(deps: seq[tuple[name, path: string]], isNew: bool) =
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

    let (output, exitCode) = execNimbleYes("lock", "--debug")
    check exitCode == QuitSuccess

    var lines = output.processOutput
    if isNew:
      check lines.inLinesOrdered(generatingTheLockFileMsg)
      check lines.inLinesOrdered(lockFileIsGeneratedMsg)
    else:
      check lines.inLinesOrdered(updatingTheLockFileMsg)
      check lines.inLinesOrdered(lockFileIsUpdatedMsg)

    testLockedVcsRevisions(deps)

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

  test "can generate lock file":
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath, mainPkgRepoPath,
                           @[dep1PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath)
      cd mainPkgRepoPath:
        testLockFile(@[(dep1PkgName, dep1PkgRepoPath)], isNew = true)

  test "cannot lock because develop dependency is out of range":
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath, mainPkgRepoPath,
                           @[dep1PkgName, dep2PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath)
      initNewNimblePackage(dep2PkgOriginRepoPath, dep2PkgRepoPath)
      cd mainPkgRepoPath:
        writeDevelopFile(developFileName, @[],
                         @[dep1PkgRepoPath, dep2PkgRepoPath])

        # Make main package's Nimble file to require dependencies versions
        # different than provided in the develop file.
        let nimbleFileContent = mainPkgNimbleFileName.readFile
        mainPkgNimbleFileName.writeFile(nimbleFileContent.replace(
          &"\"{dep1PkgName}\",\"{dep2PkgName}\"",
          &"\"{dep1PkgName} > 0.1.0\",\"{dep2PkgName} < 0.1.0\""))

        let (output, exitCode) = execNimbleYes("lock")
        check exitCode == QuitFailure
        let mainPkgRepoPath =
          when defined(macosx):
            # This is a workaround for the added `/private` prefix to the main
            # repository Nimble file path when executing the test on macOS.
            "/private" / mainPkgRepoPath
          else:
            mainPkgRepoPath
        let errors = @[
          notInRequiredRangeMsg(dep1PkgName, dep1PkgRepoPath, "0.1.0",
                                mainPkgName, mainPkgRepoPath, "> 0.1.0"),
          notInRequiredRangeMsg(dep2PkgName, dep2PkgRepoPath, "0.1.0",
                                mainPkgName, mainPkgRepoPath, "< 0.1.0")
          ]
        check output.processOutput.inLines(
          invalidDevelopDependenciesVersionsMsg(errors))

  test "can download locked dependencies":
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath, mainPkgRepoPath,
                           @[dep1PkgName, dep2PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath)
      initNewNimblePackage(dep2PkgOriginRepoPath, dep2PkgRepoPath)
      cd mainPkgRepoPath:
        testLockFile(@[(dep1PkgName, dep1PkgRepoPath),
                       (dep2PkgName, dep2PkgRepoPath)],
                     isNew = true)
        removeDir installDir
        let (output, exitCode) = execNimbleYes("install", "--debug")
        check exitCode == QuitSuccess
        let lines = output.processOutput
        check lines.inLines(&"Downloading {dep1PkgOriginRepoPath} using git")
        check lines.inLines(&"Downloading {dep2PkgOriginRepoPath} using git")

  test "can update already existing lock file":
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath, mainPkgRepoPath,
                           @[dep1PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath)
      initNewNimblePackage(dep2PkgOriginRepoPath, dep2PkgRepoPath)

      cd mainPkgRepoPath:
        testLockFile(@[(dep1PkgName, dep1PkgRepoPath)], isNew = true)
        # Add additional dependency to the nimble file.
        let mainPkgNimbleFileContent = newNimbleFileContent(mainPkgName,
          nimbleFileTemplate, @[dep1PkgName, dep2PkgName])
        writeFile(mainPkgNimbleFileName, mainPkgNimbleFileContent)
        # Make first dependency to be in develop mode.
        writeDevelopFile(developFileName, @[], @[dep1PkgRepoPath])

      cd dep1PkgOriginRepoPath:
        # Add additional file to the first dependency, commit and push.
        addAdditionalFileToTheRepo("dep1.nim", additionalFileContent)

      cd dep1PkgRepoPath:
        pull("origin")

      cd mainPkgRepoPath:
        # On second lock the first package revision is updated and a second
        # package is added as dependency.
        testLockFile(@[(dep1PkgName, dep1PkgRepoPath),
                       (dep2PkgName, dep2PkgRepoPath)],
                     isNew = false)

  template outOfSyncDepsTest(branchName: string, body: untyped) =
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath, mainPkgRepoPath,
                           @[dep1PkgName, dep2PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath)
      initNewNimblePackage(dep2PkgOriginRepoPath, dep2PkgRepoPath)

      cd dep1PkgOriginRepoPath:
        createBranchAndSwitchToIt(branchName)
        addAdditionalFileToTheRepo("dep1.nim", additionalFileContent)
      
      cd dep2PkgOriginRepoPath:
        createBranchAndSwitchToIt(branchName)
        addAdditionalFileToTheRepo("dep2.nim", additionalFileContent)

      cd mainPkgOriginRepoPath:
        testLockFile(@[(dep1PkgName, dep1PkgOriginRepoPath),
                       (dep2PkgName, dep2PkgOriginRepoPath)],
                     isNew = true)
        addFiles(lockFileName)
        commit("Add the lock file to version control")

      cd mainPkgRepoPath:
        pull("origin")
        let (_ {.used.}, devCmdExitCode) = execNimble("develop",
          &"-a:{dep1PkgRepoPath}", &"-a:{dep2PkgRepoPath}")
        check devCmdExitCode == QuitSuccess
        `body`

  test "can list out of sync develop dependencies":
    outOfSyncDepsTest(""):
      let (output, exitCode) = execNimbleYes("sync", "--list-only")
      check exitCode == QuitSuccess
      let lines = output.processOutput
      check lines.inLines(
        pkgWorkingCopyNeedsSyncingMsg(dep1PkgName, dep1PkgRepoPath))
      check lines.inLines(
        pkgWorkingCopyNeedsSyncingMsg(dep2PkgName, dep2PkgRepoPath))

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
  
  test "can sync out of sync develop dependencies":
    outOfSyncDepsTest(""):
      testDepsSync()

  test "can switch to another branch when syncing":
    const newBranchName = "new-branch"
    outOfSyncDepsTest(newBranchName):
      testDepsSync()
      check dep1PkgRepoPath.getCurrentBranch == newBranchName
      check dep2PkgRepoPath.getCurrentBranch == newBranchName

  test "cannot lock because the directory is not under version control":
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath,  mainPkgRepoPath,
                           @[dep1PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath)
      cd dep1PkgRepoPath:
        # Remove working copy from version control.
        removeDir(".git")
      cd mainPkgRepoPath:
        writeDevelopFile(developFileName, @[], @[dep1PkgRepoPath])
        let (output, exitCode) = execNimbleYes("lock")
        check exitCode == QuitFailure
        let
          error = ValidationError(kind: vekDirIsNotUnderVersionControl,
                                  path: dep1PkgRepoPath)
          errorMessage = getValidationErrorMessage(dep1PkgName, error)
        check output.processOutput.inLines(errorMessage)

  test "cannot lock because the working copy is not clean":
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath,  mainPkgRepoPath,
                           @[dep1PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath)
      cd dep1PkgRepoPath:
        # Modify the Nimble file to make the working copy not clean.
        discard initNewNimbleFile(dep1PkgRepoPath, @[dep2PkgName])
      cd mainPkgRepoPath:
        writeDevelopFile(developFileName, @[], @[dep1PkgRepoPath])
        let (output, exitCode) = execNimbleYes("lock")
        check exitCode == QuitFailure
        let
          error = ValidationError(kind: vekWorkingCopyIsNotClean,
                                  path: dep1PkgRepoPath)
          errorMessage = getValidationErrorMessage(dep1PkgName, error)
        check output.processOutput.inLines(errorMessage)

  test "cannot lock because the working copy has not pushed VCS revision":
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath,  mainPkgRepoPath,
                           @[dep1PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath)
      cd dep1PkgRepoPath:
        addAdditionalFileToTheRepo("dep1.nim", additionalFileContent)
      cd mainPkgRepoPath:
        writeDevelopFile(developFileName, @[], @[dep1PkgRepoPath])
        let (output, exitCode) = execNimbleYes("lock")
        check exitCode == QuitFailure
        let
          error = ValidationError(kind: vekVcsRevisionIsNotPushed,
                                  path: dep1PkgRepoPath)
          errorMessage = getValidationErrorMessage(dep1PkgName, error)
        check output.processOutput.inLines(errorMessage)

  test "cannot sync because the working copy needs lock":
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath,  mainPkgRepoPath,
                           @[dep1PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath)
      cd mainPkgRepoPath:
        writeDevelopFile(developFileName, @[], @[dep1PkgRepoPath])
        testLockFile(@[(dep1PkgName, dep1PkgRepoPath)], isNew = true)
      cd dep1PkgOriginRepoPath:
        addAdditionalFileToTheRepo("dep1.nim", additionalFileContent)
      cd dep1PkgRepoPath:
        pull("origin")
      cd mainPkgRepoPath:
        let (output, exitCode) = execNimbleYes("sync")
        check exitCode == QuitFailure
        let
          error = ValidationError(kind: vekWorkingCopyNeedsLock,
                                  path: dep1PkgRepoPath)
          errorMessage = getValidationErrorMessage(dep1PkgName, error)
        check output.processOutput.inLines(errorMessage)

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

  test "cannot sync because the working copy needs merge":
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath,  mainPkgRepoPath,
                           @[dep1PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath)

      cd mainPkgOriginRepoPath:
        testLockFile(@[(dep1PkgName, dep1PkgOriginRepoPath)], isNew = true)
        addFiles(lockFileName)
        commit("Add the lock file to version control")

      cd mainPkgRepoPath:
        # Pull the lock file.
        pull("origin")
        # Create develop file. On this command also a sync file will be
        # generated.
        let (_, exitCode) = execNimble("develop", &"-a:{dep1PkgRepoPath}")
        check exitCode == QuitSuccess

      addAdditionalFileAndPushToRemote(
        dep1PkgRepoPath, dep1PkgRemoteName, dep1PkgRemotePath,
        additionalFileContent)

      addAdditionalFileAndPushToRemote(
        dep1PkgOriginRepoPath, dep1PkgOriginRemoteName, dep1PkgOriginRemotePath,
        alternativeAdditionalFileContent)

      cd mainPkgOriginRepoPath:
        writeDevelopFile(developFileName, @[], @[dep1PkgOriginRepoPath])
        # Update the origin lock file.
        testLockFile(@[(dep1PkgName, dep1PkgOriginRepoPath)], isNew = false)
        addFiles(lockFileName)
        commit("Modify the lock file")

      cd mainPkgRepoPath:
        # Pull modified origin lock file. At this point the revisions in the
        # lock file, sync file and develop mode dependency working copy should
        # be different from one another.
        pull("origin")
        let (output, exitCode) = execNimbleYes("sync")
        check exitCode == QuitFailure
        let
          error = ValidationError(kind: vekWorkingCopyNeedsMerge,
                                  path: dep1PkgRepoPath)
          errorMessage = getValidationErrorMessage(dep1PkgName, error)
        check output.processOutput.inLines(errorMessage)

  test "check fails because the working copy needs sync":
     outOfSyncDepsTest(""):
       let (output, exitCode) = execNimble("check")
       check exitCode == QuitFailure
       let
         error = ValidationError(kind: vekWorkingCopyNeedsSync,
                                 path: dep1PkgRepoPath)
         errorMessage = getValidationErrorMessage(dep1PkgName, error)
       check output.processOutput.inLines(errorMessage)
