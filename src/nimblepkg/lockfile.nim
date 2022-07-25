# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import tables, os, json
import version, sha1hashes, packageinfotypes

type
  LockFileJsonKeys* = enum
    lfjkVersion = "version"
    lfjkPackages = "packages"
    lfjkPkgVcsRevision = "vcsRevision"

const
  lockFileVersion = 1

proc initLockFileDep*: LockFileDep =
  result = LockFileDep(
    version: notSetVersion,
    vcsRevision: notSetSha1Hash,
    checksums: Checksums(sha1: notSetSha1Hash))

const
  notSetLockFileDep* = initLockFileDep()

proc writeLockFile*(fileName: string, packages: LockFileDeps,
                    topologicallySortedOrder: seq[string]) =
  ## Saves lock file on the disk in topologically sorted order of the
  ## dependencies.

  let packagesJsonNode = newJObject()
  for packageName in topologicallySortedOrder:
    packagesJsonNode.add packageName, %packages[packageName]

  let mainJsonNode = %{
      $lfjkVersion: %lockFileVersion,
      $lfjkPackages: packagesJsonNode
      }

  writeFile(fileName, mainJsonNode.pretty)

proc readLockFile*(filePath: string): LockFileDeps =
  {.warning[UnsafeDefault]: off.}
  {.warning[ProveInit]: off.}
  result = parseFile(filePath)[$lfjkPackages].to(result.typeof)
  {.warning[ProveInit]: on.}
  {.warning[UnsafeDefault]: on.}

proc getLockedDependencies*(lockFile: string): LockFileDeps =
  if lockFile.fileExists:
    result = lockFile.readLockFile
