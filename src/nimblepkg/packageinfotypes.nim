# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import std/[sets, tables, strformat, options, os]
import version, sha1hashes

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

  AllLockFileDeps* = Table[string, LockFileDeps]
    ## Base deps is stored with empty string key ""
    ## Other tasks have task name as key

  PackageMetaData* = object
    url*: string
    downloadMethod*: DownloadMethod
    vcsRevision*: Sha1Hash
    files*: seq[string]
    binaries*: seq[string]
    specialVersions*: HashSet[Version]
      # Special versions are aliases with which a single package can be
      # referred. For example a package can be versions `0.1.0`, `#head` and
      # `#master` at the same time.

  PackageBasicInfo* = tuple
    name: string
    version: Version
    checksum: Sha1Hash

  PackageInfoKind* = enum
    pikNone #No info
    pikMinimal #Minimal info, previous isMinimal
    pikRequires #Declarative parser only Minimal + requires (No vm involved)
    pikFull #Full info

  PackageInfo* = object
    myPath*: string ## The path of this .nimble file
    isNimScript*: bool ## Determines if this pkg info was read from a nims file
    infoKind*: PackageInfoKind
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
    taskRequires*: Table[string, seq[PkgTuple]]
    bin*: Table[string, string]
    binDir*: string
    srcDir*: string
    backend*: string
    foreignDeps*: seq[string]
    basicInfo*: PackageBasicInfo
    lockedDeps*: AllLockFileDeps
    metaData*: PackageMetaData
    isLink*: bool
    paths*: seq[string] 
    entryPoints*: seq[string] #useful for tools like the lsp.
    features*: Table[string, seq[PkgTuple]] #features requires defined in the nimble file. Declarative parser + SAT solver only.
    activeFeatures*: Table[PkgTuple, seq[string]] #features that dependencies of this package have activated. #i.e. requires package[feature1, feature2]
    testEntryPoint*: string ## The entry point for the test task.

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

  SolvedPackage* = object
    pkgName*: string
    version*: Version
    requirements*: seq[PkgTuple] 
    reverseDependencies*: seq[(string, Version)] 
    deps*: seq[SolvedPackage]
    reverseDeps*: seq[SolvedPackage]

  SATPass* = enum
    satNone
    satLockFile #From a lock file. SAT is not ran.
    satNimSelection #Declarative parser preferred. Fallback to VM parser if needed via bootstrapped nim
    satDone

  NimResolved* = object
    pkg*: Option[PackageInfo] #when none, we need to install it
    version*: Version

  BootstrapNim* = object
    nimResolved*: NimResolved
    allowToUse*: bool #Whether we are allowed to use the bootstrap nim. When parsing the initial pkglist we are not allow. 

  PackageMinimalInfo* = object
    name*: string
    version*: Version
    requires*: seq[PkgTuple]
    isRoot*: bool
    url*: string

  PackageVersions* = object
    pkgName*: string
    versions*: seq[PackageMinimalInfo]
    
  SATResult* = ref object
    rootPackage*: PackageInfo 
    pkgsToInstall*: seq[(string, Version)] #Packages to install
    solvedPkgs*: seq[SolvedPackage] #SAT solution
    pkgList*: HashSet[PackageInfo] #Original package list the user has installed
    output*: string
    pkgs*: HashSet[PackageInfo] #Packages from solution + new installs
    pass*: SATPass
    installedPkgs*: seq[PackageInfo] #Packages installed in the current pass
    buildPkgs*: seq[PackageInfo] #Packages that were built in the current pass
    declarativeParseFailed*: bool
    declarativeParserErrorLines*: seq[string]
    nimResolved*: NimResolved
    bootstrapNim*: BootstrapNim #The nim that we are going to use if we dont have a nim resolved yet and the declarative parser failed. Notice this is required to Atomic Parser fallback (not implemented)
    normalizedRequirements*: Table[string, string] #normalized -> old. Some packages are not published as nimble packages, we keep the url for installation.
    pkgVersionTable*: Table[string, PackageVersions]

proc `==`*(a, b: SolvedPackage): bool =
  a.pkgName == b.pkgName and
  a.version == b.version 
  
proc isMinimal*(pkg: PackageInfo): bool =
  pkg.infoKind == pikMinimal

const noTask* = "" # Means that noTask is being ran. Use this as key for base dependencies
var satProccesedPackages*: Option[HashSet[PackageInfo]] 
#Package name -> features. When a package requires a feature, it is added to this table. 
#For instance, if a dependency of a package requires the feature "feature1", it will be added to this table although the root package may not explicitly require it.
var globallyActiveFeatures {.threadvar.}: TableRef[string, seq[string]]

proc getGloballyActiveFeaturesTable(): TableRef[string, seq[string]] =
  if globallyActiveFeatures == nil:
    globallyActiveFeatures = newTable[string, seq[string]]()
  return globallyActiveFeatures

proc appendGloballyActiveFeatures*(pkgName: string, features: seq[string]) =
  if pkgName notin getGloballyActiveFeaturesTable():
    getGloballyActiveFeaturesTable()[pkgName] = features
  else:
    for feature in features:
      getGloballyActiveFeaturesTable()[pkgName].add(feature)

proc getGloballyActiveFeatures*(): seq[string] = 
  #returns features.{pkgName}.{feature}
    for pkgName, features in getGloballyActiveFeaturesTable():
      for feature in features:
        result.add(&"features.{pkgName}.{feature}")
  
proc initSATResult*(pass: SATPass): SATResult =
  SATResult(pkgsToInstall: @[], solvedPkgs: @[], output: "", pkgs: initHashSet[PackageInfo](), 
    pass: pass, installedPkgs: @[], declarativeParseFailed: false, declarativeParserErrorLines: @[],
    normalizedRequirements: initTable[string, string]()
    )

proc getNimbleFileDir*(pkgInfo: PackageInfo): string =
  pkgInfo.myPath.splitFile.dir

proc getNimPath*(pkgInfo: PackageInfo): string = 
  var binaryPath = "bin" / "nim"
  when defined(windows):
    binaryPath &= ".exe"      
  pkgInfo.getNimbleFileDir() / binaryPath

proc getNimBin*(nimResolved: NimResolved): string =
  assert nimResolved.pkg.isSome, "Nim is not resolved yet"
  return nimResolved.pkg.get.getNimPath().quoteShell
