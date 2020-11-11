# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import tables, os, json
import sha1hashes

type
  Checksums* = object
    sha1*: Sha1Hash

  LockFileDependency* = object
    version*: string
    vcsRevision*: Sha1Hash
    url*: string
    downloadMethod*: string
    dependencies*: seq[string]
    checksums*: Checksums

  LockFileDependencies* = OrderedTable[string, LockFileDependency]

  LockFileJsonKeys = enum
    lfjkVersion = "version"
    lfjkPackages = "packages"

const
  lockFileName* = "nimble.lockfile"
  lockFileVersion = "0.1.0"

proc lockFileExists*(dir: string): bool =
  fileExists(dir / lockFileName)

proc writeLockFile*(fileName: string, packages: LockFileDependencies,
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

proc writeLockFile*(packages: LockFileDependencies,
                    topologicallySortedOrder: seq[string]) =
  writeLockFile(lockFileName, packages, topologicallySortedOrder)

proc readLockFile*(filePath: string): LockFileDependencies =
  {.warning[UnsafeDefault]: off.}
  {.warning[ProveInit]: off.}
  result = parseFile(filePath)[$lfjkPackages].to(result.typeof)
  {.warning[ProveInit]: on.}
  {.warning[UnsafeDefault]: on.}

proc readLockFileInDir*(dir: string): LockFileDependencies =
  readLockFile(dir / lockFileName)

proc getLockedDependencies*(dir: string): LockFileDependencies =
  if lockFileExists(dir):
    result = readLockFileInDir(dir)
