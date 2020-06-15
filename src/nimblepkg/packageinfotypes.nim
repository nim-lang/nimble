# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import sets, tables
import version, lockfile, aliasthis

type
  PackageMetaDataBase* {.inheritable.} = object
    url*: string
    vcsRevision*: string
    files*: seq[string]
    binaries*: seq[string]

  PackageMetaDataV1* = object of PackageMetaDataBase
    isLink*: bool

  PackageMetaDataV2* = object of PackageMetaDataBase
    specialVersion*: string

  PackageMetaData* = object of PackageMetaDataBase
    isLink*: bool
    specialVersion*: string

  PackageBasicInfo* = tuple
    name: string
    version: string
    checksum: string

  PackageInfo* = object
    myPath*: string ## The path of this .nimble file
    isNimScript*: bool ## Determines if this pkg info was read from a nims file
    isMinimal*: bool
    isInstalled*: bool ## Determines if the pkg this info belongs to is installed
    nimbleTasks*: HashSet[string] ## All tasks defined in the Nimble file
    postHooks*: HashSet[string] ## Useful to know so that Nimble doesn't execHook unnecessarily
    preHooks*: HashSet[string]
    author*: string
    description*: string
    license*: string
    skipDirs*: seq[string]
    skipFiles*: seq[string]
    skipExt*: seq[string]
    installDirs*: seq[string]
    installFiles*: seq[string]
    installExt*: seq[string]
    requires*: seq[PkgTuple]
    bin*: Table[string, string]
    binDir*: string
    srcDir*: string
    backend*: string
    foreignDeps*: seq[string]
    basicInfo*: PackageBasicInfo
    lockedDependencies*: LockFileDependencies
    metaData*: PackageMetaData

  Package* = object ## Definition of package from packages.json.
    # Required fields in a package.
    name*: string
    url*: string # Download location.
    license*: string
    downloadMethod*: string
    description*: string
    tags*: seq[string] # Even if empty, always a valid non nil seq. \
    # From here on, optional fields set to the empty string if not available.
    version*: string
    dvcsTag*: string
    web*: string # Info url for humans.
    alias*: string ## A name of another package, that this package aliases.

  PackageDependenciesInfo* = tuple[deps: HashSet[PackageInfo], pkg: PackageInfo]

aliasThis PackageInfo.metaData
aliasThis PackageInfo.basicInfo
