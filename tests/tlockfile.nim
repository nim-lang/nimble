# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, strformat, json, strutils, sequtils, tables

import testscommon

import nimblepkg/displaymessages
import nimblepkg/sha1hashes
import nimblepkg/paths
import nimblepkg/vcstools

from nimblepkg/common import cd, dump, cdNewDir
from nimblepkg/tools import tryDoCmdEx, doCmdEx
from nimblepkg/packageinfotypes import DownloadMethod
from nimblepkg/version import PkgTuple, `$`
from nimblepkg/lockfile import LockFileJsonKeys
from nimblepkg/options import defaultLockFileName, defaultDevelopPath, initOptions
from nimblepkg/developfile import ValidationError, ValidationErrorKind,
  developFileName, getValidationErrorMessage
from nimblepkg/declarativeparser import extractRequiresInfo, getRequires

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
    # alternativeAdditionalFileContent  = "proc bar() =\n  echo \"bar\"\n"

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

  proc getRepoRevision(): string =
    result = tryDoCmdEx("git rev-parse HEAD").replace("\n", "")

  proc getRevision(dep: string, lockFileName = defaultLockFileName): string =
    result = lockFileName.readFile.parseJson{$lfjkPackages}{dep}{$lfjkPkgVcsRevision}.str

  proc addAdditionalFileAndPushToRemote(
      repoPath, remoteName, remotePath, fileContent: string) {.used.} =
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
        addFiles(defaultLockFileName)
        commit("Add the lock file to version control")

      cd mainPkgRepoPath:
        pull("origin")
        let (_ {.used.}, devCmdExitCode) = execNimble("develop",
          &"-a:{dep1PkgRepoPath}", &"-a:{dep2PkgRepoPath}")
        check devCmdExitCode == QuitSuccess
        `body`

  test "can generate lock file":
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath, mainPkgRepoPath,
                           @[dep1PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath)
      cd mainPkgRepoPath:
        testLockFile(@[(dep1PkgName, dep1PkgRepoPath)], isNew = true)

  test "can generate overridden lock file":
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath, mainPkgRepoPath,
                           @[dep1PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath)
      cd mainPkgRepoPath:
        testLockFile(@[(dep1PkgName, dep1PkgRepoPath)],
                     isNew = true,
                     lockFileName = "changed-lock-file.lock")

  test "can generate overridden lock file absolute path":
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath, mainPkgRepoPath,
                           @[dep1PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath)
      cd mainPkgRepoPath:
        testLockFile(@[(dep1PkgName, dep1PkgRepoPath)],
                     isNew = true,
                     lockFileName = mainPkgRepoPath / "changed-lock-file.lock")

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
          invalidDevelopDependenciesVersionsMsg(errors)) or
          output.processOutput.inLines(
          "Downloaded package's version does not satisfy requested version range: wanted > 0.1.0 got 0.1.0.")

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

  # test "can update already existing lock file":
  #   cleanUp()
  #   withPkgListFile:
  #     initNewNimblePackage(mainPkgOriginRepoPath, mainPkgRepoPath,
  #                          @[dep1PkgName])
  #     initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath)
  #     initNewNimblePackage(dep2PkgOriginRepoPath, dep2PkgRepoPath)

  #     cd mainPkgRepoPath:
  #       testLockFile(@[(dep1PkgName, dep1PkgRepoPath)], isNew = true)
  #       # Add additional dependency to the nimble file.
  #       let mainPkgNimbleFileContent = newNimbleFileContent(mainPkgName,
  #         nimbleFileTemplate, @[dep1PkgName, dep2PkgName])
  #       writeFile(mainPkgNimbleFileName, mainPkgNimbleFileContent)
  #       # Make first dependency to be in develop mode.
  #       writeDevelopFile(developFileName, @[], @[dep1PkgRepoPath, dep2PkgRepoPath])

  #     cd dep1PkgOriginRepoPath:
  #       # Add additional file to the first dependency, commit and push.
  #       addAdditionalFileToTheRepo("dep1.nim", additionalFileContent)

  #     cd dep1PkgRepoPath:
  #       pull("origin")

  #     cd mainPkgRepoPath:
  #       # On second lock the first package revision is updated and a second
  #       # package is added as dependency.
  #       testLockFile(@[(dep1PkgName, dep1PkgRepoPath),
  #                      (dep2PkgName, dep2PkgRepoPath)],
  #                    isNew = false)

  test "can list out of sync develop dependencies":
    outOfSyncDepsTest(""):
      let (output, exitCode) = execNimbleYes("sync", "--list-only")
      check exitCode == QuitSuccess
      let lines = output.processOutput
      check lines.inLines(
        pkgWorkingCopyNeedsSyncingMsg(dep1PkgName, dep1PkgRepoPath))
      check lines.inLines(
        pkgWorkingCopyNeedsSyncingMsg(dep2PkgName, dep2PkgRepoPath))

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
        # Add a file to make the working copy not clean.
        writeFile("dirty", "dirty")
        addFiles("dirty")
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

  test "check fails because the working copy needs sync":
     outOfSyncDepsTest(""):
       let (output, exitCode) = execNimble("check")
       check exitCode == QuitFailure
       let
         error = ValidationError(kind: vekWorkingCopyNeedsSync,
                                 path: dep1PkgRepoPath)
         errorMessage = getValidationErrorMessage(dep1PkgName, error)
       check output.processOutput.inLines(errorMessage)

  test "can lock with dirty non-deps in develop file":
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath, mainPkgRepoPath,
                           @[dep1PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath)
      initNewNimblePackage(dep2PkgOriginRepoPath, dep2PkgRepoPath)

      cd dep2PkgRepoPath:
        # make dep2 dirty
        writeFile("dirty", "dirty")
        addFiles("dirty")


      cd mainPkgRepoPath:
        # make main dirty
        writeFile("dirty", "dirty")
        addFiles("dirty")
        writeDevelopFile(developFileName, @[],
                         @[dep2PkgRepoPath, mainPkgRepoPath, dep1PkgRepoPath])
        testLockFile(@[(dep1PkgName, dep1PkgRepoPath)], isNew = true)

  test "can sync ignoring deps not present in lock file even if they are in develop file":
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath, mainPkgRepoPath,
                           @[dep1PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath)
      cd mainPkgRepoPath:
        testLockFile(@[(dep1PkgName, dep1PkgRepoPath)], isNew = true)
        writeDevelopFile(developFileName, @[], @[dep1PkgRepoPath, mainPkgOriginRepoPath])
        let (_, exitCode) = execNimbleYes("--debug", "--verbose", "sync")
        check exitCode == QuitSuccess

  #TODO we are going to introduce a new way to lock nim, this is too convoluted
  # test "can generate lock file for nim as dep":
  #   cleanUp()
  #   let nimDir = defaultDevelopPath / "Nim"
  #   cd "nimdep":
  #     removeFile "nimble.develop"
  #     removeFile "nimble.lock"
  #     removeDir nimDir
  #     check execNimbleYes("-y", "develop", "nim").exitCode == QuitSuccess
  #     cd nimDir:
  #       let (_, exitCode) = execNimbleYes("-y", "install")
  #       check exitCode == QuitSuccess

  #     # check if the compiler version will be used when doing build
  #     testLockFile(@[("nim", nimDir)], isNew = true)
  #     removeFile "nimble.develop"
  #     removeDir nimDir

  #     let (output, exitCodeInstall) = execNimbleYes("-y", "build")
  #     check exitCodeInstall == QuitSuccess
  #     let usingNim = when defined(Windows): "nim.exe for compilation" else: "bin/nim for compilation"
  #     check output.contains(usingNim)

  #     # check the nim version
  #     let (outputVersion, _) = execNimble("version")
  #     check outputVersion.contains(getRevision("nim"))

  #     let (outputGlobalNim, exitCodeGlobalNim) = execNimbleYes("-y", "--use-system-nim", "build")
  #     check exitCodeGlobalNim == QuitSuccess
  #     check not outputGlobalNim.contains(usingNim)

  test "can install task level deps when dep has subdeb":
    cleanUp()
    cd "lockfile-subdep":
      check execNimbleYes("test").exitCode == QuitSuccess

  test "can upgrade a dependency.":
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath, mainPkgRepoPath,
                           @[dep1PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath)

      cd mainPkgRepoPath:
        check execNimbleYes("lock").exitCode == QuitSuccess

      cd dep1PkgOriginRepoPath:
        addAdditionalFileToTheRepo("dep1.nim", "echo 42")
        let newRevision = getRepoRevision()
        cd mainPkgRepoPath:
          check newRevision != getRevision(dep1PkgName)
          let res = execNimbleYes("upgrade", fmt "{dep1PkgName}@#{newRevision}")
          check newRevision == getRevision(dep1PkgName)
          check res.exitCode == QuitSuccess

  test "can upgrade: the new version of the package has a new dep":
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath, mainPkgRepoPath, @[dep1PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath)
      initNewNimblePackage(dep2PkgOriginRepoPath, dep2PkgRepoPath)

      cd mainPkgRepoPath:
        check execNimbleYes("lock").exitCode == QuitSuccess

      cd dep1PkgOriginRepoPath:
        let nimbleFile = initNewNimbleFile(dep1PkgOriginRepoPath, @[dep2PkgName])
        addFiles(nimbleFile)
        commit("Add dependency to pkg2")

        let newRevision = getRepoRevision()
        cd mainPkgRepoPath:
          let res = execNimbleYes("upgrade", fmt "{dep1PkgName}@#{newRevision}")
          check newRevision == getRevision(dep1PkgName)
          check res.exitCode == QuitSuccess         
          
          testLockedVcsRevisions(@[(dep1PkgName, dep1PkgOriginRepoPath),
                                   (dep2PkgName, dep2PkgOriginRepoPath)])

  test "can upgrade: upgrade minimal set of deps":
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath, mainPkgRepoPath,
                           @[dep1PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath, @[dep2PkgName])
      initNewNimblePackage(dep2PkgOriginRepoPath, dep2PkgRepoPath)

      cd mainPkgRepoPath:
        check execNimbleYes("lock").exitCode == QuitSuccess

      cd dep1PkgOriginRepoPath:
        addAdditionalFileToTheRepo("dep1.nim", "echo 1")

      cd dep2PkgOriginRepoPath:
        let first =  getRepoRevision()
        addAdditionalFileToTheRepo("dep2.nim", "echo 2")
        let second = getRepoRevision()

        check execNimbleYes("install").exitCode == QuitSuccess

        cd mainPkgRepoPath:
          # verify that it won't upgrade version first
          check execNimbleYes("upgrade", fmt "{dep1PkgName}@#HEAD").exitCode == QuitSuccess
          check getRevision(dep2PkgName) == first

          check execNimbleYes("upgrade", fmt "{dep2PkgName}@#{second}").exitCode == QuitSuccess
          check getRevision(dep2PkgName) == second

          # # verify that it won't upgrade version second
          check execNimbleYes("upgrade", fmt "{dep1PkgName}@#HEAD").exitCode == QuitSuccess
          check getRevision(dep2PkgName) == second

  test "can upgrade: the new version of the package with removed dep":
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath, mainPkgRepoPath, @[dep1PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath, @[dep2PkgName])
      initNewNimblePackage(dep2PkgOriginRepoPath, dep2PkgRepoPath)

      cd mainPkgRepoPath:
        check execNimbleYes("lock").exitCode == QuitSuccess

      cd dep1PkgOriginRepoPath:
        let nimbleFile = initNewNimbleFile(dep1PkgOriginRepoPath)
        addFiles(nimbleFile)
        commit("Remove pkg2 dep")

        cd mainPkgRepoPath:
          let res = execNimbleYes("upgrade", fmt "{dep1PkgName}@#HEAD")
          check res.exitCode == QuitSuccess
          let pkgs = defaultLockFileName.readFile.parseJson{$lfjkPackages}.keys.toSeq
          check "dep1" in pkgs
          check "dep2" notin pkgs

  test "can lock with --developFile argument":
    cleanUp()
    withPkgListFile:
      initNewNimblePackage(mainPkgOriginRepoPath,  mainPkgRepoPath,
                           @[dep1PkgName])
      initNewNimblePackage(dep1PkgOriginRepoPath, dep1PkgRepoPath)
      cd mainPkgRepoPath:
        writeDevelopFile(developFileName, @[], @[dep1PkgRepoPath])
        moveFile("nimble.develop", "other-name.develop")

        let exitCode = execNimbleYes("lock", "--developFile=" & "other-name.develop").exitCode
        check exitCode == QuitSuccess

  test "Forge alias is generated inside lockfile":
    cleanup()
    withPkgListFile:
      cd "forgealias001":
        removeFile defaultLockFileName

        let (_, exitCode) = execNimbleYes("lock")
        check exitCode == QuitSuccess

        # Check the dependency appears in the lock file, and its expanded
        check defaultLockFileName.fileExists
        let json = defaultLockFileName.readFile.parseJson
        check json{$lfjkPackages, "librng", "url"}.str == "https://github.com/xTrayambak/librng"

  test "nim version from requires is used in lock file":
    # Test that when a package requires a specific nim version (e.g., nim == 2.0.8),
    # the lock file correctly contains that nim version, not the system nim.
    # This tests the fix for nim requirements being filtered during SAT nim selection.
    # Uses langserver as it has many dependencies and moving pieces.
    let langserverDir = tempDir / "nimlangserver"

    # Clean up any previous test
    if dirExists(langserverDir):
      removeDir(langserverDir)
    createDir(tempDir)

    # Clone langserver
    let (_, cloneExitCode) =
        doCmdEx(&"git clone --depth 1 https://github.com/nim-lang/langserver.git {langserverDir}")
    check cloneExitCode == QuitSuccess

    cd langserverDir:
      var options = initOptions()
      let nimbleInfo = extractRequiresInfo("nimlangserver.nimble", options)
      var activeFeatures = initTable[PkgTuple, seq[string]]()
      let requires = nimbleInfo.getRequires(activeFeatures)
      let nimReq = requires.filterIt(it.name == "nim")
      check nimReq.len > 0
      let expectedNimVersion = $nimReq[0].ver

      # Remove existing lock file to force regeneration
      removeFile defaultLockFileName
      let (_, lockExitCode) = execNimbleYes("lock")
      check lockExitCode == QuitSuccess

      check defaultLockFileName.fileExists
      let lockJson = defaultLockFileName.readFile.parseJson
      let nimVersion = lockJson{$lfjkPackages, "nim", "version"}.getStr
      check nimVersion == expectedNimVersion

  test "lock file content is preserved when running nimble lock on existing lock file":
    # Test that running `nimble lock` on an existing lock file preserves:
    # 1. The dependencies arrays (not emptied)
    # 2. The package ordering (nim not moved to first line)
    # This tests fixes for issues: "Missing deps in lock file" and "Nim dependency moved to first line"
    let langserverDir = tempDir / "nimlangserver_preserve_test"

    # Clean up any previous test
    if dirExists(langserverDir):
      removeDir(langserverDir)
    createDir(tempDir)

    # Clone langserver which has an existing lock file
    let (_, cloneExitCode) =
        doCmdEx(&"git clone --depth 1 https://github.com/nim-lang/langserver.git {langserverDir}")
    check cloneExitCode == QuitSuccess

    cd langserverDir:
      check defaultLockFileName.fileExists
      let originalLockJson = defaultLockFileName.readFile.parseJson

      # 1. Find a package with dependencies to verify they're preserved
      var pkgWithDeps = ""
      var expectedDeps: seq[string] = @[]
      for pkgName, pkgData in originalLockJson{$lfjkPackages}.pairs:
        if pkgName == "nim":
          continue  # Skip nim as it typically has no dependencies
        let deps = pkgData{"dependencies"}
        if deps != nil and deps.kind == JArray and deps.len > 0:
          pkgWithDeps = pkgName
          for dep in deps:
            expectedDeps.add(dep.getStr)
          break
      check pkgWithDeps != ""
      check expectedDeps.len > 0

      # 2. Get original package order and nim's position
      var originalOrder: seq[string] = @[]
      for pkgName, _ in originalLockJson{$lfjkPackages}.pairs:
        originalOrder.add(pkgName)
      let originalNimIndex = originalOrder.find("nim")
      check originalNimIndex >= 0  # nim should be in the lock file

      # Run nimble lock
      let (_, lockExitCode) = execNimbleYes("lock")
      check lockExitCode == QuitSuccess

      let newLockJson = defaultLockFileName.readFile.parseJson

      # Verify 1: dependencies are preserved
      let newDeps = newLockJson{$lfjkPackages, pkgWithDeps, "dependencies"}
      check newDeps != nil
      check newDeps.kind == JArray
      check newDeps.len == expectedDeps.len
      for dep in expectedDeps:
        check newDeps.elems.anyIt(it.getStr == dep)

      # Verify 2: nim position is preserved (not moved to first)
      var newOrder: seq[string] = @[]
      for pkgName, _ in newLockJson{$lfjkPackages}.pairs:
        newOrder.add(pkgName)
      let newNimIndex = newOrder.find("nim")
      check newNimIndex >= 0  # nim should still be in the lock file
      if originalNimIndex > 0:
        check newNimIndex > 0  # nim should not be moved to first position

  test "installs correct vcsRevision from lock file":
    # Test that when installing from a lock file, the exact vcsRevision
    # specified in the lock file is installed, not just a matching version.
    let testDir = tempDir / "vcsrevision_test"

    # Clean up any previous test
    if dirExists(testDir):
      removeDir(testDir)
    createDir(testDir)

    cd testDir:
      # Create a minimal project with a lock file that specifies exact vcsRevisions
      writeFile("vcsrevision_test.nimble", """
version       = "0.1.0"
author        = "Test"
description   = "Test vcsRevision from lock file"
license       = "MIT"
requires "nim >= 2.0.0"
requires "checksums >= 0.1.0"
""")

      # Create a lock file with specific vcsRevision
      # Using checksums package which is small and has tags
      # The vcsRevision is the actual commit for v0.1.0 tag
      let lockContent = """{
  "version": 2,
  "packages": {
    "checksums": {
      "version": "0.1.0",
      "vcsRevision": "7ff0b762332d2591bbeb65df9bb86d52ea44ec01",
      "url": "https://github.com/nim-lang/checksums",
      "downloadMethod": "git",
      "dependencies": [],
      "checksums": {
        "sha1": "7ff0b762332d2591bbeb65df9bb86d52ea44ec01"
      }
    }
  },
  "tasks": {}
}"""
      writeFile(defaultLockFileName, lockContent)

      # Remove any existing checksums package to force fresh install
      let pkgsDir = installDir / "pkgs2"
      for kind, path in walkDir(pkgsDir):
        if kind == pcDir and path.extractFilename.startsWith("checksums-"):
          removeDir(path)

      # Run nimble setup which will install from lock file
      let (_, exitCode) = execNimbleYes("setup")
      check exitCode == QuitSuccess

      # Find the installed checksums package
      var installedDir = ""
      for kind, path in walkDir(pkgsDir):
        if kind == pcDir and path.extractFilename.startsWith("checksums-"):
          installedDir = path
          break

      check installedDir != ""

      # Read the nimblemeta.json to verify the correct vcsRevision was installed
      let metaFile = installedDir / "nimblemeta.json"
      check fileExists(metaFile)
      let metaJson = parseFile(metaFile)
      let installedVcsRevision = metaJson{"metaData", "vcsRevision"}.getStr

      # Verify the vcsRevision matches what was in the lock file
      check installedVcsRevision == "7ff0b762332d2591bbeb65df9bb86d52ea44ec01"

    # Cleanup
    removeDir(testDir)

  test "nimble.paths contains only one version per package":
    # This test verifies that when using a lock file, nimble.paths doesn't contain
    # multiple versions of the same package. This was a bug where satResult.pkgs
    # wasn't cleared before processing the lock file, causing old versions to remain.
    #
    # The bug scenario:
    # 1. Project requires "checksums >= 0.1.0"
    # 2. Lock file specifies checksums 0.1.0
    # 3. SAT solver runs and might pick 0.2.0 (latest satisfying version)
    # 4. Lock file processing should clear SAT result and use 0.1.0 only
    # 5. Without the fix, both 0.1.0 and 0.2.0 could appear in nimble.paths

    let testDir = tempDir / "single_version_paths_test"

    # Clean up any previous test
    if dirExists(testDir):
      removeDir(testDir)
    createDir(testDir)

    cd testDir:
      # Create a minimal project
      writeFile("single_version_test.nimble", """
version       = "0.1.0"
author        = "Test"
description   = "Test single version in paths"
license       = "MIT"
requires "nim >= 2.0.0"
requires "checksums >= 0.1.0"
""")

      # Create a lock file specifying an OLDER version (0.1.0)
      # The SAT solver would normally pick the latest (0.2.x) but lock file pins to 0.1.0
      let lockContent = """{
  "version": 2,
  "packages": {
    "checksums": {
      "version": "0.1.0",
      "vcsRevision": "7ff0b762332d2591bbeb65df9bb86d52ea44ec01",
      "url": "https://github.com/nim-lang/checksums",
      "downloadMethod": "git",
      "dependencies": [],
      "checksums": {
        "sha1": "7ff0b762332d2591bbeb65df9bb86d52ea44ec01"
      }
    }
  },
  "tasks": {}
}"""
      writeFile(defaultLockFileName, lockContent)

      let pkgsDir = installDir / "pkgs2"

      # Remove any existing checksums packages first
      for kind, path in walkDir(pkgsDir):
        if kind == pcDir and path.extractFilename.startsWith("checksums-"):
          removeDir(path)

      # First, install the LATEST version without using lock file
      # This simulates having a newer version installed
      removeFile(defaultLockFileName)  # Temporarily remove lock file
      let (_, buildExitCode) = execNimbleYes("setup")
      check buildExitCode == QuitSuccess

      # Check what version was installed (should be latest, like 0.2.x)
      var installedVersionWithoutLock = ""
      for kind, path in walkDir(pkgsDir):
        if kind == pcDir and path.extractFilename.startsWith("checksums-"):
          let afterChecksums = path.extractFilename[10 .. ^1]  # skip "checksums-"
          let dashPos = afterChecksums.find("-")
          if dashPos > 0:
            installedVersionWithoutLock = afterChecksums[0 ..< dashPos]
            break

      # Now restore the lock file and run setup again
      # This is where the bug manifests - both versions could appear
      writeFile(defaultLockFileName, lockContent)
      let (_, setupExitCode) = execNimbleYes("setup")
      check setupExitCode == QuitSuccess

      # Read nimble.paths and check for duplicate package versions
      let pathsFile = "nimble.paths"
      check fileExists(pathsFile)
      let pathsContent = readFile(pathsFile)

      # Extract version numbers from checksums paths
      # A package may have multiple paths (root and src), but all should be same version
      var checksumsVersions: seq[string] = @[]
      for line in pathsContent.splitLines():
        if "checksums-" in line and line.startsWith("--path:"):
          # Extract version from path like "checksums-0.1.0-hash"
          let pathStart = line.find("checksums-")
          if pathStart >= 0:
            let afterChecksums = line[pathStart + 10 .. ^1]  # skip "checksums-"
            let dashPos = afterChecksums.find("-")
            if dashPos > 0:
              let version = afterChecksums[0 ..< dashPos]
              if version notin checksumsVersions:
                checksumsVersions.add(version)

      # There should be exactly one VERSION of checksums (though possibly multiple paths)
      # The bug would cause both 0.1.0 and 0.2.x to appear
      check checksumsVersions.len == 1

      # And it should be the version from the lock file (0.1.0), not the latest
      check checksumsVersions[0] == "0.1.0"

    # Cleanup
    removeDir(testDir)
