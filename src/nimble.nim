# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import os, tables, strtabs, json, browsers, algorithm, sets, uri, sugar, sequtils, osproc,
       strformat

import std/options as std_opt

import strutils except toLower
from unicode import toLower
import sat/sat
import nimblepkg/packageinfotypes, nimblepkg/packageinfo, nimblepkg/version,
       nimblepkg/tools, nimblepkg/download, nimblepkg/common,
       nimblepkg/publish, nimblepkg/options, nimblepkg/packageparser,
       nimblepkg/cli, nimblepkg/packageinstaller, nimblepkg/reversedeps,
       nimblepkg/nimscriptexecutor, nimblepkg/init, nimblepkg/vcstools,
       nimblepkg/checksums, nimblepkg/topologicalsort, nimblepkg/lockfile,
       nimblepkg/nimscriptwrapper, nimblepkg/developfile, nimblepkg/paths,
       nimblepkg/nimbledatafile, nimblepkg/packagemetadatafile,
       nimblepkg/displaymessages, nimblepkg/sha1hashes, nimblepkg/syncfile,
       nimblepkg/deps, nimblepkg/nimblesat, nimblepkg/nimenv,
       nimblepkg/downloadnim, nimblepkg/declarativeparser,
       nimblepkg/vnext

const
  nimblePathsFileName* = "nimble.paths"
  nimbleConfigFileName* = "config.nims"
  nimbledepsFolderName = "nimbledeps"
  gitIgnoreFileName = ".gitignore"
  hgIgnoreFileName = ".hgignore"
  nimblePathsEnv = "__NIMBLE_PATHS"
  separator = when defined(windows): ";" else: ":"

proc initPkgList(pkgInfo: PackageInfo, options: Options): seq[PackageInfo] =
  let
    installedPkgs = getInstalledPkgsMin(options.getPkgsDir(), options)
    developPkgs = processDevelopDependencies(pkgInfo, options)
  
  result = concat(installedPkgs, developPkgs)

proc install(packages: seq[PkgTuple], options: Options,
             doPrompt, first, fromLockFile: bool,
             preferredPackages: seq[PackageInfo] = @[]): PackageDependenciesInfo

proc checkSatisfied(options: Options, dependencies: seq[PackageInfo]) =
  ## Check if two packages of the same name (but different version) are listed
  ## in the path. Throws error if it fails
  var pkgsInPath: Table[string, Version]
  for pkgInfo in dependencies:
    let currentVer = pkgInfo.getConcreteVersion(options)
    if pkgsInPath.hasKey(pkgInfo.basicInfo.name) and
       pkgsInPath[pkgInfo.basicInfo.name] != currentVer:
      raise nimbleError(
        "Cannot satisfy the dependency on $1 $2 and $1 $3" %
          [pkgInfo.basicInfo.name, $currentVer, $pkgsInPath[pkgInfo.basicInfo.name]])
    pkgsInPath[pkgInfo.basicInfo.name] = currentVer

proc displayUsingSpecialVersionWarning(solvedPkgs: seq[SolvedPackage], options: Options) =
  var messages = newSeq[string]()
  for pkg in solvedPkgs:
    for req in pkg.requirements:
      if req.ver.isSpecial:
        nimblesat.addUnique(messages, &"Package {pkg.pkgName} lists an underspecified version of {req.name} ({req.ver})")
  
  for msg in messages:
    displayWarning(msg)

proc activateSolvedPkgFeatures(solvedPkgs: seq[SolvedPackage], allPkgsInfo: seq[PackageInfo], options: Options) =
  if not options.useDeclarativeParser:
    return
  for solved in solvedPkgs:
    var pkg = getPackageInfo(solved.pkgName, allPkgsInfo, some solved.version)
    if pkg.isNone: 
      displayError &"PackageInfo {solved.pkgName} not found", priority = LowPriority
      continue
    if pkg.get.activeFeatures.len == 0:      
      pkg = some pkg.get.toRequiresInfo(options)
    for pkgTuple, activeFeatures in pkg.get.activeFeatures:
      let pkgWithFeature = getPackageInfo(pkgTuple[0], allPkgsInfo, none(Version))
      if pkgWithFeature.isNone:
        displayError &"Active PackageInfo {pkgTuple[0]} not found", priority = HighPriority
        continue
      appendGloballyActiveFeatures(pkgWithFeature.get.basicInfo.name, activeFeatures)

proc addReverseDeps*(solvedPkgs: seq[SolvedPackage], allPkgsInfo: seq[PackageInfo], options: Options) = 
  for pkg in solvedPkgs:
    if pkg.pkgName.isNim: continue 
    let solvedPkg = getPackageInfo(pkg.pkgName, allPkgsInfo, some pkg.version)
    if solvedPkg.isNone:
      continue
    for (reverseDepName, ver) in pkg.reverseDependencies:
      var reverseDep = getPackageInfo(reverseDepName, allPkgsInfo, some ver)
      if reverseDep.isNone: 
        continue
      if reverseDepName.isNim: continue #Nim is already handled. 
      if reverseDep.get.myPath.parentDir.developFileExists:
        reverseDep.get.isLink = true
      addRevDep(options.nimbleData, solvedPkg.get.basicInfo, reverseDep.get)

proc processFreeDependenciesSAT(rootPkgInfo: PackageInfo, options: Options): HashSet[PackageInfo] = 
  if rootPkgInfo.basicInfo.name.isNim: #Nim has no deps
    return initHashSet[PackageInfo]()  
  if satProccesedPackages.isSome:
    return satProccesedPackages.get
  var solvedPkgs = newSeq[SolvedPackage]()
  var pkgsToInstall: seq[(string, Version)] = @[]
  var rootPkgInfo = rootPkgInfo
  if options.useDeclarativeParser:
    rootPkgInfo = rootPkgInfo.toRequiresInfo(options)
    # displayInfo(&"Features: options: {options.features} pkg: {rootPkgInfo.features}", HighPriority)
    for feature in options.features:
      if feature in rootPkgInfo.features:
        rootPkgInfo.requires &= rootPkgInfo.features[feature]
    for pkgName, activeFeatures in rootPkgInfo.activeFeatures:
      appendGloballyActiveFeatures(pkgName[0], activeFeatures)
    
    #If root is a development package, we need to activate it as well:
    if rootPkgInfo.isDevelopment(options) and "dev" in rootPkgInfo.features:
      rootPkgInfo.requires &= rootPkgInfo.features["dev"]
      appendGloballyActiveFeatures(rootPkgInfo.basicInfo.name, @["dev"])
  rootPkgInfo.requires &= options.extraRequires
  var pkgList = initPkgList(rootPkgInfo, options)
  if options.useDeclarativeParser:
    pkgList = pkgList.mapIt(it.toRequiresInfo(options))
  else:
    pkgList = pkgList.mapIt(it.toFullInfo(options))
  var allPkgsInfo: seq[PackageInfo] = pkgList & rootPkgInfo
  #Remove from the pkglist the packages that exists in lock file and has a different vcsRevision
  var upgradeVersions = initTable[string, VersionRange]()
  var isUpgrading = options.action.typ == actionUpgrade
  if isUpgrading:
    for pkg in options.action.packages:
      upgradeVersions[pkg.name] = pkg.ver
    pkgList = pkgList.filterIt(it.basicInfo.name notin upgradeVersions)

  var toRemoveFromLocked = newSeq[PackageInfo]()
  if rootPkgInfo.lockedDeps.hasKey(""):
    for name, lockedPkg in rootPkgInfo.lockedDeps[""]:
      for pkg in pkgList:
        if name notin upgradeVersions and name == pkg.basicInfo.name and
        (isUpgrading and lockedPkg.vcsRevision != pkg.metaData.vcsRevision or 
          not isUpgrading and lockedPkg.vcsRevision == pkg.metaData.vcsRevision):
              toRemoveFromLocked.add pkg

  var systemNimCompatible = options.nimBin.isSome
  result = solveLocalPackages(rootPkgInfo, pkgList, solvedPkgs, systemNimCompatible,  options)
  if solvedPkgs.len > 0: 
    displaySatisfiedMsg(solvedPkgs, pkgsToInstall, options)
    addReverseDeps(solvedPkgs, allPkgsInfo, options)
    activateSolvedPkgFeatures(solvedPkgs, allPkgsInfo, options)
    for pkg in allPkgsInfo:
      if pkg.basicInfo.name.isNim and systemNimCompatible:
        continue #Dont add nim from the solution as we will use system nim
      result.incl pkg
    for nonLocked in toRemoveFromLocked:
      #only remove if the vcsRevision is different
      var toRemove: HashSet[PackageInfo] = initHashSet[PackageInfo]()
      for pkg in result:
        if pkg.basicInfo.name == nonLocked.basicInfo.name and pkg.metaData.vcsRevision != nonLocked.metaData.vcsRevision:
          toRemove.incl nonLocked
      result.excl toRemove
    result = 
      result.toSeq
      .deleteStaleDependencies(rootPkgInfo, options)
      .toHashSet
    satProccesedPackages = some result
    return result
  var output = ""
  result = solvePackages(rootPkgInfo, pkgList, pkgsToInstall, options, output, solvedPkgs)
  displaySatisfiedMsg(solvedPkgs, pkgsToInstall, options)
  displayUsingSpecialVersionWarning(solvedPkgs, options)
  var solved = solvedPkgs.len > 0 #A pgk can be solved and still dont return a set of PackageInfo
  for (name, ver) in pkgsToInstall:
    var versionRange = ver.toVersionRange
    if name in upgradeVersions:
      versionRange = upgradeVersions[name]
    let resolvedDep = ((name: name, ver: versionRange)).resolveAlias(options)
    let (packages, _) = install(@[resolvedDep], options,
      doPrompt = false, first = false, fromLockFile = false, preferredPackages = result.toSeq())
    for pkg in packages:
      if pkg in result:
        # If the result already contains the newly tried to install package
        # we had to merge its special versions set into the set of the old
        # one.
        result[pkg].metaData.specialVersions.incl(
          pkg.metaData.specialVersions)
      else:
        result.incl pkg

  for pkg in result:
    allPkgsInfo.add pkg
  addReverseDeps(solvedPkgs, allPkgsInfo, options)
  activateSolvedPkgFeatures(solvedPkgs, allPkgsInfo, options)


  for nonLocked in toRemoveFromLocked:
    result.excl nonLocked

  result = deleteStaleDependencies(result.toSeq, rootPkgInfo, options).toHashSet  
  satProccesedPackages = some result

  if not solved:
    display("Error", output, Error, priority = HighPriority)
    raise nimbleError("Unsatisfiable dependencies")



proc getNimBin*(pkgInfo: PackageInfo, options: Options): string =
  proc getNimPath(pkgInfo: PackageInfo): string = 
    var binaryPath = "bin" / "nim"
    when defined(windows):
      binaryPath &= ".exe"      
    pkgInfo.getNimbleFileDir() / binaryPath

  if pkgInfo.basicInfo.name.isNim:
    return getNimPath(pkgInfo)
  else: 
    if not options.isLegacy:
      assert options.satResult.nimResolved.pkg.isSome, "Nim is not resolved yet"
      return getNimPath(options.satResult.nimResolved.pkg.get)
    if options.useSatSolver and not options.useSystemNim:
      #Try to first use nim from the solved packages
      #TODO add the solved packages to the options (we need to remove the legacy solver first otherwise it will be messy)
      #If there is not nimble file in the current package we are trying to install, means we are installing a binary in the global directory
      #Sometimes, like when installing a package globally without being in a nimble package, sat is not ran at this point. 
      #We need to run it here to get the correct nim bin
      #In the future, when the declarative parser is the default, we will run for getting Nim much early (right now we need a nim to parse the deps)
      if satProccesedPackages.isNone:        
        discard processFreeDependenciesSAT(pkgInfo, options)
      if satProccesedPackages.isSome:
        for pkg in satProccesedPackages.get:
          if pkg.basicInfo.name == "nim":
            return pkg.getNimBin(options)  

    assert options.nimBin.isSome, "Nim binary not set"
    #Check if the current nim satisfais the pacakge 
    let nimVer = options.nimBin.get.version
    let reqNimVer = pkgInfo.getRequiredNimVersion()
    
    if not nimVer.withinRange(reqNimVer):
      display("Warning:", &"Package requires nim {reqNimVer} but {nimVer}. Attempting to compile with the current nim version.", Warning, HighPriority)
    result = options.nim
  display("Info:", "compiling nim package using $1" % result, priority = HighPriority)

proc processFreeDependencies(pkgInfo: PackageInfo,
                             requirements: seq[PkgTuple],
                             options: Options,
                             preferredPackages: seq[PackageInfo] = @[]):
    HashSet[PackageInfo] =
  ## Verifies and installs dependencies.
  ##
  ## Returns set of PackageInfo (for paths) to pass to the compiler
  ## during build phase.
  assert not pkgInfo.isMinimal,
         "processFreeDependencies needs pkgInfo.requires"
  var requirements = requirements
  var pkgList {.global.}: seq[PackageInfo]
  once: 
    pkgList = initPkgList(pkgInfo, options)
    if options.useSatSolver:
      return processFreeDependenciesSAT(pkgInfo, options)
    else:
      requirements.add options.extraRequires

  display("Verifying", "dependencies for $1@$2" %
          [pkgInfo.basicInfo.name, $pkgInfo.basicInfo.version],
          priority = MediumPriority)

  var reverseDependencies: seq[PackageBasicInfo] = @[]

  let includeNim =
    pkgInfo.lockedDeps.contains("compiler") or
    pkgInfo.getDevelopDependencies(options).contains("nim")

  for dep in requirements:
    if dep.name.isNim and not includeNim:
      continue

    let resolvedDep = dep.resolveAlias(options)
    display("Checking", "for $1" % $resolvedDep, priority = MediumPriority)
    var pkg = initPackageInfo()
    var found = findPkg(preferredPackages, resolvedDep, pkg) or
      findPkg(pkgList, resolvedDep, pkg)
    # Check if the original name exists.
    if not found and resolvedDep.name != dep.name:
      display("Checking", "for $1" % $dep, priority = MediumPriority)
      found = findPkg(preferredPackages, dep, pkg) or findPkg(pkgList, dep, pkg)
      if found:
        displayWarning(&"Installed package {dep.name} should be renamed to " &
                       resolvedDep.name)
    if not found and options.useSatSolver:
      # check if SAT already installed the needed packages.
      if satProccesedPackages.isSome:
        for satPkg in satProccesedPackages.get:
          if satPkg.basicInfo.name == dep.name:
            found = true
            pkg = satPkg
            break
    if not found:
      display("Installing", $resolvedDep, priority = MediumPriority)
      let toInstall = @[(resolvedDep.name, resolvedDep.ver)]
      let (packages, installedPkg) = install(toInstall, options,
        doPrompt = false, first = false, fromLockFile = false,
        preferredPackages = preferredPackages)

      for pkg in packages:
        if result.contains pkg:
          # If the result already contains the newly tried to install package
          # we had to merge its special versions set into the set of the old
          # one.
          result[pkg].metaData.specialVersions.incl(
            pkg.metaData.specialVersions)
        else:
          result.incl pkg

      pkg = installedPkg # For addRevDep
      fillMetaData(pkg, pkg.getRealDir(), false, options)

      # This package has been installed so we add it to our pkgList.
      pkgList.add pkg
    else:
      displayInfo(pkgDepsAlreadySatisfiedMsg(dep), MediumPriority)
      result.incl pkg
      # Process the dependencies of this dependency.
      let fullInfo = pkg.toFullInfo(options)
      result.incl processFreeDependencies(fullInfo, fullInfo.requires, options,
                                          preferredPackages)

    if not pkg.isLink:
      reverseDependencies.add(pkg.basicInfo)
  if not options.useSatSolver: #SAT already checks if the dependencies are satisfied
    options.checkSatisfied(result.toSeq)

  # We add the reverse deps to the JSON file here because we don't want
  # them added if the above errorenous condition occurs
  # (unsatisfiable dependencies).
  # N.B. NimbleData is saved in installFromDir.
  for i in reverseDependencies:
    addRevDep(options.nimbleData, i, pkgInfo)

proc buildFromDir(pkgInfo: PackageInfo, paths: HashSet[seq[string]],
                  args: seq[string], options: Options) =
  ## Builds a package as specified by ``pkgInfo``.
  # Handle pre-`build` hook.
  let
    realDir = pkgInfo.getRealDir()
    pkgDir = pkgInfo.myPath.parentDir()

  cd pkgDir: # Make sure `execHook` executes the correct .nimble file.
    if not execHook(options, actionBuild, true):
      raise nimbleError("Pre-hook prevented further execution.")

  if pkgInfo.bin.len == 0:
    raise nimbleError(
        "Nothing to build. Did you specify a module to build using the" &
        " `bin` key in your .nimble file?")

  var
    binariesBuilt = 0
    args = args
  args.add "-d:NimblePkgVersion=" & $pkgInfo.basicInfo.version
  for path in paths:
    for p in path:
      args.add("--path:" & p.quoteShell)
  if options.verbosity >= HighPriority:
    # Hide Nim hints by default
    args.add("--hints:off")
  if options.verbosity == SilentPriority:
    # Hide Nim warnings
    args.add("--warnings:off")
  if options.noColor:
    # Disable coloured output
    args.add("--colors:off")

  if options.features.len > 0 and not options.useDeclarativeParser:
    raise nimbleError("Features are only supported when using the declarative parser")

  for feature in options.features: #Features enabled with the cli    
    let featureStr = &"features.{pkgInfo.basicInfo.name}.{feature}"
    # displayInfo &"Adding feature {featureStr}", priority = HighPriority
    args.add &"-d:{featureStr}"
  
  # displayInfo &"All active features: {getGloballyActiveFeatures()}", priority = HighPriority
  for featureStr in getGloballyActiveFeatures():
    args.add &"-d:{featureStr}"

  let binToBuild =
    # Only build binaries specified by user if any, but only if top-level package,
    # dependencies should have every binary built.
    if options.isInstallingTopLevel(pkgInfo.myPath.parentDir()):
      options.getCompilationBinary(pkgInfo).get("")
    else: ""

  for bin, src in pkgInfo.bin:
    # Check if this is the only binary that we want to build.
    if binToBuild.len != 0 and binToBuild != bin:
      if bin.extractFilename().changeFileExt("") != binToBuild:
        continue

    let outputDir = pkgInfo.getOutputDir("")
    if dirExists(outputDir):
      if fileExists(outputDir / bin):
        if not pkgInfo.needsRebuild(outputDir / bin, realDir, options):
          display("Skipping", "$1/$2 (up-to-date)" %
                  [pkginfo.basicInfo.name, bin], priority = HighPriority)
          binariesBuilt.inc()
          continue
    else:
      createDir(outputDir) 
    let outputOpt = "-o:" & pkgInfo.getOutputDir(bin).quoteShell
    display("Building", "$1/$2 using $3 backend" %
            [pkginfo.basicInfo.name, bin, pkgInfo.backend], priority = HighPriority)

    let input = realDir / src.changeFileExt("nim")
    # `quoteShell` would be more robust than `\"` (and avoid quoting when
    # un-necessary) but would require changing `extractBin`
    let cmd = "$# $# --colors:$# --noNimblePath $# $# $#" % [
      pkgInfo.getNimBin(options).quoteShell, pkgInfo.backend, if options.noColor: "off" else: "on", join(args, " "),
      outputOpt, input.quoteShell]
    try:
      display("Executing", cmd, priority = DebugPriority)
      doCmd(cmd)
      binariesBuilt.inc()
    except CatchableError as error:
      raise buildFailed(
        &"Build failed for the package: {pkgInfo.basicInfo.name}", details = error)

  if binariesBuilt == 0:
    raise nimbleError(
      "No binaries built, did you specify a valid binary name?"
    )

  # Handle post-`build` hook.
  cd pkgDir: # Make sure `execHook` executes the correct .nimble file.
    discard execHook(options, actionBuild, false)

proc cleanFromDir(pkgInfo: PackageInfo, options: Options) =
  ## Clean up build files.
  # Handle pre-`clean` hook.
  let pkgDir = pkgInfo.myPath.parentDir()

  cd pkgDir: # Make sure `execHook` executes the correct .nimble file.
    if not execHook(options, actionClean, true):
      raise nimbleError("Pre-hook prevented further execution.")

  if pkgInfo.bin.len == 0:
    return

  for bin, _ in pkgInfo.bin:
    let outputDir = pkgInfo.getOutputDir("")
    if dirExists(outputDir):
      if fileExists(outputDir / bin):
        removeFile(outputDir / bin)

  # Handle post-`clean` hook.
  cd pkgDir: # Make sure `execHook` executes the correct .nimble file.
    discard execHook(options, actionClean, false)

proc promptRemoveEntirePackageDir(pkgDir: string, options: Options) =
  let exceptionMsg = getCurrentExceptionMsg()
  let warningMsgEnd = if exceptionMsg.len > 0: &": {exceptionMsg}" else: "."
  let warningMsg = &"Unable to read {packageMetaDataFileName}{warningMsgEnd}"

  display("Warning", warningMsg, Warning, HighPriority)

  if not options.prompt(
      &"Would you like to COMPLETELY remove ALL files in {pkgDir}?"):
    raise nimbleQuit()

proc removePackageDir(pkgInfo: PackageInfo, pkgDestDir: string) =
  removePackageDir(pkgInfo.metaData.files & packageMetaDataFileName, pkgDestDir)

proc removeBinariesSymlinks(pkgInfo: PackageInfo, binDir: string) =
  for bin in pkgInfo.metaData.binaries:
    when defined(windows):
      removeFile(binDir / bin.changeFileExt("cmd"))
    removeFile(binDir / bin)

proc reinstallSymlinksForOlderVersion(pkgDir: string, options: Options) =
  let (pkgName, _, _) = getNameVersionChecksum(pkgDir)
  let pkgList = getInstalledPkgsMin(options.getPkgsDir(), options)
  var newPkgInfo = initPackageInfo()
  if pkgList.findPkg((pkgName, newVRAny()), newPkgInfo):
    newPkgInfo = newPkgInfo.toFullInfo(options)
    for bin, _ in newPkgInfo.bin:
      let symlinkDest = newPkgInfo.getOutputDir(bin)
      let symlinkFilename = options.getBinDir() / bin.extractFilename
      discard setupBinSymlink(symlinkDest, symlinkFilename, options)

proc removePackage(pkgInfo: PackageInfo, options: Options) =
  var pkgInfo = pkgInfo
  let pkgDestDir = pkgInfo.getPkgDest(options)

  if not pkgInfo.hasMetaData:
    try:
      fillMetaData(pkgInfo, pkgDestDir, true, options)
    except MetaDataError, ValueError:
      promptRemoveEntirePackageDir(pkgDestDir, options)
      removeDir(pkgDestDir)

  removePackageDir(pkgInfo, pkgDestDir)
  removeBinariesSymlinks(pkgInfo, options.getBinDir())
  reinstallSymlinksForOlderVersion(pkgDestDir, options)
  options.nimbleData.removeRevDep(pkgInfo)

proc packageExists(pkgInfo: PackageInfo, options: Options):
    Option[PackageInfo] =
  ## Checks whether a package `pkgInfo` already exists in the Nimble cache. If a
  ## package already exists returns the `PackageInfo` of the package in the
  ## cache otherwise returns `none`. Raises a `NimbleError` in the case the
  ## package exists in the cache but it is not valid.
  let pkgDestDir = pkgInfo.getPkgDest(options)
  if not fileExists(pkgDestDir / packageMetaDataFileName):
    return none[PackageInfo]()
  else:
    var oldPkgInfo = initPackageInfo()
    try:
      oldPkgInfo = pkgDestDir.getPkgInfo(options)
    except CatchableError as error:
      raise nimbleError(&"The package inside \"{pkgDestDir}\" is invalid.",
                        details = error)
    fillMetaData(oldPkgInfo, pkgDestDir, true, options)
    return some(oldPkgInfo)

proc processLockedDependencies(pkgInfo: PackageInfo, options: Options):
  HashSet[PackageInfo]

proc getDependenciesPaths(pkgInfo: PackageInfo, options: Options):
    HashSet[seq[string]]

proc processAllDependencies(pkgInfo: PackageInfo, options: Options):
    HashSet[PackageInfo] =
  if pkgInfo.hasLockedDeps():
    result = pkgInfo.processLockedDependencies(options)
  else:
    result.incl pkgInfo.processFreeDependencies(pkgInfo.requires, options)
    if options.task in pkgInfo.taskRequires:
      result.incl pkgInfo.processFreeDependencies(pkgInfo.taskRequires[options.task], options)

  putEnv(nimblePathsEnv, result.map(dep => dep.getRealDir().quoteShell).toSeq().join("|"))

proc allDependencies(pkgInfo: PackageInfo, options: Options): HashSet[PackageInfo] =
  ## Returns all dependencies for a package (Including tasks)
  result.incl pkgInfo.processFreeDependencies(pkgInfo.requires, options)
  for requires in pkgInfo.taskRequires.values:
    result.incl pkgInfo.processFreeDependencies(requires, options)
 
proc installFromDir(dir: string, requestedVer: VersionRange, options: Options,
                    url: string, first: bool, fromLockFile: bool,
                    vcsRevision = notSetSha1Hash,
                    deps: seq[PackageInfo] = @[],
                    preferredPackages: seq[PackageInfo] = @[]):
    PackageDependenciesInfo =
  ## Returns where package has been installed to, together with paths
  ## to the packages this package depends on.
  ##
  ## The return value of this function is used by
  ## ``processFreeDependencies``
  ##   To gather a list of paths to pass to the Nim compiler.
  ##
  ## ``first``
  ##   True if this is the first level of the indirect recursion.
  ## ``fromLockFile``
  ##   True if we are installing dependencies from the lock file.

  # Handle pre-`install` hook.
  if not options.depsOnly:
    cd dir: # Make sure `execHook` executes the correct .nimble file.
      if not execHook(options, actionInstall, true):
        raise nimbleError("Pre-hook prevented further execution.")

  var pkgInfo = getPkgInfo(dir, options)
  # Set the flag that the package is not in develop mode before saving it to the
  # reverse dependencies.
  pkgInfo.isLink = false
  if vcsRevision != notSetSha1Hash:
    ## In the case we downloaded the package as tarball we have to set the VCS
    ## revision returned by download procedure because it cannot be queried from
    ## the package directory.
    pkgInfo.metaData.vcsRevision = vcsRevision

  let realDir = pkgInfo.getRealDir()
  let binDir = options.getBinDir()
  var depsOptions = options
  depsOptions.depsOnly = false

  if requestedVer.kind == verSpecial:
    # Add a version alias to special versions set if requested version is a
    # special one.
    pkgInfo.metaData.specialVersions.incl requestedVer.spe

  # Dependencies need to be processed before the creation of the pkg dir.
  if first and pkgInfo.hasLockedDeps():
    result.deps = pkgInfo.processLockedDependencies(depsOptions)
  elif not fromLockFile:
    result.deps = pkgInfo.processFreeDependencies(pkgInfo.requires, depsOptions,
                                                  preferredPackages = preferredPackages)
  else:
    result.deps = deps.toHashSet

  if options.depsOnly:
    result.pkg = pkgInfo
    return result

  display("Installing", "$1@$2" %
    [pkginfo.basicInfo.name, $pkginfo.basicInfo.version],
    priority = MediumPriority)

  let oldPkg = pkgInfo.packageExists(options)
  if oldPkg.isSome:
    # In the case we already have the same package in the cache then only merge
    # the new package special versions to the old one.
    displayWarning(pkgAlreadyExistsInTheCacheMsg(pkgInfo), MediumPriority)
    if not options.useSatSolver: #The dep path is not created when using the sat solver as packages are collected upfront
      var oldPkg = oldPkg.get
      oldPkg.metaData.specialVersions.incl pkgInfo.metaData.specialVersions
      saveMetaData(oldPkg.metaData, oldPkg.getNimbleFileDir, changeRoots = false)
      if result.deps.contains oldPkg:
        result.deps[oldPkg].metaData.specialVersions.incl(
          oldPkg.metaData.specialVersions)
      result.deps.incl oldPkg
      result.pkg = oldPkg
      return result

  # nim is intended only for local project local usage, so avoid installing it
  # in .nimble/bin
  let isNimPackage = pkgInfo.basicInfo.name.isNim

  # Build before removing an existing package (if one exists). This way
  # if the build fails then the old package will still be installed.

  if pkgInfo.bin.len > 0 and not isNimPackage:
    let paths = result.deps.map(dep => dep.expandPaths(options))
    let flags = if options.action.typ in {actionInstall, actionPath, actionUninstall, actionDevelop}:
                  options.action.passNimFlags
                else:
                  @[]

    try:
      buildFromDir(pkgInfo, paths, "-d:release" & flags, options)
    except CatchableError:
      removeRevDep(options.nimbleData, pkgInfo)
      raise

  let pkgDestDir = pkgInfo.getPkgDest(options)

  # Fill package Meta data
  pkgInfo.metaData.url = url
  pkgInfo.isLink = false

  # Don't copy artifacts if project local deps mode and "installing" the top
  # level package.
  if not (options.localdeps and options.isInstallingTopLevel(dir)):
    createDir(pkgDestDir)
    # Copy this package's files based on the preferences specified in PkgInfo.
    var filesInstalled: HashSet[string]
    iterInstallFiles(realDir, pkgInfo, options,
      proc (file: string) =
        createDir(changeRoot(realDir, pkgDestDir, file.splitFile.dir))
        let dest = changeRoot(realDir, pkgDestDir, file)
        filesInstalled.incl copyFileD(file, dest)
    )

    # Copy the .nimble file.
    let dest = changeRoot(pkgInfo.myPath.splitFile.dir, pkgDestDir,
                          pkgInfo.myPath)
    filesInstalled.incl copyFileD(pkgInfo.myPath, dest)

    var binariesInstalled: HashSet[string]
    if pkgInfo.bin.len > 0 and not pkgInfo.basicInfo.name.isNim:
      # Make sure ~/.nimble/bin directory is created.
      createDir(binDir)
      # Set file permissions to +x for all binaries built,
      # and symlink them on *nix OS' to $nimbleDir/bin/
      for bin, src in pkgInfo.bin:
        let binDest =
          # Issue #308
          if dirExists(pkgDestDir / bin):
            bin & ".out"
          else: bin

        if fileExists(pkgDestDir / binDest):
          display("Warning:", ("Binary '$1' was already installed from source" &
                              " directory. Will be overwritten.") % bin, Warning,
                  MediumPriority)

        # Copy the binary file.
        createDir((pkgDestDir / binDest).parentDir())
        filesInstalled.incl copyFileD(pkgInfo.getOutputDir(bin),
                                      pkgDestDir / binDest)

        # Set up a symlink.
        let symlinkDest = pkgDestDir / binDest
        let symlinkFilename = options.getBinDir() / bin.extractFilename
        binariesInstalled.incl(
          setupBinSymlink(symlinkDest, symlinkFilename, options))

    # Update package path to point to installed directory rather than the temp
    # directory.
    pkgInfo.myPath = dest
    pkgInfo.metaData.files = filesInstalled.toSeq
    pkgInfo.metaData.binaries = binariesInstalled.toSeq

    saveMetaData(pkgInfo.metaData, pkgDestDir)
  else:
    display("Warning:", "Skipped copy in project local deps mode", Warning)

  pkgInfo.isInstalled = true

  displaySuccess(pkgInstalledMsg(pkgInfo.basicInfo.name), MediumPriority)

  result.deps.incl pkgInfo
  result.pkg = pkgInfo

  # Run post-install hook now that package is installed. The `execHook` proc
  # executes the hook defined in the CWD, so we set it to where the package
  # has been installed.
  cd pkgInfo.myPath.splitFile.dir:
    discard execHook(options, actionInstall, false)

proc getDependencyDir(name: string, dep: LockFileDep, options: Options):
    string =
  ## Returns the installation directory for a dependency from the lock file.
  options.getPkgsDir() /  &"{name}-{dep.version}-{dep.checksums.sha1}"

proc isInstalled(name: string, dep: LockFileDep, options: Options): bool =
  ## Checks whether a dependency from the lock file is already installed.
  fileExists(getDependencyDir(name, dep, options) / packageMetaDataFileName)

proc getDependency(name: string, dep: LockFileDep, options: Options):
    PackageInfo =
  ## Returns a `PackageInfo` for an already installed dependency from the
  ## lock file.
  let depDirName = getDependencyDir(name, dep, options)
  let nimbleFilePath = findNimbleFile(depDirName, false, options)
  getInstalledPackageMin(options, depDirName, nimbleFilePath).toFullInfo(options)

type
  DownloadInfo = ref object
    ## Information for a downloaded dependency needed for installation.
    name: string
    dependency: LockFileDep
    url: string
    version: VersionRange
    downloadDir: string
    vcsRevision: Sha1Hash

proc developWithDependencies(options: Options): bool =
  ## Determines whether the current executed action is a develop sub-command
  ## with `--with-dependencies` flag.
  options.action.typ == actionDevelop and options.action.withDependencies

proc raiseCannotCloneInExistingDirException(downloadDir: string) =
  let msg = "Cannot clone into '$1': directory exists." % downloadDir
  const hint = "Remove the directory, or run this command somewhere else."
  raise nimbleError(msg, hint)

proc downloadDependency(name: string, dep: LockFileDep, options: Options, validateRange = true):
    DownloadInfo =
  ## Downloads a dependency from the lock file.
  if options.offline:
    raise nimbleError("Cannot download in offline mode.")

  if dep.url.len == 0:
    raise nimbleError(
      &"Cannot download dependency '{name}' because its URL is empty in the lock file. " &
      "This usually happens with develop mode dependencies. " &
      "Make sure the dependency is properly configured in your develop file.")

  if not options.developWithDependencies:
    let depDirName = getDependencyDir(name, dep, options)
    if depDirName.dirExists:
      promptRemoveEntirePackageDir(depDirName, options)
      removeDir(depDirName)

  let (url, metadata) = getUrlData(dep.url)
  let version =  dep.version.parseVersionRange
  let subdir = metadata.getOrDefault("subdir")
  let downloadPath = if options.developWithDependencies:
    getDevelopDownloadDir(url, subdir, options) else: ""

  if dirExists(downloadPath):
    if options.developWithDependencies:
      displayWarning(skipDownloadingInAlreadyExistingDirectoryMsg(
        downloadPath, name))
      result = DownloadInfo(
        name: name,
        dependency: dep,
        url: url,
        version: version,
        downloadDir: downloadPath,
        vcsRevision: dep.vcsRevision)
      return
    else:
      raiseCannotCloneInExistingDirException(downloadPath)

  let (downloadDir, _, vcsRevision) = downloadPkg(
    url, version, dep.downloadMethod, subdir, options, downloadPath,
    dep.vcsRevision, validateRange = validateRange)

  let downloadedPackageChecksum = calculateDirSha1Checksum(downloadDir)
  if downloadedPackageChecksum != dep.checksums.sha1:
    raise checksumError(name, dep.version, dep.vcsRevision,
                        downloadedPackageChecksum, dep.checksums.sha1)

  result = DownloadInfo(
    name: name,
    dependency: dep,
    url: url,
    version: version,
    downloadDir: downloadDir,
    vcsRevision: vcsRevision)

proc installDependency(lockedDeps: Table[string, LockFileDep], downloadInfo: DownloadInfo,
                       options: Options,
                       deps: seq[PackageInfo]): PackageInfo =
  ## Installs an already downloaded dependency of the package `pkgInfo`.
  let (_, newlyInstalledPkgInfo) = installFromDir(
    downloadInfo.downloadDir,
    downloadInfo.version,
    options,
    downloadInfo.url,
    first = false,
    fromLockFile = true,
    downloadInfo.vcsRevision,
    deps = deps)

  downloadInfo.downloadDir.removeDir
  for depDepName in downloadInfo.dependency.dependencies:
    let depDep = lockedDeps[depDepName]
    let revDep = (name: depDepName, version: depDep.version,
                  checksum: depDep.checksums.sha1)
    options.nimbleData.addRevDep(revDep, newlyInstalledPkgInfo)

  return newlyInstalledPkgInfo

proc processLockedDependencies(pkgInfo: PackageInfo, options: Options):
    HashSet[PackageInfo] =
  # Returns a hash set with `PackageInfo` of all packages from the lock file of
  # the package `pkgInfo` by getting the info for develop mode dependencies from
  # their local file system directories and other packages from the Nimble
  # cache. If a package with required checksum is missing from the local cache
  # installs it by downloading it from its repository.
  if not options.isLegacy:
    return options.satResult.pkgs
  
  let developModeDeps = getDevelopDependencies(pkgInfo, options, raiseOnValidationErrors = false)

  var res: seq[PackageInfo]

  for name, dep in pkgInfo.lockedDeps.lockedDepsFor(options):
    if name.isNim and options.useSystemNim: continue
    if developModeDeps.hasKey(name):
      res.add developModeDeps[name][]
    elif isInstalled(name, dep, options):
      res.add getDependency(name, dep, options)
    elif not options.offline:
      let
        downloadResult = downloadDependency(name, dep, options)
        dependencies = res.filterIt(dep.dependencies.contains(it.name))
      res.add installDependency(pkgInfo.lockedDeps.lockedDepsFor(options).toSeq.toTable,
                                downloadResult, options, dependencies)
    else:
      raise nimbleError("Unsatisfied dependency: " & pkgInfo.basicInfo.name)

  return res.toHashSet

proc install(packages: seq[PkgTuple], options: Options,
             doPrompt, first, fromLockFile: bool,
             preferredPackages: seq[PackageInfo] = @[]): PackageDependenciesInfo =
  ## ``first``
  ##   True if this is the first level of the indirect recursion.
  ## ``fromLockFile``
  ##   True if we are installing dependencies from the lock file.
  ## ``preferredPackages``
  ##   Prefer these packages when performing `processFreeDependencies`
  if packages == @[]:
    let currentDir = getCurrentDir()
    if currentDir.developFileExists:
      displayWarning(
        "Installing a package which currently has develop mode dependencies." &
        "\nThey will be ignored and installed as normal packages.")
    result = installFromDir(currentDir, newVRAny(), options, "", first,
                            fromLockFile,
                            preferredPackages = preferredPackages)
  else:
    # Install each package.
    for pv in packages:
      let (meth, url, metadata) = getDownloadInfo(pv, options, doPrompt) #TODO dont download if its nim

      let subdir = metadata.getOrDefault("subdir")
      var downloadPath = ""
      if options.useSatSolver and subdir == "": #Ignore the cache if subdir is set
          downloadPath =  getCacheDownloadDir(url, pv.ver, options)
      var nimInstalled = none(NimInstalled)
      if pv.isNim: 
        nimInstalled = installNimFromBinariesDir(pv, options)
       
      let (downloadDir, downloadVersion, vcsRevision) =
        if nimInstalled.isSome():
          (nimInstalled.get().dir, nimInstalled.get().ver, notSetSha1Hash)
        else:
          downloadPkg(url, pv.ver, meth, subdir, options,
                    downloadPath = downloadPath, vcsRevision = notSetSha1Hash)
      try:
        var opt = options
        if pv.name.isNim:
          if not downloadDir.isSubdirOf(options.nimBinariesDir):
            compileNim(opt, downloadDir, pv.ver)
          opt.useNimFromDir(downloadDir, pv.ver, true)
        result = installFromDir(downloadDir, pv.ver, opt, url,
                                first, fromLockFile, vcsRevision,
                                preferredPackages = preferredPackages)
      except BuildFailed as error:
        # The package failed to build.
        # Check if we tried building a tagged version of the package.
        let headVer = getHeadName(meth)
        if pv.ver.kind != verSpecial and downloadVersion != headVer and
           not fromLockFile:
          # If we tried building a tagged version of the package and this is not
          # fixed in the lock file version then ask the user whether they want
          # to try building #head.
          let promptResult = doPrompt and
              options.prompt(("Build failed for '$1@$2', would you" &
                  " like to try installing '$1@#head' (latest unstable)?") %
                  [pv.name, $downloadVersion])
          if promptResult:
            let toInstall = @[(pv.name, headVer.toVersionRange())]
            result =  install(toInstall, options, doPrompt, first,
                              fromLockFile = false)
          else:
            raise buildFailed(
              "Aborting installation due to build failure.", details = error)
        else:
          raise

proc getDependenciesPaths(pkgInfo: PackageInfo, options: Options):
    HashSet[seq[string]] =
  let deps = pkgInfo.processAllDependencies(options)
  return deps.map(dep => dep.expandPaths(options))

proc build(pkgInfo: PackageInfo, options: Options) =
  ## Builds the package `pkgInfo`.
  nimScriptHint(pkgInfo)
  let paths = pkgInfo.getDependenciesPaths(options)
  var args = options.getCompilationFlags()
  buildFromDir(pkgInfo, paths, args, options)

proc addPackages(packages: seq[PkgTuple], options: var Options) =
  if packages.len == 0:
    raise nimbleError(
      "Expected packages to add to dependencies, got none."
    )
  
  let 
    dir = findNimbleFile(getCurrentDir(), true, options)
    pkgInfo = getPkgInfo(getCurrentDir(), options)
    pkgList = options.getPackageList()
    deps = pkgInfo.requires

  var 
    appendStr: string
    addedPkgs: seq[string]

  for apkg in packages:
    var 
      exists = false
      version: string

    let isValidUrl = isURL(apkg.name)
    
    for pkg in pkgList:
      if pkg.name == apkg.name:
        exists = true
        version = case apkg.ver.kind
        of verAny:
          ""
        else:
          $apkg.ver
        break
    
    if not exists and not isValidUrl:
      raise nimbleError(
        "No such package \"$1\" was found in the package list." % [apkg.name]
      )
    
    var doAppend = true
    for dep in deps:
      if dep.name.toLowerAscii() == apkg.name.toLowerAscii():
        displayWarning(
          "$1 is already a dependency to $2; ignoring." % [apkg.name, pkgInfo.name]
        )
        doAppend = false
    
    if not doAppend:
      continue
  
    var pSeq = newSeq[PkgTuple](1)
    pSeq[0] = apkg

    let data = install(pSeq, options, false, false, false)

    let finalVer = if version.len < 1:
      $data.pkg.basicInfo.version
    else:
      version
    
    let prettyStr = apkg.name & '@' & finalVer

    appendStr &= "\nrequires \"$1$2\"" % [
      apkg.name,
      if finalVer != "":
        " >= " & finalVer
      else:
        ""
    ]
    
    addedPkgs.add(prettyStr)

  let file = open(dir, fmAppend)
  file.write(appendStr)
  file.close()

  for added in addedPkgs:
    display(
      "Added",
      "$1 as a dependency to $2" % [added, pkgInfo.name],
      priority = HighPriority
    )

proc build(options: var Options) =
  getPkgInfo(getCurrentDir(), options).build(options)

proc clean(options: Options) =
  let dir = getCurrentDir()
  let pkgInfo = getPkgInfo(dir, options)
  nimScriptHint(pkgInfo)
  cleanFromDir(pkgInfo, options)

proc execBackend(pkgInfo: PackageInfo, options: Options) =
  let
    bin = options.getCompilationBinary(pkgInfo).get("")
    binDotNim = bin.addFileExt("nim")

  if bin == "":
    raise nimbleError("You need to specify a file.")

  if not (fileExists(bin) or fileExists(binDotNim)):
    raise nimbleError(
      "Specified file, " & bin & " or " & binDotNim & ", does not exist.")

  let pkgInfo = getPkgInfo(getCurrentDir(), options)
  nimScriptHint(pkgInfo)

  let deps = 
    if not options.isLegacy:
      options.satResult.pkgs
    else:
      pkgInfo.processAllDependencies(options)
  if not execHook(options, options.action.typ, true):
    raise nimbleError("Pre-hook prevented further execution.")

  var args = @["-d:NimblePkgVersion=" & $pkgInfo.basicInfo.version]
  if not options.isLegacy:
    for path in options.getPathsAllPkgs():
      args.add("--path:" & path.quoteShell)
  else:
    for dep in deps:
      args.add("--path:" & dep.getRealDir().quoteShell)
  if options.verbosity >= HighPriority:
    # Hide Nim hints by default
    args.add("--hints:off")
  if options.verbosity == SilentPriority:
    # Hide Nim warnings
    args.add("--warnings:off")

  for option in options.getCompilationFlags():
    args.add(option.quoteShell)

  let backend =
    if options.action.backend.len > 0:
      options.action.backend
    else:
      pkgInfo.backend

  if options.action.typ == actionCompile:
    display("Compiling", "$1 (from package $2) using $3 backend" %
            [bin, pkgInfo.basicInfo.name, backend], priority = HighPriority)
  else:
    display("Generating", ("documentation for $1 (from package $2) using $3 " &
            "backend") % [bin, pkgInfo.basicInfo.name, backend], priority = HighPriority)

  doCmd("$# $# --noNimblePath $# $# $#" %
        [pkgInfo.getNimBin(options).quoteShell,
         backend,
         join(args, " "),
         bin.quoteShell,
         options.action.additionalArguments.map(quoteShell).join(" ")])

  display("Success:", "Execution finished", Success, HighPriority)

  # Run the post hook for action if it exists
  discard execHook(options, options.action.typ, false)

proc search(options: Options) =
  ## Searches for matches in ``options.action.search``.
  ##
  ## Searches are done in a case insensitive way making all strings lower case.
  assert options.action.typ == actionSearch
  if options.action.search == @[]:
    raise nimbleError("Please specify a search string.")
  if needsRefresh(options):
    raise nimbleError("Please run nimble refresh.")
  let pkgList = getPackageList(options)
  var found = false
  template onFound {.dirty.} =
    echoPackage(pkg)
    if pkg.alias.len == 0 and options.action.showSearchVersions:
      echoPackageVersions(pkg)
    echo(" ")
    found = true
    break forPkg

  for pkg in pkgList:
    block forPkg:
      for word in options.action.search:
        # Search by name.
        if word.toLower() in pkg.name.toLower():
          onFound()
        # Search by tag.
        for tag in pkg.tags:
          if word.toLower() in tag.toLower():
            onFound()

  if not found:
    display("Error", "No package found.", Error, HighPriority)

proc list(options: Options) =
  if needsRefresh(options):
    raise nimbleError("Please run nimble refresh.")
  let pkgList = getPackageList(options)
  for pkg in pkgList:
    echoPackage(pkg)
    if pkg.alias.len == 0 and options.action.showListVersions:
      echoPackageVersions(pkg)
    echo(" ")

proc listNimBinaries(options: Options) =
  let nimBininstalledPkgs = getInstalledPkgsMin(options.nimBinariesDir, options)
  displayFormatted(Message, "nim")
  displayFormatted(Hint, "\n")
  for idx, pkg in nimBininstalledPkgs:
    assert pkg.basicInfo.name == "nim"
    if idx == nimBininstalledPkgs.len() - 1:
      displayFormatted(Hint, "└── ")
    else:
      displayFormatted(Hint, "├── ")
    displayFormatted(Success, "@" & $pkg.basicInfo.version)
    displayFormatted(Hint, " ")
    displayFormatted(Details, fmt"({pkg.myPath.splitPath().head})")
    displayFormatted(Hint, "\n")
  displayFormatted(Hint, "\n")

proc listInstalled(options: Options) =
  type
    VersionChecksumTuple = tuple[version: Version, checksum: Sha1Hash, special: seq[string], path: string]
  var vers: OrderedTable[string, seq[VersionChecksumTuple]]
  let pkgs = getInstalledPkgsMin(options.getPkgsDir(), options)
  for pkg in pkgs:
    let
      pName = pkg.basicInfo.name
      pVersion = pkg.basicInfo.version
      pChecksum = pkg.basicInfo.checksum
    if not vers.hasKey(pName): vers[pName] = @[]
    var s = vers[pName]
    add(s, (pVersion, pChecksum, pkg.metadata.specialVersions.toSeq().map(v => $v), pkg.getRealDir()))
    vers[pName] = s

  vers.sort(proc (a, b: (string, seq[VersionChecksumTuple])): int =
    cmpIgnoreCase(a[0], b[0]))

  displayInfo("Package list format: {PackageName} ")
  displayInfo("  {PackageName} ")
  displayInfo("     {Version} ({CheckSum})")
  for k in keys(vers):
    displayFormatted(Message, k)
    displayFormatted(Hint, "\n")
    if options.action.showListVersions:
      for idx, item in vers[k]:
        if idx == vers[k].len() - 1:
          displayFormatted(Hint, "└── ")
        else:
          displayFormatted(Hint, "├── ")
        displayFormatted(Success, "@", $item.version)
        displayFormatted(Hint, " ")
        displayFormatted(Details, fmt"({item.checksum})")
        if item.special.len > 1:
          displayFormatted(Hint, " ")
          displayFormatted(Details, fmt"""[{item.special.join(", ")}]""")
        displayFormatted(Hint, " ")
        displayFormatted(Details, fmt"({item.path})")
        displayFormatted(Hint, "\n")
        # "  [" & vers[k].join(", ") & "]"

type VersionAndPath = tuple[version: Version, path: string]

proc listPaths(options: Options) =
  ## Loops over the specified packages displaying their installed paths.
  ##
  ## If there are several packages installed, all of them will be displayed.
  ## If any package name is not found, the proc displays a missing message and
  ## continues through the list, but at the end quits with a non zero exit
  ## error.
  ##
  ## On success the proc returns normally.

  cli.setSuppressMessages(true)
  assert options.action.typ == actionPath

  if options.action.packages.len == 0:
    raise nimbleError("A package name needs to be specified")

  var errors = 0
  let pkgs = getInstalledPkgsMin(options.getPkgsDir(), options)
  for name, version in options.action.packages.items:
    var installed: seq[VersionAndPath] = @[]
    # There may be several, list all available ones and sort by version.
    for pkg in pkgs:
      if name == pkg.basicInfo.name and withinRange(pkg.basicInfo.version, version):
        installed.add((pkg.basicInfo.version, pkg.getRealDir))

    if installed.len > 0:
      sort(installed, cmp[VersionAndPath], Descending)
      # The output for this command is used by tools so we do not use display().
      for pkg in installed:
        echo pkg.path
    else:
      display("Warning:", "Package '$1' is not installed" % name, Warning,
              MediumPriority)
      errors += 1
  if errors > 0:
    raise nimbleError(
        "At least one of the specified packages was not found")

proc join(x: seq[PkgTuple]; y: string): string =
  if x.len == 0: return ""
  result = x[0][0] & " " & $x[0][1]
  for i in 1 ..< x.len:
    result.add y
    result.add x[i][0] & " " & $x[i][1]

proc getPackageByPattern(pattern: string, options: Options): PackageInfo =
  ## Search for a package file using multiple strategies.
  if pattern == "":
    # Not specified - using current directory
    result = getPkgInfo(os.getCurrentDir(), options)
  elif pattern.splitFile.ext == ".nimble" and pattern.fileExists:
    # project file specified
    result = getPkgInfoFromFile(pattern, options)
  elif pattern.dirExists:
    # project directory specified
    result = getPkgInfo(pattern, options)
  else:
    # Last resort - attempt to read as package identifier
    let packages = getInstalledPkgsMin(options.getPkgsDir(), options)
    let identTuple = parseRequires(pattern)
    var skeletonInfo = initPackageInfo()
    if not findPkg(packages, identTuple, skeletonInfo):
      raise nimbleError(
          "Specified package not found"
      )
    result = getPkgInfoFromFile(skeletonInfo.myPath, options)

proc getNimDir(options: Options): string = 
  ## returns the nim directory prioritizing the nimBin one if it satisfais the requirement of the project
  ## otherwise it returns the major version of the nim installed packages that satisfies the requirement of the project
  ## if no nim package satisfies the requirement of the project it returns the nimBin parent directory
  ## only used by the `nimble dump` command which is used to drive the lsp
  let projectPkg = getPackageByPattern(options.action.projName, options)
  var nimPkgTupl = projectPkg.requires.filterIt(it.name == "nim")
  if nimPkgTupl.len > 0:
    let reqNimVersion = nimPkgTupl[0].ver
    if options.nimBin.isSome and options.nimBin.get.version.withinRange(reqNimVersion):
      return options.nimBin.get.path.parentDir
    var nimPkgInfo = 
      getInstalledPkgsMin(options.getPkgsDir(), options)
        .filterIt(it.basicInfo.name == "nim" and it.withinRange(reqNimVersion))
    nimPkgInfo.sort(proc (a, b: PackageInfo): int = cmp(a.basicInfo.version, b.basicInfo.version), Descending)
    if nimPkgInfo.len > 0:
      let nimBin = nimPkgInfo[0].getNimBin(options)
      return nimBin.parentDir
  return options.nimBin.get(NimBin()).path.parentDir

proc getEntryPoints(pkgInfo: PackageInfo, options: Options): seq[string] =
  ## Returns the entry points for a package. 
  ## This is useful for tools like the lsp.
  let main = pkgInfo.srcDir / pkgInfo.basicInfo.name & ".nim"
  result.add main
  let entries = pkgInfo.entryPoints & pkgInfo.bin.keys.toSeq
  for entry in entries:
    result.add if entry.endsWith(".nim"): entry else: entry & ".nim"
  
proc dump(options: Options) =
  var p = getPackageByPattern(options.action.projName, options)
  if options.action.collect or options.action.solve:
    p.requires &= options.extraRequires
    let pkgList = initPkgList(p, options).toSeq()
    if options.action.collect:
      dumpPackageVersionTable(p, pkgList.toSeq(), options)
    else:
      dumpSolvedPackages(p, pkgList, options)
    quit()

  cli.setSuppressMessages(true)
  var j: JsonNode
  var s: string
  let json = options.dumpMode == kdumpJson
  if json: j = newJObject()
  template fn(key, val) =
    if json:
      when val is seq[PkgTuple]:
        # jsonutils.toJson would work but is only available since 1.3.5, so we
        # do it manually.
        j[key] = newJArray()
        for (name, ver) in val:
          j[key].add %{
            "name": % name,
            # we serialize both: `ver` may be more convenient for tooling
            # (no parsing needed); while `str` is more familiar.
            "str": % $ver,
            "ver": %* ver,
          }
      else:
        j[key] = %*val
    else:
      if s.len > 0: s.add "\n"
      s.add key & ": "
      when val is string:
        s.add val.escape
      else:
        s.add val.join(", ").escape
  fn "name", p.basicInfo.name
  fn "version", $p.basicInfo.version
  fn "nimblePath", p.myPath
  fn "author", p.author
  fn "desc", p.description
  fn "license", p.license
  fn "skipDirs", p.skipDirs
  fn "skipFiles", p.skipFiles
  fn "skipExt", p.skipExt
  fn "installDirs", p.installDirs
  fn "installFiles", p.installFiles
  fn "installExt", p.installExt
  fn "requires", p.requires
  for task, requirements in p.taskRequires:
    fn task & "Requires", requirements
  fn "bin", p.bin.keys.toSeq
  fn "binDir", p.binDir
  fn "srcDir", p.srcDir
  fn "backend", p.backend
  fn "paths", p.paths
  fn "nimDir", getNimDir(options)
  fn "entryPoints", p.getEntryPoints(options)
  fn "testEntryPoint", p.testEntryPoint
  if json:
    s = j.pretty
  echo s

proc init(options: Options) =
  # Check whether the vcs is installed.
  let vcsBin = options.action.vcsOption
  if vcsBin != "" and findExe(vcsBin, true) == "":
    raise nimbleError("Please install git or mercurial first")

  # Determine the package name.
  let hasProjectName = options.action.projName != ""
  let pkgName =
    if options.action.projName != "":
      options.action.projName
    else:
      os.getCurrentDir().splitPath.tail.toValidPackageName()

  # Validate the package name.
  validatePackageName(pkgName)

  # Determine the package root.
  let pkgRoot =
    if not hasProjectName:
      os.getCurrentDir()
    else:
      os.getCurrentDir() / pkgName

  let nimbleFile = (pkgRoot / pkgName).changeFileExt("nimble")

  if fileExists(nimbleFile):
    let errMsg = "Nimble file already exists: $#" % nimbleFile
    raise nimbleError(errMsg)

  if options.forcePrompts != forcePromptYes:
    display(
      "Info:",
      "Package initialisation requires info which could not be inferred.\n" &
      "Default values are shown in square brackets, press\n" &
      "enter to use them.",
      priority = HighPriority
    )
  display("Using", "$# for new package name" % [pkgName.escape()],
    priority = HighPriority)

  # Determine author by running an external command
  proc getAuthorWithCmd(cmd: string): string =
    let (name, exitCode) = doCmdEx(cmd)
    if exitCode == QuitSuccess and name.len > 0:
      result = name.strip()
      display("Using", "$# for new package author" % [result],
        priority = HighPriority)

  # Determine package author via git/hg or asking
  proc getAuthor(): string =
    if findExe("git") != "":
      result = getAuthorWithCmd("git config --global user.name")
    elif findExe("hg") != "":
      result = getAuthorWithCmd("hg config ui.username")
    if result.len == 0:
      result = promptCustom(options, "Your name?", "Anonymous")
  let pkgAuthor = getAuthor()

  # Declare the src/ directory
  let pkgSrcDir = "src"
  display("Using", "$# for new package source directory" % [pkgSrcDir.escape()],
    priority = HighPriority)

  # Determine the type of package
  let pkgType = promptList(
    options,
    """Package type?
Library - provides functionality for other packages.
Binary  - produces an executable for the end-user.
Hybrid  - combination of library and binary

For more information see https://goo.gl/cm2RX5""",
    ["library", "binary", "hybrid"]
  )

  # Ask for package version.
  let pkgVersion = promptCustom(options, "Initial version of package?", "0.1.0")
  validateVersion(pkgVersion)

  # Ask for description
  let pkgDesc = promptCustom(options, "Package description?",
    "A new awesome nimble package")

  # Ask for license
  # License list is based on:
  # https://www.blackducksoftware.com/top-open-source-licenses
  var pkgLicense = options.promptList(
    """Package License?
This should ideally be a valid SPDX identifier. See https://spdx.org/licenses/.
""", [
    "MIT",
    "GPL-2.0",
    "Apache-2.0",
    "ISC",
    "GPL-3.0",
    "BSD-3-Clause",
    "LGPL-2.1",
    "LGPL-3.0",
    # LGPLv3 with static linking exception https://spdx.org/licenses/LGPL-3.0-linking-exception.html
    "LGPL-3.0-linking-exception",
    "EPL-2.0",
    "AGPL-3.0",
    # This is what npm calls "UNLICENSED" (which is too similar to "Unlicense")
    "Proprietary",
    "Other"
  ])

  if pkgLicense.toLower == "other":
    pkgLicense = promptCustom(options,
      """Package license?
Please specify a valid SPDX identifier.""",
      "MIT"
    )

  if pkgLicense in ["GPL-2.0", "GPL-3.0", "LGPL-2.1", "LGPL-3.0", "AGPL-3.0"]:
    let orLater = options.promptList(
      "\"Or any later version\" clause?", ["Yes", "No"])
    if orLater == "Yes":
      pkgLicense.add("-or-later")
    else:
      pkgLicense.add("-only")

  # Ask for Nim dependency
  let nimDepDef = getNimrodVersion(options)
  let pkgNimDep = promptCustom(options, "Lowest supported Nim version?",
    $nimDepDef)
  validateVersion(pkgNimDep)

  createPkgStructure(
    (
      pkgName,
      pkgVersion,
      pkgAuthor,
      pkgDesc,
      pkgLicense,
      pkgSrcDir,
      pkgNimDep,
      pkgType
    ),
    pkgRoot
  )

  # Create a git or hg repo in the new nimble project.
  if vcsBin != "":
    let cmd = fmt"cd {pkgRoot} && {vcsBin} init"
    let ret: tuple[output: string, exitCode: int] = execCmdEx(cmd)
    if ret.exitCode != 0: quit ret.output

    var ignoreFile = if vcsBin == "git": ".gitignore" else: ".hgignore"
    var fd = open(joinPath(pkgRoot, ignoreFile), fmWrite)
    fd.write(pkgName & "\n")
    fd.close()

  display("Success:", "Package $# created successfully" % [pkgName], Success,
    HighPriority)

proc removePackages(pkgs: HashSet[ReverseDependency], options: var Options) =
  for pkg in pkgs:
    let pkgInfo = pkg.toPkgInfo(options)
    case pkg.kind
    of rdkInstalled:
      pkgInfo.removePackage(options)
      display("Removed", $pkg, Success, HighPriority)
    of rdkDevelop:
      options.nimbleData.removeRevDep(pkgInfo)

proc collectNames(pkgs: HashSet[ReverseDependency],
                  includeDevelopRevDeps: bool): seq[string] =
  for pkg in pkgs:
    if pkg.kind != rdkDevelop or includeDevelopRevDeps:
      result.add $pkg

proc uninstall(options: var Options) =
  if options.action.packages.len == 0:
    raise nimbleError(
        "Please specify the package(s) to uninstall.")

  var pkgsToDelete: HashSet[ReverseDependency]
  # Do some verification.
  for pkgTup in options.action.packages:
    display("Looking", "for $1 ($2)" % [pkgTup.name, $pkgTup.ver],
            priority = HighPriority)
    let installedPkgs = getInstalledPkgsMin(options.getPkgsDir(), options)
    var pkgList = findAllPkgs(installedPkgs, pkgTup)
    if pkgList.len == 0:
      raise nimbleError("Package not found")

    display("Checking", "reverse dependencies", priority = HighPriority)
    for pkg in pkgList:
      # Check whether any packages depend on the ones the user is trying to
      # uninstall.
      if options.uninstallRevDeps:
        getAllRevDeps(options.nimbleData, pkg.toRevDep, pkgsToDelete)
      else:
        let revDeps = options.nimbleData.getRevDeps(pkg.toRevDep)
        if len(revDeps - pkgsToDelete) > 0:
          let pkgs = revDeps.collectNames(true)
          displayWarning(
            cannotUninstallPkgMsg(pkgTup.name, pkg.basicInfo.version, pkgs))
        else:
          pkgsToDelete.incl pkg.toRevDep

  if pkgsToDelete.len == 0:
    raise nimbleError("Failed uninstall - no packages to delete")

  if not options.prompt(pkgsToDelete.collectNames(false).promptRemovePkgsMsg):
    raise nimbleQuit()

  removePackages(pkgsToDelete, options)

proc listTasks(options: Options) =
  let nimbleFile = findNimbleFile(getCurrentDir(), true, options)
  nimscriptwrapper.listTasks(nimbleFile, options)

proc developAllDependencies(pkgInfo: PackageInfo, options: var Options, topLevel = false)

proc saveLinkFile(pkgInfo: PackageInfo, options: Options) =
  let
    pkgName = pkgInfo.basicInfo.name
    pkgLinkDir = options.getPkgsLinksDir / pkgName.getLinkFileDir
    pkgLinkFilePath = pkgLinkDir / pkgName.getLinkFileName
    pkgLinkFileContent = pkgInfo.myPath & "\n" & pkgInfo.getNimbleFileDir

  if pkgLinkDir.dirExists and not options.prompt(
    &"The link file for {pkgName} already exists. Overwrite?"):
    return

  pkgLinkDir.createDir
  writeFile(pkgLinkFilePath, pkgLinkFileContent)
  displaySuccess(pkgLinkFileSavedMsg(pkgLinkFilePath))

proc developFromDir(pkgInfo: PackageInfo, options: var Options, topLevel = false) =
  assert options.action.typ == actionDevelop,
    "This procedure should be called only when executing develop sub-command."

  let dir = pkgInfo.getNimbleFileDir()

  if options.depsOnly:
    raise nimbleError("Cannot develop dependencies only.")

  cd dir: # Make sure `execHook` executes the correct .nimble file.
    if not execHook(options, actionDevelop, true):
      raise nimbleError("Pre-hook prevented further execution.")

  if pkgInfo.bin.len > 0:
    displayWarning(
      "This package's binaries will not be compiled for development.")

  if options.developLocaldeps:
    var optsCopy = options
    optsCopy.nimbleDir = dir / nimbledeps
    optsCopy.nimbleData = newNimbleDataNode()
    optsCopy.startDir = dir
    createDir(optsCopy.getPkgsDir())
    cd dir:
      if options.action.withDependencies:
        developAllDependencies(pkgInfo, optsCopy, topLevel = topLevel)
      else:
        discard processAllDependencies(pkgInfo, optsCopy)
  else:
    if options.action.withDependencies:
      developAllDependencies(pkgInfo, options, topLevel = topLevel)
    else:
      # Dependencies need to be processed before the creation of the pkg dir.
      discard processAllDependencies(pkgInfo, options)

  if options.action.global:
    saveLinkFile(pkgInfo, options)

  displaySuccess(pkgSetupInDevModeMsg(pkgInfo.basicInfo.name, dir))

  # Execute the post-develop hook.
  cd dir:
    discard execHook(options, actionDevelop, false)

proc installDevelopPackage(pkgTup: PkgTuple, options: var Options):
    PackageInfo =
  let (meth, url, metadata) = getDownloadInfo(pkgTup, options, true)
  let subdir = metadata.getOrDefault("subdir")
  let downloadDir = getDevelopDownloadDir(url, subdir, options)

  if dirExists(downloadDir):
    if options.developWithDependencies:
      displayWarning(skipDownloadingInAlreadyExistingDirectoryMsg(
        downloadDir, pkgTup.name))
      let pkgInfo = getPkgInfo(downloadDir, options)
      developFromDir(pkgInfo, options)
      options.action.devActions.add(
        (datAdd, pkgInfo.getNimbleFileDir.normalizedPath))
      return pkgInfo
    else:
      raiseCannotCloneInExistingDirException(downloadDir)


  # Download the HEAD and make sure the full history is downloaded.
  let ver =
    if pkgTup.ver.kind == verAny:
      parseVersionRange("#head")
    else:
      pkgTup.ver

  discard downloadPkg(url, ver, meth, subdir, options, downloadDir,
                      vcsRevision = notSetSha1Hash)

  let pkgDir = downloadDir / subdir
  var pkgInfo = getPkgInfo(pkgDir, options)

  developFromDir(pkgInfo, options)
  options.action.devActions.add(
    (datAdd, pkgInfo.getNimbleFileDir.normalizedPath))

  return pkgInfo

proc developLockedDependencies(pkgInfo: PackageInfo,
    alreadyDownloaded: var HashSet[string], options: var Options) =
  ## Downloads for develop the dependencies from the lock file.
  for task, deps in pkgInfo.lockedDeps:
    for name, dep in deps:
      if dep.url.removeTrailingGitString notin alreadyDownloaded:
        let downloadResult = downloadDependency(name, dep, options)
        alreadyDownloaded.incl downloadResult.url.removeTrailingGitString
        options.action.devActions.add(
          (datAdd, downloadResult.downloadDir.normalizedPath))

proc check(alreadyDownloaded: HashSet[string], dep: PkgTuple,
           options: Options): bool =
  let (_, url, _) = getDownloadInfo(dep, options, false)
  alreadyDownloaded.contains url.removeTrailingGitString

proc developFreeDependencies(pkgInfo: PackageInfo,
                             alreadyDownloaded: var HashSet[string],
                             options: var Options) =
  # Downloads for develop the dependencies of `pkgInfo` (including transitive
  # ones) by recursively following the requires clauses in the Nimble files.
  assert not pkgInfo.isMinimal,
         "developFreeDependencies needs pkgInfo.requires"

  for dep in pkgInfo.requires:
    if dep.name.isNim:
      continue

    let resolvedDep = dep.resolveAlias(options)
    var found = alreadyDownloaded.check(dep, options)

    if not found and resolvedDep.name != dep.name:
      found = alreadyDownloaded.check(dep, options)
      if found:
        displayWarning(&"Develop package {dep.name} should be renamed to " &
                       resolvedDep.name)

    if found:
      continue

    let pkgInfo = installDevelopPackage(dep, options)
    alreadyDownloaded.incl pkgInfo.metaData.url.removeTrailingGitString

proc developAllDependencies(pkgInfo: PackageInfo, options: var Options, topLevel = false) =
  ## Puts all dependencies of `pkgInfo` (including transitive ones) in develop
  ## mode by cloning their repositories.

  var alreadyDownloadedDependencies {.global.}: HashSet[string]
  alreadyDownloadedDependencies.incl pkgInfo.metaData.url.removeTrailingGitString

  if pkgInfo.hasLockedDeps() and topLevel:
    pkgInfo.developLockedDependencies(alreadyDownloadedDependencies, options)
  else:
    pkgInfo.developFreeDependencies(alreadyDownloadedDependencies, options)

proc updateSyncFile(dependentPkg: PackageInfo, options: Options)

proc updatePathsFile(pkgInfo: PackageInfo, options: Options) =
  let paths = 
    if not options.isLegacy: 
      #TODO improve this (or better the alternative, getDependenciesPaths, so it returns the same type)
      var pathsPaths = initHashSet[seq[string]]()
      for path in options.getPathsAllPkgs():
          pathsPaths.incl @[path]
      pathsPaths
    else:
      pkgInfo.getDependenciesPaths(options)
  var pathsFileContent = "--noNimblePath\n"
  for path in paths:
    for p in path:
      pathsFileContent &= &"--path:{p.escape}\n"
  var action = if fileExists(nimblePathsFileName): "updated" else: "generated"
  writeFile(nimblePathsFileName, pathsFileContent)
  displayInfo(&"\"{nimblePathsFileName}\" is {action}.")

proc develop(options: var Options) =
  if options.action.path.len == 0:
    # If no path is provided, use the vendor folder as default
    options.action.path = defaultDevelopPath
  let
    hasPackages = options.action.packages.len > 0
    hasPath = options.action.path.len > 0
    isDefaultPath = options.action.path == defaultDevelopPath
    hasDevActions = options.action.devActions.len > 0
    hasDevFile = options.developFile.len > 0
    withDependencies = options.action.withDependencies    

  var
    currentDirPkgInfo = initPackageInfo()
    hasError = false

  try:
    # Check whether the current directory is a package directory.
    currentDirPkgInfo = getPkgInfo(getCurrentDir(), options)
  except CatchableError as error:
    if hasDevActions and not hasDevFile:
      raise nimbleError(developOptionsWithoutDevelopFileMsg, details = error)

  if withDependencies and not hasPackages and not currentDirPkgInfo.isLoaded:
    raise nimbleError(developWithDependenciesWithoutPackagesMsg)

  if hasPath and not isDefaultPath and not hasPackages and
     (not currentDirPkgInfo.isLoaded or not withDependencies):
    raise nimbleError(pathGivenButNoPkgsToDownloadMsg)

  if currentDirPkgInfo.isLoaded and (not hasPackages) and (not hasDevActions):
    developFromDir(currentDirPkgInfo, options, topLevel = true)

  # Install each package.
  for pkgTup in options.action.packages:
    try:
      discard installDevelopPackage(pkgTup, options)
    except CatchableError as error:
      hasError = true
      displayError(&"Cannot install package \"{pkgTup}\" for develop.")
      displayDetails(error)

  if currentDirPkgInfo.isLoaded and not hasDevFile:
    options.developFile = developFileName

  if options.developFile.len > 0:
    hasError = not updateDevelopFile(currentDirPkgInfo, options) or hasError
    if currentDirPkgInfo.isLoaded and
       options.developFile == developFileName:
      # If we are updated package's develop file we have to update also
      # sync and paths files.
      updateSyncFile(currentDirPkgInfo, options)
      if fileExists(nimblePathsFileName):
        updatePathsFile(currentDirPkgInfo, options)

  if hasError:
    raise nimbleError(
      "There are some errors while executing the operation.",
      "See the log above for more details.")

proc test(options: Options) =
  ## Executes all tests starting with 't' in the ``tests`` directory.
  ## Subdirectories are not walked.
  var pkgInfo = getPkgInfo(getCurrentDir(), options)

  var
    files = toSeq(walkDir(getCurrentDir() / "tests"))
    tests, failures: int

  if pkgInfo.testEntryPoint != "" :
    if fileExists(pkgInfo.testEntryPoint):
      displayInfo("Using test entry point: " & pkgInfo.testEntryPoint, HighPriority)
      files = @[(kind: pcFile, path: pkgInfo.testEntryPoint)]
    else:
      raise nimbleError("Test entry point not found: " & pkgInfo.testEntryPoint)

  if files.len < 1:
    display("Warning:", "No tests found!", Warning, HighPriority)
    return

  if not execHook(options, actionCustom, true):
    raise nimbleError("Pre-hook prevented further execution.")

  files.sort((a, b) => cmp(a.path, b.path))

  for file in files:
    let (_, name, ext) = file.path.splitFile()
    if ext == ".nim" and name[0] == 't' and file.kind in {pcFile, pcLinkToFile}:
      var optsCopy = options
      optsCopy.action = Action(typ: actionCompile)
      optsCopy.action.file = file.path
      optsCopy.action.additionalArguments = options.action.arguments
      optsCopy.action.backend = pkgInfo.backend
      optsCopy.getCompilationFlags() = options.getCompilationFlags()
      # treat run flags as compile for default test task
      optsCopy.getCompilationFlags().add(options.action.custRunFlags.filterIt(it != "--continue" and it != "-c"))
      optsCopy.getCompilationFlags().add("-r")
      optsCopy.getCompilationFlags().add("--path:.")
      let
        binFileName = file.path.changeFileExt(ExeExt)
        existsBefore = fileExists(binFileName)

      if options.continueTestsOnFailure:
        inc tests
        try:
          execBackend(pkgInfo, optsCopy)
        except NimbleError:
          inc failures
      else:
        execBackend(pkgInfo, optsCopy)

      let
        existsAfter = fileExists(binFileName)
        canRemove = not existsBefore and existsAfter
      if canRemove:
        try:
          removeFile(binFileName)
        except OSError as exc:
          display("Warning:", "Failed to delete " & binFileName & ": " &
                  exc.msg, Warning, MediumPriority)

  if failures == 0:
    display("Success:", "All tests passed", Success, HighPriority)
  else:
    let error = "Only " & $(tests - failures) & "/" & $tests & " tests files passed"
    display("Error:", error, Error, HighPriority)

  if not execHook(options, actionCustom, false):
    return

proc notInRequiredRangeMsg*(dependentPkg, dependencyPkg: PackageInfo,
                            versionRange: VersionRange): string =
  notInRequiredRangeMsg(dependencyPkg.basicInfo.name, dependencyPkg.getNimbleFileDir,
    $dependencyPkg.basicInfo.version, dependentPkg.basicInfo.name, dependentPkg.getNimbleFileDir,
    $versionRange)

proc validateDevelopDependenciesVersionRanges(dependentPkg: PackageInfo,
    dependencies: seq[PackageInfo], options: Options) =
  let allPackages = concat(@[dependentPkg], dependencies)
  let developDependencies = processDevelopDependencies(dependentPkg, options)
  var errors: seq[string]
  for pkg in allPackages:
    for dep in pkg.requires:
      if dep.ver.kind == verSpecial or dep.ver.kind == verAny:
        # Develop packages versions are not being validated against the special
        # versions in the Nimble files requires clauses, because there is no
        # special versions for develop mode packages. If special version is
        # required then any version for the develop package is allowed.
        # Also skip validation for verAny (any version) requirements.
        continue
      var depPkg = initPackageInfo()
      if not findPkg(developDependencies, dep, depPkg):
        # This dependency is not part of the develop mode dependencies.
        continue
      if not withinRange(depPkg, dep.ver):
        errors.add notInRequiredRangeMsg(pkg, depPkg, dep.ver)
  if errors.len > 0:
    raise nimbleError(invalidDevelopDependenciesVersionsMsg(errors))

proc validateParsedDependencies(pkgInfo: PackageInfo, options: Options) =
  displayInfo(&"Validating dependencies for pkgInfo {pkgInfo.infoKind}", HighPriority)
  var options = options
  options.useDeclarativeParser = true
  let declDeps = pkgInfo.toRequiresInfo(options).requires

  options.useDeclarativeParser = false
  let vmDeps = pkgInfo.toFullInfo(options).requires
  displayInfo(&"Parsed declarative dependencies: {declDeps}", HighPriority)
  displayInfo(&"Parsed VM dependencies: {vmDeps}", HighPriority)
  if declDeps != vmDeps:
    raise nimbleError(&"Parsed declarative and VM dependencies are not the same: {declDeps} != {vmDeps}")

proc check(options: Options) =
  try:
    let currentDir = getCurrentDir()
    let pkgInfo = getPkgInfo(currentDir, options, true)
    validateDevelopFile(pkgInfo, options)
    let dependencies = pkgInfo.processAllDependencies(options).toSeq
    validateDevelopDependenciesVersionRanges(pkgInfo, dependencies, options)
    validateParsedDependencies(pkgInfo, options)
    displaySuccess(&"The package \"{pkgInfo.basicInfo.name}\" is valid.")
  except CatchableError as error:
    displayError(error)
    display("Failure:", validationFailedMsg, Error, HighPriority)
    raise nimbleQuit(QuitFailure)

proc updateSyncFile(dependentPkg: PackageInfo, options: Options) =
  # Updates the sync file with the current VCS revisions of develop mode
  # dependencies of the package `dependentPkg`.

  let developDeps = processDevelopDependencies(dependentPkg, options).toHashSet
  let syncFile = getSyncFile(dependentPkg)

  # Remove old data from the sync file
  syncFile.clear

  # Add all current develop packages' VCS revisions to the sync file.
  for dep in developDeps:
    syncFile.setDepVcsRevision(dep.basicInfo.name, dep.metaData.vcsRevision)

  syncFile.save

proc validateDevModeDepsWorkingCopiesBeforeLock(
    pkgInfo: PackageInfo, options: Options): ValidationErrors =
  ## Validates that the develop mode dependencies states are suitable for
  ## locking. They must be under version control, their working copies must be
  ## in a clean state and their current VCS revision must be present on some of
  ## the configured remotes.

  findValidationErrorsOfDevDepsWithLockFile(pkgInfo, options, result)

  # Those validation errors are not errors in the context of generating a lock
  # file.
  const notAnErrorSet = {
    vekWorkingCopyNeedsSync,
    vekWorkingCopyNeedsLock,
    vekWorkingCopyNeedsMerge,
    }

  # Remove not errors from the errors set.
  for name, error in common.dup(result):
    if error.kind in notAnErrorSet:
      result.del name

proc displayLockOperationStart(lockFile: string): bool =
  ## Displays a proper log message for starting generating or updating the lock
  ## file of a package in directory `dir`.

  var doesLockFileExist = lockFile.fileExists
  let msg = if doesLockFileExist:
    updatingTheLockFileMsg
  else:
    generatingTheLockFileMsg
  displayInfo(msg)
  return doesLockFileExist

proc displayLockOperationFinish(didLockFileExist: bool) =
  ## Displays a proper log message for finished generation or update of a lock
  ## file.

  let msg = if didLockFileExist:
    lockFileIsUpdatedMsg
  else:
    lockFileIsGeneratedMsg
  displaySuccess(msg)

proc check(errors: ValidationErrors, graph: LockFileDeps) =
  ## Checks that the dependency graph has no errors
  # throw error only for dependencies that are part of the graph
  var err = errors
  for name, error in errors:
    if name notin graph:
      err.del name

  if err.len > 0:
    raise validationErrors(err)

proc getDependenciesForLocking(pkgInfo: PackageInfo, options: Options):
    seq[PackageInfo] =
  ## Get all of the dependencies and then force the upgrade spec
  var res = pkgInfo.processAllDependencies(options).toSeq.mapIt(it.toFullInfo(options))

  if pkgInfo.hasLockedDeps():
    # if we are performing lock and there is a lock file we make sure that the
    # requires section still applies over the lock dependencies. In case it does
    # not, we upgrade those.
    let
      toUpgrade = if options.action.typ == actionUpgrade:
        options.action.packages
      else:
        pkgInfo.requires

      allRequiredPackages = pkgInfo.processFreeDependencies(toUpgrade, options, res).toSeq
      allRequiredNames = allRequiredPackages.mapIt(it.name)
    res = res.filterIt(it.name notin allRequiredNames)
    res.add allRequiredPackages

  result = res.deleteStaleDependencies(pkgInfo, options).deduplicate

proc lock(options: var Options) =
  ## Generates a lock file for the package in the current directory or updates
  ## it if it already exists.  
  let currentDir = getCurrentDir()
  
  # Clear package info cache to ensure we read the latest nimble file
  # This is important when the nimble file has been modified since the last read
  # In vnext mode, the cache clearing is done before runVNext is called
  if options.isLegacy:
    options.pkgInfoCache.clear()
  
  let
    pkgInfo = if not options.isLegacy:
      options.satResult.rootPackage
    else:
      getPkgInfo(currentDir, options)
    currentLockFile = options.lockFile(currentDir)
    lockExists = displayLockOperationStart(currentLockFile)      
  
  var 
     baseDeps =       
      if not options.isLegacy:
        options.satResult.pkgs.toSeq
      elif options.useSATSolver:
        processFreeDependenciesSAT(pkgInfo, options).toSeq        
      else:
        pkgInfo.getDependenciesForLocking(options) # Deps shared by base and tasks  

  if options.useSystemNim:
    baseDeps = baseDeps.filterIt(not it.name.isNim)

  let baseDepNames: HashSet[string] = baseDeps.mapIt(it.name).toHashSet
  pkgInfo.validateDevelopDependenciesVersionRanges(baseDeps, options)
  
  var
    errors = validateDevModeDepsWorkingCopiesBeforeLock(pkgInfo, options)
    taskDepNames: Table[string, HashSet[string]] # We need to separate the graph into separate tasks later
    allDeps = baseDeps.toHashSet
    lockDeps: AllLockFileDeps

  lockDeps[noTask] = LockFileDeps()
  # Add each individual tasks as partial sub graphs
  for task in pkgInfo.taskRequires.keys:
    var taskOptions = options
    taskOptions.task = task

    let taskDeps = pkgInfo.getDependenciesForLocking(taskOptions)

    pkgInfo.validateDevelopDependenciesVersionRanges(taskDeps, taskOptions)

    # Add in the dependencies that are in this task but not in base
    taskDepNames[task] = initHashSet[string]()
    for dep in taskDeps:
      if dep.name notin baseDepNames:
        taskDepNames[task].incl dep.name
        allDeps.incl dep

    # Now build graph for all dependencies
    taskOptions.checkSatisfied(taskDeps)

  if not options.isLegacy:
    # vnext path: generate lockfile from solved packages
    # Check for develop dependency validation errors
    # Create a minimal graph for error checking - only include actual dependencies, not root package
    #TODO Some errors are not checked here.
    var vnextGraph: LockFileDeps
    let rootPkgName = pkgInfo.basicInfo.name
    
    #TODO in the future we could consider to add it via a flag/when nimble install nim and a develop file is present. By default we should not add it.
    var shouldAddNim = false

    for solvedPkg in options.satResult.solvedPkgs:
      if (not solvedPkg.pkgName.isNim or (shouldAddNim and solvedPkg.pkgName.isNim)) and solvedPkg.pkgName != rootPkgName:
        vnextGraph[solvedPkg.pkgName] = LockFileDep()  # Minimal entry for error checking
    errors.check(vnextGraph)
    for solvedPkg in options.satResult.solvedPkgs:
      if solvedPkg.pkgName.isNim and not shouldAddNim: continue
      
      # Get the PackageInfo for this solved package
      let pkgInfo = options.satResult.getPkgInfoFromSolved(solvedPkg, options)
      var vcsRevision = pkgInfo.metaData.vcsRevision
      
      # For develop mode dependencies, ensure VCS revision is set from working copy
      if (pkgInfo.isLink or (vcsRevision == notSetSha1Hash and pkgInfo.getRealDir().dirExists())) and vcsRevision == notSetSha1Hash:
        try:
          vcsRevision = getVcsRevision(pkgInfo.getRealDir())
        except CatchableError:
          discard
      lockDeps[noTask][pkgInfo.basicInfo.name] = LockFileDep(
        version: solvedPkg.version,
        vcsRevision: vcsRevision,
        url: pkgInfo.metaData.url,
        downloadMethod: pkgInfo.metaData.downloadMethod,
        dependencies: solvedPkg.requirements.mapIt(it.name), 
        checksums: Checksums(sha1: pkgInfo.basicInfo.checksum))
    
    for task in pkgInfo.taskRequires.keys:
      lockDeps[task] = LockFileDeps()
      for (taskDep, _) in pkgInfo.taskRequires[task]:
        for solvedPkg in options.satResult.solvedPkgs:
          if solvedPkg.pkgName == taskDep:
            #Now we have to pick the dep from above
            var found = false
            for key, value in lockDeps[noTask]:
              if key == taskDep:
                lockDeps[task][key] = value
                found = true
                break
            if found: 
              lockDeps[noTask].del(taskDep)
    
    writeLockFile(currentLockFile, lockDeps)
  else:
    # traditional path: use dependency graph
    let graph = buildDependencyGraph(allDeps.toSeq, options)
    errors.check(graph)

    for task in pkgInfo.taskRequires.keys:
      lockDeps[task] = LockFileDeps()

    for dep in topologicalSort(graph).order:
      #ignore root
      if dep == pkgInfo.basicInfo.name: continue
      if dep in baseDepNames:
        lockDeps[noTask][dep] = graph[dep]
      else:
        # Add the dependency for any task that requires it
        for task in pkgInfo.taskRequires.keys:
          if dep in taskDepNames[task]:
            lockDeps[task][dep] = graph[dep]

    writeLockFile(currentLockFile, lockDeps)
  updateSyncFile(pkgInfo, options)
  displayLockOperationFinish(lockExists)

proc depsPrint(options: Options,
              pkgInfo: PackageInfo,
              dependencies: seq[PackageInfo],
              errors: ValidationErrors) =
  ## Prints the dependency tree

  if options.action.format == "json":
    if options.action.depsAction == "inverted":
      raise nimbleError("Deps JSON format does not support inverted tree")
    echo (%depsRecursive(pkgInfo, dependencies, errors)).pretty
  elif options.action.depsAction == "inverted":
    printDepsHumanReadableInverted(pkgInfo, dependencies, errors)
  elif options.action.depsAction == "tree":
    printDepsHumanReadable(pkgInfo, dependencies, errors)
  else:
    printDepsHumanReadable(pkgInfo, dependencies, errors, true)

proc deps(options: Options) =
  ## handles deps actions
  let pkgInfo = getPkgInfo(getCurrentDir(), options)

  var errors = validateDevModeDepsWorkingCopiesBeforeLock(pkgInfo, options)

  let dependencies =  pkgInfo.allDependencies(options).map(
    pkg => pkg.toFullInfo(options)).toSeq
  pkgInfo.validateDevelopDependenciesVersionRanges(dependencies, options)
  var dependencyGraph = buildDependencyGraph(dependencies, options)

  # delete errors for dependencies that aren't part of the graph
  for name, error in common.dup errors:
    if not dependencyGraph.contains name:
      errors.del name

  if options.action.depsAction in ["", "tree", "inverted"]:
    depsPrint(options, pkgInfo, dependencies, errors)
  else:
    raise nimbleError("Unknown deps flag: " & options.action.depsAction)

proc syncWorkingCopy(name: string, path: Path, dependentPkg: PackageInfo,
                     options: Options) =
  ## Syncs a working copy of a develop mode dependency of package `dependentPkg`
  ## with name `name` at path `path` with the revision from the lock file of
  ## `dependentPkg`.

  if options.offline:
    raise nimbleError("Cannot sync in offline mode.")

  displayInfo(&"Syncing working copy of package \"{name}\" at \"{path}\"...")

  let lockedDeps = dependentPkg.lockedDeps[noTask]
  assert lockedDeps.hasKey(name),
         &"Package \"{name}\" must be present in the lock file."

  let vcsRevision = lockedDeps[name].vcsRevision
  assert vcsRevision != path.getVcsRevision,
        "If here the working copy VCS revision must be different from the " &
        "revision written in the lock file."

  try:
    if not isVcsRevisionPresentOnSomeBranch(path, vcsRevision):
      # If the searched revision is not present on some local branch retrieve
      # changes sets from the remote branch corresponding to the local one.
      let (remote, branch) = getCorrespondingRemoteAndBranch(path)
      retrieveRemoteChangeSets(path, remote, branch)

    if not isVcsRevisionPresentOnSomeBranch(path, vcsRevision):
      # If the revision is still not found retrieve all remote change sets.
      retrieveRemoteChangeSets(path)

    let
      currentBranch = getCurrentBranch(path)
      localBranches = getBranchesOnWhichVcsRevisionIsPresent(
        path, vcsRevision, btLocal)
      remoteTrackingBranches = getBranchesOnWhichVcsRevisionIsPresent(
        path, vcsRevision, btRemoteTracking)
      allBranches = localBranches + remoteTrackingBranches

    var targetBranch =
      if allBranches.len == 0:
        # Te revision is not found on any branch.
        ""
      elif localBranches.len == 1:
        # If the revision is present on only one local branch switch to it.
        localBranches.toSeq[0]
      elif localBranches.contains(currentBranch):
        # If the current branch is among the local branches on which the
        # revision is found we have to stay to it.
        currentBranch
      elif remoteTrackingBranches.len == 1:
        # If the revision is found on only one remote tracking branch we have to
        # fast forward merge it to a corresponding local branch and to switch to
        # it.
        remoteTrackingBranches.toSeq[0]
      elif (let (hasBranch, branchName) = hasCorrespondingRemoteBranch(
              path, remoteTrackingBranches); hasBranch):
        # If the current branch has corresponding remote tracking branch on
        # which the revision is found we have to get the name of the remote
        # tracking branch in order to try to fast forward merge it to the local
        # branch.
        branchName
      else:
        # If the revision is found on several branches, but nighter of them is
        # the current one or a remote tracking branch corresponding to the
        # current one then give the user a choice to which branch to switch.
        options.promptList(
          &"The revision \"{vcsRevision}\" is found on multiple branches.\n" &
          "Choose a branch to switch to:",
          allBranches.toSeq.toOpenArray(0, allBranches.len - 1))

    if path.getVcsType == vcsTypeGit and
       remoteTrackingBranches.contains(targetBranch):
      # If the target branch is a remote tracking branch get all local branches
      # which track it.
      let localBranches = getLocalBranchesTrackingRemoteBranch(
        path, targetBranch)
      let localBranch =
        if localBranches.len == 0:
          # There is no local branch tracking the remote branch and we have to
          # get a name for a new branch.
          getLocalBranchName(path, targetBranch)
        elif localBranches.len == 1:
          # There is only one local branch tracking the remote branch.
          localBranches[0]
        else:
          # If there are multiple local branches which track the remote branch
          # then give the user a choice to which to try to fast forward merge
          # the remote branch.
          options.promptList("Choose local branch where to try to fast " &
                             &"forward merge \"{targetBranch}\":",
            localBranches.toOpenArray(0, localBranches.len - 1))
      fastForwardMerge(path, targetBranch, localBranch)
      targetBranch = localBranch

    if targetBranch != "":
      if targetBranch != currentBranch:
        switchBranch(path, targetBranch)
      if path.getVcsRevision != vcsRevision:
        setCurrentBranchToVcsRevision(path, vcsRevision)
    else:
      # If the revision is not found on any branch try to set the package
      # working copy to it in detached state. If the revision is completely
      # missing the operation will fail with exception.
      setWorkingCopyToVcsRevision(path, vcsRevision)

    displayInfo(pkgWorkingCopyIsSyncedMsg(name, $path))
  except CatchableError as error:
    displayError(&"Working copy of package \"{name}\" at path \"{path}\" " &
                  "cannot be synced.")
    displayDetails(error.msg)

proc sync(options: Options) =
  # Syncs working copies of the develop mode dependencies of the current
  # directory package with the revision data from the lock file.

  let currentDir = getCurrentDir()
  let pkgInfo = 
    if not options.isLegacy:
      options.satResult.rootPackage
    else:
      getPkgInfo(currentDir, options)

  if not pkgInfo.areLockedDepsLoaded:
    raise nimbleError("Cannot execute `sync` when lock file is missing.")

  if options.offline:
    raise nimbleError("Cannot execute `sync` in offline mode.")

  if not options.action.listOnly:
    # On `sync` we also want to update Nimble cache with the dependencies'
    # versions from the lock file.
    discard processLockedDependencies(pkgInfo, options)
    if fileExists(nimblePathsFileName):
      updatePathsFile(pkgInfo, options)

  var errors: ValidationErrors
  findValidationErrorsOfDevDepsWithLockFile(pkgInfo, options, errors)

  for name, error in common.dup(errors):
    if not pkgInfo.lockedDeps.hasPackage(name):
      errors.del name
    elif error.kind == vekWorkingCopyNeedsSync:
      if not options.action.listOnly:
        syncWorkingCopy(name, error.path, pkgInfo, options)
      else:
        displayInfo(pkgWorkingCopyNeedsSyncingMsg(name, $error.path))
      # Remove sync errors because we are doing sync.
      errors.del name

  updateSyncFile(pkgInfo, options)

  if errors.len > 0:
    raise validationErrors(errors)

proc append(existingContent: var string; newContent: string) =
  ## Appends `newContent` to the `existingContent` on a new line by inserting it
  ## if the new line doesn't already exist.
  if existingContent.len > 0 and existingContent[^1] != '\n':
    existingContent &= "\n"
  existingContent &= newContent

proc setupNimbleConfig(options: Options) =
  ## Creates `nimble.paths` file containing file system paths to the
  ## dependencies. Includes it in `config.nims` file to make them available
  ## for the compiler.
  const
    configFileVersion = 2
    sectionEnd = "# end Nimble config"
    sectionStart = "# begin Nimble config"
    configFileHeader = &"# begin Nimble config (version {configFileVersion})"
    configFileContentNoLock = fmt"""
{configFileHeader}
when withDir(thisDir(), system.fileExists("{nimblePathsFileName}")):
  include "{nimblePathsFileName}"
{sectionEnd}
"""
    configFileContentWithLock = fmt"""
{configFileHeader}
--noNimblePath
when withDir(thisDir(), system.fileExists("{nimblePathsFileName}")):
  include "{nimblePathsFileName}"
{sectionEnd}
"""

  let
    currentDir = getCurrentDir()
    pkgInfo = getPkgInfo(currentDir, options)
    lockFileExists = options.lockFile(currentDir).fileExists
    configFileContent = if lockFileExists: configFileContentWithLock
                        else: configFileContentNoLock

  updatePathsFile(pkgInfo, options)

  var
    writeFile = false
    fileContent: string

  if fileExists(nimbleConfigFileName):
    fileContent = readFile(nimbleConfigFileName)
    if not fileContent.contains(configFileContent):
      let
        startIndex = fileContent.find(sectionStart)
        endIndex = fileContent.find(sectionEnd)
      if startIndex >= 0 and endIndex >= 0:
        fileContent = fileContent[0..<startIndex] & configFileContent[0 ..< ^1] & fileContent[endIndex + sectionEnd.len .. ^1]
      else:
        fileContent.append(configFileContent)
      writeFile = true
  else:
    fileContent.append(configFileContent)
    writeFile = true

  if writeFile:
    writeFile(nimbleConfigFileName, fileContent)
    displayInfo(&"\"{nimbleConfigFileName}\" is set up.")
  else:
    displayInfo(&"\"{nimbleConfigFileName}\" is already set up.")

proc setupVcsIgnoreFile =
  ## Adds the names of some files which should not be committed to the VCS
  ## ignore file.
  let
    currentDir = getCurrentDir()
    vcsIgnoreFileName = case currentDir.getVcsType
      of vcsTypeGit: gitIgnoreFileName
      of vcsTypeHg: hgIgnoreFileName
      of vcsTypeNone: ""

  if vcsIgnoreFileName.len == 0:
    return

  var
    writeFile = false
    fileContent: string

  if fileExists(vcsIgnoreFileName):
    fileContent = readFile(vcsIgnoreFileName)
    if not fileContent.contains(developFileName):
      fileContent.append(developFileName)
      writeFile = true
    if not fileContent.contains(nimblePathsFileName):
      fileContent.append(nimblePathsFileName)
      writeFile = true
    if not fileContent.contains(nimbledepsFolderName):  
      fileContent.append(nimbledepsFolderName)
      writeFile = true
  else:
    fileContent.append(developFileName)
    fileContent.append(nimblePathsFileName)
    fileContent.append(nimbledepsFolderName)
    writeFile = true

  if writeFile:
    writeFile(vcsIgnoreFileName, fileContent & "\n")

proc setup(options: Options) =
  setupNimbleConfig(options)
  setupVcsIgnoreFile()

proc getAlteredPath(options: Options): string =
  
  let pkgInfo = 
    if not options.isLegacy:
      options.satResult.rootPackage
    else:
      getPkgInfo(getCurrentDir(), options)
  var pkgs =
    if not options.isLegacy:
      options.satResult.pkgs.toSeq.toOrderedSet
    else:
      pkgInfo.processAllDependencies(options).toSeq.toOrderedSet
  pkgs.incl(pkgInfo)

  var paths: seq[string] = @[]
  for pkg in pkgs:
    let fullInfo = pkg.toFullInfo(options)
    for bin, _ in fullInfo.bin:
      let folder = fullInfo.getOutputDir(bin).parentDir.quoteShell
      paths.add folder
  paths.reverse
  let parentDir = options.nimBin.get.path.parentDir
  result = fmt "{getAppDir()}{separator}{paths.join(separator)}{separator}{parentDir}{separator}{getEnv(\"PATH\")}"

proc shellenv(options: var Options) =
  setVerbosity(SilentPriority)
  options.verbosity = SilentPriority
  const prefix = when defined(windows): "set PATH=" else: "export PATH="
  echo prefix & getAlteredPath(options)

proc shell(options: Options) =
  putEnv("PATH", getAlteredPath(options))

  when defined windows:
    var shell = getEnv("ComSpec")
    if shell == "": shell = "powershell"
  else:
    var shell = getEnv("SHELL")
    if shell == "": shell = "bash"

  discard waitForExit startProcess(shell, options = {poParentStreams, poUsePath})

proc getPackageForAction(pkgInfo: PackageInfo, options: Options): PackageInfo =
  ## Returns the `PackageInfo` for the package in `pkgInfo`'s dependencies tree
  ## with the name specified in `options.package`. If `options.package` is empty
  ## or it matches the name of the `pkgInfo` then `pkgInfo` is returned. Raises
  ## a `NimbleError` if the package with the provided name is not found.

  result = initPackageInfo()

  if options.package.len == 0 or pkgInfo.basicInfo.name == options.package:
    return pkgInfo

  if not options.isLegacy:
    # Search through the SAT result packages as the packages are already solved
    for pkg in options.satResult.pkgs:
      if pkg.basicInfo.name == options.package:
        var fullPkg = getPkgInfo(pkg.getRealDir(), options)
        # Explicitly check for develop mode conditions in vnext
        if fullPkg.developFileExists or not fullPkg.myPath.startsWith(options.getPkgsDir):
          fullPkg.isLink = true
        return fullPkg
  else:
    let deps = pkgInfo.processAllDependencies(options)
    for dep in deps:
      if dep.basicInfo.name == options.package:
        return dep.toFullInfo(options)

  raise nimbleError(notFoundPkgWithNameInPkgDepTree(options.package))

proc run(options: Options) =
  var pkgInfo: PackageInfo
  if not options.isLegacy: #At this point we already ran the solver
    pkgInfo = options.satResult.rootPackage
    pkgInfo = getPackageForAction(pkgInfo, options)
  else:
    pkgInfo = getPkgInfo(getCurrentDir(), options)
    pkgInfo = getPackageForAction(pkgInfo, options)

  let binary = options.getCompilationBinary(pkgInfo).get("")
  if binary.len == 0:
    raise nimbleError("Please specify a binary to run")

  if binary notin pkgInfo.bin:
    raise nimbleError(binaryNotDefinedInPkgMsg(binary, pkgInfo.basicInfo.name))

  if not options.isLegacy:
    # In vnext path, build develop mode packages (similar to old code path)
    if pkgInfo.isLink:
      # Use vnext buildPkg for develop mode packages
      let isInRootDir = options.startDir == pkgInfo.myPath.parentDir and 
        options.satResult.rootPackage.basicInfo.name == pkgInfo.basicInfo.name
      buildPkg(pkgInfo, isInRootDir, options)
    
    if options.getCompilationFlags.len > 0:
      displayWarning(ignoringCompilationFlagsMsg)
  else:
    if pkgInfo.isLink: #TODO review this code path for vnext. isLink is related to develop mode
      # If this is not installed package then build the binary.
      pkgInfo.build(options)
    elif options.getCompilationFlags.len > 0:
      displayWarning(ignoringCompilationFlagsMsg)
  
  let binaryPath = pkgInfo.getOutputDir(binary)
  let cmd = quoteShellCommand(binaryPath & options.action.runFlags)
  displayDebug("Executing", cmd)

  let exitCode = cmd.execCmd
  raise nimbleQuit(exitCode)

proc openNimbleManual =
  const NimbleGuideURL = "https://nim-lang.github.io/nimble/index.html"
  display(
    "Opened", "the Nimble guide in your default browser."
  )
  displayInfo("If it did not open, you can try going to the link manually: " & NimbleGuideURL)
  openDefaultBrowser(NimbleGuideURL)

proc solvePkgs(rootPackage: PackageInfo, options: var Options) =
  options.satResult.rootPackage = rootPackage
  options.satResult.rootPackage.requires &= options.extraRequires
  # Add task-specific requirements if a task is being executed
  #Note this wont work until we support taskRequires in the declarative parser
  if options.task.len > 0 and options.task in rootPackage.taskRequires:
    options.satResult.rootPackage.requires &= rootPackage.taskRequires[options.task]
  #when locking we need to add the task requires to the root package
  if options.action.typ == actionLock:
    for task in rootPackage.taskRequires.keys:
      options.satResult.rootPackage.requires &= rootPackage.taskRequires[task]
  
  var pkgList = initPkgList(options.satResult.rootPackage, options)
  options.satResult.rootPackage.enableFeatures(options)
  # echo "BEFORE FIRST PASS"
  # options.debugSATResult()
  # For lock action, always read from nimble file, not from lockfile
  # if rootPackage.hasLockFile(options) and options.action.typ != actionLock:
  #   options.satResult.pass = satLockFile
  
  let resolvedNim = resolveAndConfigureNim(options.satResult.rootPackage, pkgList, options)
  # echo "AFTER FIRST PASS"
  # options.debugSATResult()
  #We set nim in the options here as it is used to get the full info of the packages.
  #Its kinda a big refactor getPkgInfo to parametrize it. At some point we will do it. 
  setNimBin(resolvedNim.pkg.get, options)
  if options.satResult.declarativeParseFailed:
    displayWarning("Declarative parser failed. Will rerun SAT with the VM parser. Please fix your nimble file.")
    for line in options.satResult.declarativeParserErrorLines:
      displayWarning(line)
    options.satResult = initSATResult(satFallbackToVmParser)
    options.satResult.rootPackage = rootPackage
    options.satResult.rootPackage = getPkgInfo(options.satResult.rootPackage.getNimbleFileDir, options).toRequiresInfo(options)
    options.satResult.rootPackage.requires &= options.extraRequires
    options.satResult.rootPackage.enableFeatures(options) 
    # Add task-specific requirements if a task is being executed (fallback path)
    if options.task.len > 0 and options.task in options.satResult.rootPackage.taskRequires:
      options.satResult.rootPackage.requires &= options.satResult.rootPackage.taskRequires[options.task]
    #when locking we need to add the task requires to the root package
    if options.action.typ == actionLock:
      for task in options.satResult.rootPackage.taskRequires.keys:
        options.satResult.rootPackage.requires &= options.satResult.rootPackage.taskRequires[task]
    #Declarative parser failed. So we need to rerun the solver but this time, we allow the parser
    #to fallback to the vm parser
    solvePkgsWithVmParserAllowingFallback(options.satResult.rootPackage, resolvedNim, pkgList, options)
  #Nim used in the new code path (mainly building, except in getPkgInfo) is set here
  options.satResult.nimResolved = resolvedNim #TODO maybe we should consider the sat fallback pass. Not sure if we should just warn the user so the packages are corrected
  options.satResult.pkgs.incl(resolvedNim.pkg.get) #Make sure its in the solution
  nimblesat.addUnique(options.satResult.solvedPkgs, SolvedPackage(pkgName: "nim", version: resolvedNim.version))
  options.satResult.solutionToFullInfo(options)
  if rootPackage.hasLockFile(options): 
    options.satResult.solveLockFileDeps(pkgList, options)

    
  options.satResult.pass = satDone 


proc runVNext*(options: var Options) =
  #Make sure we set the righ verbosity for commands that output info:
  if options.action.typ in {actionShellEnv}:
    setVerbosity(SilentPriority)
    options.verbosity = SilentPriority
  #Install and in consequence builds the packages
  let thereIsNimbleFile = findNimbleFile(getCurrentDir(), error = false, options) != ""
  if thereIsNimbleFile:
    options.satResult = initSATResult(satNimSelection)
    var rootPackage = getPkgInfoFromDirWithDeclarativeParser(getCurrentDir(), options)
    if options.action.typ == actionInstall:
      rootPackage.requires.add(options.action.packages)
    solvePkgs(rootPackage, options)
      # return
  elif options.action.typ == actionInstall:
    #Global install        
    for pkg in options.action.packages:          
      options.satResult = initSATResult(satNimSelection)      
      var rootPackage = downloadPkInfoForPv(pkg, options, doPrompt = true)
      solvePkgs(rootPackage, options)
  # echo "BEFORE INSTALL PKGS"
  # options.debugSATResult()
  options.satResult.installPkgs(options)
  # echo "AFTER INSTALL PKG/S"
  # options.debugSATResult()
  options.satResult.addReverseDeps(options)
  
proc doAction(options: var Options) =
  if options.showHelp:
    writeHelp()
  if options.showVersion:
    writeVersion()
  case options.action.typ
  of actionRefresh:
    refresh(options)
  of actionInstall:
    if options.isLegacy:
      let (_, pkgInfo) = install(options.action.packages, options,
                                doPrompt = true,
                                first = true,
                                fromLockFile = false)
      if options.action.packages.len == 0:
        nimScriptHint(pkgInfo)
      if pkgInfo.foreignDeps.len > 0:
        display("Hint:", "This package requires some external dependencies.",
                Warning, HighPriority)
        display("Hint:", "To install them you may be able to run:",
                Warning, HighPriority)
        for i in 0..<pkgInfo.foreignDeps.len:
          display("Hint:", "  " & pkgInfo.foreignDeps[i], Warning, HighPriority)
  of actionUninstall:
    uninstall(options)
  of actionSearch:
    search(options)
  of actionList:
    if options.action.onlyInstalled:
      listInstalled(options)
    elif options.action.onlyNimBinaries:
      listNimBinaries(options)
    else:
      list(options)
  of actionPath:
    listPaths(options)
  of actionBuild:
    if options.isLegacy:
      build(options)
  of actionClean:
    clean(options)
  of actionRun:
    run(options)
  of actionUpgrade:
    lock(options)
  of actionCompile, actionDoc:
    var pkgInfo = getPkgInfo(getCurrentDir(), options)
    execBackend(pkgInfo, options)
  of actionInit:
    init(options)
  of actionPublish:
    var pkgInfo = getPkgInfo(getCurrentDir(), options)
    publish(pkgInfo, options)
  of actionDump:
    dump(options)
  of actionTasks:
    listTasks(options)
  of actionDevelop:
    develop(options)
  of actionCheck:
    check(options)
  of actionLock:
    lock(options)
    setup(options)
  of actionDeps:
    deps(options)
  of actionSync:
    sync(options)
  of actionSetup:
    setup(options)
  of actionShellEnv:
    shellenv(options)
  of actionShell:
    shell(options)
  of actionNil:
    assert false
  of actionAdd:
    addPackages(options.action.packages, options)
  of actionManual:
    openNimbleManual()
  of actionCustom:
    var optsCopy = options
    optsCopy.task = options.action.command.normalize
    let
      nimbleFile = findNimbleFile(getCurrentDir(), true, options)
      pkgInfo = getPkgInfoFromFile(nimbleFile, optsCopy)

    if optsCopy.task in pkgInfo.nimbleTasks:
      # Make sure we have dependencies for the task.
      # We do that here to make sure that any binaries from dependencies
      # are installed
      if optsCopy.isLegacy:
        discard pkgInfo.processAllDependencies(optsCopy)
      # If valid task defined in nimscript, run it
      var execResult: ExecutionResult[bool]
      if execCustom(nimbleFile, optsCopy, execResult):
        if execResult.hasTaskRequestedCommand():
          var options = execResult.getOptionsForCommand(optsCopy)
          doAction(options)
    elif optsCopy.task == "test":
      # If there is no task defined for the `test` task, we run the pre-defined
      # fallback logic.
      test(optsCopy)
    else:
      raise nimbleError(msg = "Could not find task $1 in $2" %
                              [options.action.command, nimbleFile],
                        hint = "Run `nimble --help` and/or `nimble tasks` for" &
                               " a list of possible commands." & '\n' &
                               "If you want a tutorial on how to use Nimble, run `nimble guide`."
                       )

proc setNimBin*(options: var Options) =
  # Find nim binary and set into options
  if options.nimBin.isSome:
    let nimBin = options.nimBin.get.path
    # --nim:<path> takes priority...
    if nimBin.splitPath().head.len == 0:
      # Just filename, search in PATH - nim_temp shortcut
      let pnim = findExe(nimBin)
      if pnim.len != 0: 
        options.nimBin = some makeNimBin(options, pnim)

    if not fileExists(options.nimBin.get.path):
      raise nimbleError("Unable to find `$1`" % options.nimBin.get.path)

    # when nim is forced via command like don't try to be smart and just return
    # it.
    return

  # first try lock file
  let lockFile = options.lockFile(getCurrentDir())

  if options.hasNimInLockFile():
    for name, dep in lockFile.getLockedDependencies.lockedDepsFor(options):
      if name.isNim:
        let v = dep.version.toVersionRange()
        if isInstalled(name, dep, options):
          options.useNimFromDir(getDependencyDir(name, dep, options), v)
        elif not options.offline:
          let depsOnly = options.depsOnly
          options.depsOnly = false
          let downloadResult = downloadDependency(name, dep, options, false)
          compileNim(options, downloadResult.downloadDir, v)
          options.useNimFromDir(downloadResult.downloadDir, v)
          let pkgInfo = installDependency(initTable[string, LockFileDep](), downloadResult, options, @[])
          options.useNimFromDir(pkgInfo.getRealDir, v)
          options.depsOnly = depsOnly
        break

  # Search PATH to find nim to continue with
  let nimBin = findExe("nim")
  if nimBin != "" or options.useSystemNim: #when using systemNim is on we want to fail if system nim is not found
    options.nimBin = some makeNimBin(options, nimBin)
    return #Prioritize Nim in path

  proc install(package: PkgTuple, options: Options): HashSet[PackageInfo] =
    result = install(@[package], options, doPrompt = false, first = false, fromLockFile = false).deps
  
  if options.nimBin.isNone:
    # Search installed packages to continue with
    let nimVersion = ("nim", VersionRange(kind: verAny))
    let installedPkgs = getInstalledPkgsMin(options.getPkgsDir(), options)
    #Is this actually needed? If so, guard it with the setNimBinaries flag
    # & getInstalledPkgsMin(options.nimBinariesDir, options)
    var pkg = initPackageInfo()
    if findPkg(installedPkgs, nimVersion, pkg):
      options.useNimFromDir(pkg.getRealDir, pkg.basicInfo.version.toVersionRange())
    else:
      # It still no nim found then download and install one to allow parsing of
      # other packages.
      if options.nimBin.isNone and not options.offline and options.prompt("No nim found. Download it now?"):
        for pkg in install(nimVersion, options):
          options.useNimFromDir(pkg.getRealDir, pkg.basicInfo.version.toVersionRange())

  if options.nimBin.isNone:
    raise nimbleError("Unable to find nim")

  # try to switch to the version that is in the develop file
  var pkgInfo: PackageInfo
  try:
    pkgInfo = getPkgInfo(getCurrentDir(), options)
    for pkg in pkgInfo.processDevelopDependencies(options):
      if pkg.name.isNim:
        options.useNimFromDir(pkg.getRealDir, pkg.basicInfo.version.toVersionRange(), true)
        return
    options.pkgInfoCache.clear()
  except NimbleError:
    # not in nimble package
    return


  # when no develop nim, check the versions of the nim dependency if doesnt
  # match the requires try to find/install a matching version before
  # continuing. Note that we have to do 2 passes because we cannot parse the
  # nimble file without nim initially.
  let nimVer = getNimrodVersion(options)
  for require in pkgInfo.requires:
    if require.name.isNim and not withinRange(nimVer, require.ver):
      let installedPkgs = getInstalledPkgsMin(options.getPkgsDir(), options)
      var pkg = initPackageInfo()
      if findPkg(installedPkgs, require, pkg):
        options.useNimFromDir(pkg.getRealDir, require.ver)
      else:
        if not options.offline and options.prompt("No nim version matching $1. Download it now?" % $require.ver):
          for pkg in install(require, options):
            options.useNimFromDir(pkg.getRealDir, require.ver)
        else:
          let msg = "Unsatisfied dependency: " & require.name & " (" & $require.ver & ")"
          raise nimbleError(msg)

when isMainModule:
  var exitCode = QuitSuccess

  var opt: Options
  try:
    opt = parseCmdLine()
    opt.setNimbleDir()
    opt.loadNimbleData()
    if opt.action.typ in {actionTasks, actionRun, actionBuild, actionCompile, actionDevelop}:
      # Implicitly disable package validation for these commands.
      opt.disableValidation = true

    if not opt.isLegacy and opt.action.typ in vNextSupportedActions:
      # For actionCustom, set the task name before calling runVNext
      if opt.action.typ == actionCustom:
        opt.task = opt.action.command.normalize
      runVNext(opt)
    elif not opt.showVersion and not opt.showHelp:
      #Even in vnext some actions need to have set Nim the old way i.e. initAction 
      #TODO review this and write specific logic to set Nim in this scenario.
      opt.setNimBin()
    
    opt.doAction()
  except NimbleQuit as quit:
    exitCode = quit.exitCode
  except CatchableError as error:
    exitCode = QuitFailure
    displayTip()
    echo error.getStackTrace()
    displayError(error)
  finally:
    try:
      let folder = getNimbleTempDir()
      if opt.shouldRemoveTmp(folder):
        removeDir(folder)
    except CatchableError as error:
      displayWarning("Couldn't remove Nimble's temp dir")
      displayDetails(error)

    try:
      saveNimbleData(opt)
    except CatchableError as error:
      exitCode = QuitFailure
      displayError(&"Couldn't save \"{nimbleDataFileName}\".")
      displayDetails(error)

  quit(exitCode)
