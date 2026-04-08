## Build orchestration and path collection. Contains buildFromDir / buildPkg
## plus the helpers used to assemble the `--path` flag list and the bin-symlink
## helper that buildPkg invokes.

import std/[sets, options, os, strutils, tables, strformat]
import packageinfotypes, options, version, packageinfo, common,
  cli, packageparser, tools, packageinstaller, urls,
  declarativeparser, nimscriptexecutor, displaymessages

proc nameMatches*(pkg: PackageInfo, pv: PkgTuple, options: Options): bool =
  let pvName = pv.resolveAlias(options).name
  if pkg.basicInfo.name.toLowerAscii() == pvName.toLowerAscii():
    return true
  if pkg.metaData.url == pv.name:
    return true
  # For file:// URLs, extract directory name and match against package name
  if pv.name.isFileURL:
    let dirName = extractFilePathFromURL(pv.name).lastPathPart.toLowerAscii()
    if pkg.basicInfo.name.toLowerAscii() == dirName:
      return true

proc nameMatches*(pkg: PackageInfo, name: string, options: Options): bool =
  let resolvedName = resolveAlias(name, options).toLowerAscii()
  let pkgName = pkg.basicInfo.name.toLowerAscii()
  let pkgUrl = pkg.metaData.url.toLowerAscii()

  if pkgName == resolvedName or pkgUrl == name.toLowerAscii():
    return true

  # For GitHub URLs, extract repository name and match
  if name.contains("github.com/") and name.contains("/"):
    let repoName = name.split("/")[^1].replace(".git", "").toLowerAscii()
    if pkgName == repoName:
      return true

  return false

proc getPkgInfoFromSolution*(satResult: SATResult, pv: PkgTuple, options: Options): PackageInfo =
  for pkg in satResult.pkgs:
    if pv.isNim and pkg.basicInfo.name.isNim and pkg.basicInfo.version.withinRange(pv.ver): return pkg
    if nameMatches(pkg, pv, options) and pkg.basicInfo.version.withinRange(pv.ver):
      return pkg
  raise newNimbleError[NimbleError]("Package not found in solution: " & $pv)

#We could cache this info in the satResult (if called multiple times down the road)
proc getDepsPkgInfo*(satResult: SATResult, pkgInfo: PackageInfo, options: Options): seq[PackageInfo] =
  for solvedPkg in pkgInfo.requires:
    let depInfo = getPkgInfoFromSolution(satResult, solvedPkg, options)
    result.add(depInfo)

proc expandPaths*(pkgInfo: PackageInfo, nimBin: string, options: Options): seq[string] =
  var pkgInfo = pkgInfo.toFullInfo(options, nimBin = nimBin) #TODO is this needed in VNEXT? I dont think so
  pkgInfo = pkgInfo.toRequiresInfo(options, nimBin = nimBin)
  let baseDir = pkgInfo.getRealDir()
  result = @[baseDir]
  # Also add srcDir if it exists and is different from baseDir
  if pkgInfo.srcDir != "":
    let srcPath = pkgInfo.getNimbleFileDir() / pkgInfo.srcDir
    if srcPath != baseDir and dirExists(srcPath):
      result.add srcPath

  for relativePath in pkgInfo.paths:
    let path = baseDir & "/" & relativePath
    if path.isSubdirOf(baseDir):
      result.add path

proc getPathsToBuildFor*(satResult: SATResult, pkgInfo: PackageInfo, recursive: bool, options: Options): HashSet[string] =
  let nimBin = satResult.nimResolved.getNimBin()
  for depInfo in getDepsPkgInfo(satResult, pkgInfo, options):
    for path in depInfo.expandPaths(nimBin, options):
      result.incl(path)
    if recursive:
      for path in satResult.getPathsToBuildFor(depInfo, recursive = true, options):
        result.incl(path)
  result.incl(pkgInfo.expandPaths(nimBin, options))

proc getPathsAllPkgs*(options: Options, nimBin: string): HashSet[string] =
  let satResult = options.satResult
  for pkg in satResult.pkgs:
    if pkg.basicInfo.name.isNim:
      continue  # Skip nim - it's the compiler, not a library dependency
    for path in pkg.expandPaths(nimBin, options):
      result.incl(path)

proc buildFromDir*(pkgInfo: PackageInfo, paths: HashSet[string],
                   args: seq[string], options: Options, nimBin: string) =
  ## Builds a package as specified by ``pkgInfo``.
  # Handle pre-`build` hook.
  let
    realDir = pkgInfo.getRealDir()
    pkgDir = pkgInfo.myPath.parentDir()
  cd pkgDir: # Make sure `execHook` executes the correct .nimble file.
    if not execHook(nimBin, options, actionBuild, true):
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
      args.add("--path:" & path.quoteShell)
  if options.verbosity >= HighPriority:
    # Hide Nim hints by default
    args.add("--hints:off")
  if options.verbosity == SilentPriority:
    # Hide Nim warnings
    args.add("--warnings:off")
  if options.noColor:
    # Disable coloured output
    args.add("--colors:off")

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

    # Check if we can copy an existing binary from source directory when --noRebuild is used
    if options.action.typ in {actionInstall, actionPath, actionUninstall, actionDevelop, actionUpgrade, actionLock, actionAdd} and
       options.action.noRebuild:
      # When installing from a local directory, check for binary in the original directory
      let sourceBinary =
        if options.startDir != pkgDir:
          options.startDir / bin
        else:
          pkgDir / bin

      if fileExists(sourceBinary):
        # Check if the source binary is up-to-date
        if not pkgInfo.needsRebuild(sourceBinary, realDir, options):
          let targetBinary = outputDir / bin
          display("Skipping", "$1/$2 (up-to-date)" %
                  [pkginfo.basicInfo.name, bin], priority = HighPriority)
          copyFile(sourceBinary, targetBinary)
          when not defined(windows):
            # Preserve executable permissions
            setFilePermissions(targetBinary, getFilePermissions(sourceBinary))
          binariesBuilt.inc()
          continue

    let outputOpt = "-o:" & pkgInfo.getOutputDir(bin).quoteShell
    display("Building", "$1/$2 using $3 backend" %
            [pkginfo.basicInfo.name, bin, pkgInfo.backend], priority = HighPriority)

    # For installed packages, we need to handle srcDir correctly
    let input =
      if pkgInfo.isInstalled and not pkgInfo.isLink and pkgInfo.srcDir != "":
        # For installed packages with srcDir, the source file is in srcDir
        realDir / pkgInfo.srcDir / src.changeFileExt("nim")
      else:
        # For non-installed packages or packages without srcDir, use realDir directly
        realDir / src.changeFileExt("nim")

    let cmd = "$# $# --colors:$# --noNimblePath $# $# $#" % [
      nimBin.quoteShell, pkgInfo.backend, if options.noColor: "off" else: "on", join(args, " "),
      outputOpt, input.quoteShell]
    try:
      doCmd(cmd)
      binariesBuilt.inc()
    except CatchableError as error:
      raise buildFailed(
        &"Build failed for the package: {pkgInfo.basicInfo.name}", details = error)

  if binariesBuilt == 0:
    let binary = options.getCompilationBinary(pkgInfo).get("")
    if binary != "":
      raise nimbleError(binaryNotDefinedInPkgMsg(binary, pkgInfo.basicInfo.name))

    raise nimbleError(
      "No binaries built, did you specify a valid binary name?"
    )

  # Handle post-`build` hook.
  cd pkgDir: # Make sure `execHook` executes the correct .nimble file.
    discard execHook(nimBin, options, actionBuild, false)

proc createBinSymlink*(pkgInfo: PackageInfo, options: Options) =
  var binariesInstalled: HashSet[string]
  let binDir = options.getBinDir()
  let pkgDestDir = pkgInfo.getPkgDest(options)
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
        elif dirExists(pkgDestDir / pkgInfo.binDir):
          pkgInfo.binDir / bin
        else:
          bin

      # For develop mode packages, the binary is in the source directory, not installed directory
      let symlinkDest =
        if pkgInfo.isLink:
          # Develop mode: binary is in the source directory
          pkgInfo.getOutputDir(bin)
        else:
          # Installed package: binary is in the installed directory
          pkgDestDir / binDest

      if not fileExists(symlinkDest):
        raise nimbleError(&"Binary '{bin}' was not found at expected location: {symlinkDest}. BinDir is {binDir}. binDest is {binDest}. pkgDestDir is {pkgDestDir}. isLink is {pkgInfo.isLink}")

      # if fileExists(symlinkDest) and not pkgInfo.isLink:
      #   display("Warning:", ("Binary '$1' was already installed from source" &
      #                       " directory. Will be overwritten.") % bin, Warning,
      #           MediumPriority)
      if not pkgInfo.isLink:
        createDir((pkgDestDir / binDest).parentDir())
      let symlinkFilename = options.getBinDir() / bin.extractFilename
      binariesInstalled.incl(
        setupBinSymlink(symlinkDest, symlinkFilename, options))

proc buildPkg*(nimBin: string, pkgToBuild: PackageInfo, isRootInRootDir: bool, options: Options) {.instrument.} =
  # let paths = getPathsToBuildFor(options.satResult, pkgToBuild, recursive = true, options)
  let paths = getPathsAllPkgs(options, nimBin)
  # echo "Paths ", paths
  # echo "Requires ", pkgToBuild.requires
  # echo "Package ", pkgToBuild.basicInfo.name
  let flags = if options.action.typ in {actionInstall, actionPath, actionUninstall, actionDevelop}:
                options.action.passNimFlags
              elif options.action.typ in { actionRun, actionBuild, actionDoc, actionCompile, actionCustom }:
                options.getCompilationFlags()
              else:
                @[]
  var pkgToBuild = pkgToBuild
  if isRootInRootDir and pkgToBuild.source == psInstalled:
    pkgToBuild.source = psLocal
  buildFromDir(pkgToBuild, paths, "-d:release" & flags, options, nimBin)
  # For globally installed packages, always create symlinks
  # Only skip symlinks if we're building the root package in its own directory
  let shouldCreateSymlinks = not isRootInRootDir or options.action.typ == actionInstall
  if shouldCreateSymlinks:
    createBinSymlink(pkgToBuild, options)
