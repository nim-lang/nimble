# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import sets, tables
import version, lockfile

type
  PackageInfo* = object
    myPath*: string ## The path of this .nimble file
    isNimScript*: bool ## Determines if this pkg info was read from a nims file
    isMinimal*: bool
    isInstalled*: bool ## Determines if the pkg this info belongs to is installed
    isLinked*: bool ## Determines if the pkg this info belongs to has been linked via `develop`
    nimbleTasks*: HashSet[string] ## All tasks defined in the Nimble file
    postHooks*: HashSet[string] ## Useful to know so that Nimble doesn't execHook unnecessarily
    preHooks*: HashSet[string]
    name*: string
    ## The version specified in the .nimble file.Assuming info is non-minimal,
    ## it will always be a non-special version such as '0.1.4'
    version*: string
    specialVersion*: string ## Either `myVersion` or a special version such as #head.
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
    lockedDependencies*: LockFileDependencies
    checksum*: string
    vcsRevision*: string ## This is git or hg commit sha1.

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

  MetaData* = object
    url*: string
    vcsRevision*: string

  NimbleLink* = object
    nimbleFilePath*: string
    packageDir*: string

  PackageBasicInfo* = tuple[name, version, checksum: string]
  PackageDependenciesInfo* = tuple[deps: HashSet[PackageInfo], pkg: PackageInfo]
  PackageInfoAndMetaData* = tuple[pkginfo: PackageInfo, meta: MetaData]
