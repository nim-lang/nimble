# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import sets, tables
import version, aliasthis, sha1hashes

type
  DownloadMethod* {.pure.} = enum
    git = "git", hg = "hg"

  Checksums* = object
    sha1*: Sha1Hash

  LockFileDep* = object
    version*: Version
    vcsRevision*: Sha1Hash
    url*: string
    downloadMethod*: DownloadMethod
    dependencies*: seq[string]
    checksums*: Checksums

  LockFileDeps* = OrderedTable[string, LockFileDep]

  PackageMetaData* = object
    url*: string
    vcsRevision*: Sha1Hash
    files*: seq[string]
    binaries*: seq[string]
    specialVersion*: Version

  PackageBasicInfo* = tuple
    name: string
    version: Version
    checksum: Sha1Hash

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
    lockedDeps*: LockFileDeps
    metaData*: PackageMetaData
    isLink*: bool

  Package* = object ## Definition of package from packages.json.
    # Required fields in a package.
    name*: string
    url*: string # Download location.
    license*: string
    downloadMethod*: DownloadMethod
    description*: string
    tags*: seq[string] # Even if empty, always a valid non nil seq. \
    # From here on, optional fields set to the empty string if not available.
    version*: Version
    dvcsTag*: string
    web*: string # Info url for humans.
    alias*: string ## A name of another package, that this package aliases.

  PackageDependenciesInfo* = tuple[deps: HashSet[PackageInfo], pkg: PackageInfo]

{.warning[UnsafeDefault]: off.}
{.warning[ProveInit]: off.}
aliasThis PackageInfo.metaData
{.warning[ProveInit]: on.}
aliasThis PackageInfo.basicInfo
{.warning[ProveInit]: on.}
{.warning[UnsafeDefault]: on.}
