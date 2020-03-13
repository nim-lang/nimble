# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import tables, os, json

type
  Checksums* = object
    sha1*: string

  LockFileDependency* = object
    version*: string
    vcsRevision*: string
    url*: string
    downloadMethod*: string
    dependencies*: seq[string]
    checksum*: Checksums

  LockFileDependencies* = OrderedTable[string, LockFileDependency]

  LockFileJsonKeys = enum
    lfjkVersion = "version"
    lfjkPackages = "packages"

const
  lockFile = (name: "nimble.lockfile", version: "0.1.0")

proc lockFileExists*(dir: string): bool =
  fileExists(dir / lockFile.name)

proc writeLockFile*(fileName: string, packages: LockFileDependencies,
                    topologicallySortedOrder: seq[string]) =
  ## Saves lock file on the disk in topologically sorted order of the
  ## dependencies.

  let packagesJsonNode = newJObject()
  for packageName in topologicallySortedOrder:
    packagesJsonNode.add packageName, %packages[packageName]

  let mainJsonNode = %{
      $lfjkVersion: %lockFile.version,
      $lfjkPackages: packagesJsonNode
      }

  writeFile(fileName, mainJsonNode.pretty)

proc writeLockFile*(packages: LockFileDependencies,
                    topologicallySortedOrder: seq[string]) =
  writeLockFile(lockFile.name, packages, topologicallySortedOrder)

proc readLockFile*(filePath: string): LockFileDependencies =
  parseFile(filePath)[$lfjkPackages].to(result.typeof)

proc readLockFileInDir*(dir: string): LockFileDependencies =
  readLockFile(dir / lockFile.name)

proc getLockedDependencies*(dir: string): LockFileDependencies =
  if lockFileExists(dir):
    result = readLockFileInDir(dir)