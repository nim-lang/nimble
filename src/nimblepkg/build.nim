## Build orchestration and path collection. Contains buildFromDir / buildPkg
## plus the helpers used to assemble the `--path` flag list and the bin-symlink
## helper that buildPkg invokes.

import std/[algorithm, sequtils, sets, options, os, strutils, tables, strformat]
import packageinfotypes, options, version, packageinfo, common,
  cli, tools, packageinstaller, urls,
  declarativeparser, nimscriptexecutor, displaymessages
import compat/json
when defined(windows):
  import std/tempfiles
  from nimscriptwrapper import taskCompilerCommandEnv
else:
  import std/posix_utils

const
  nimblePathsFileName* = "nimble.paths"
  nimbleConfigFileName* = "config.nims"
  taskPathsProjectEnv* = "__NIMBLE_TASK_PATHS_PROJECT"
  taskPathsOverrideEnv* = "__NIMBLE_TASK_PATHS_OVERRIDE"
  taskCompilerDirEnv = "__NIMBLE_TASK_COMPILER_DIR"

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

proc expandPaths*(pkgInfo: PackageInfo, nimBin: Option[string], options: Options): seq[string] =
  var pkgInfo = pkgInfo.toRequiresInfo(options, nimBin = nimBin)
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

proc getPathsAllPkgs*(options: Options, nimBin: Option[string]): HashSet[string] =
  let satResult = options.satResult
  for pkg in satResult.pkgs:
    if pkg.basicInfo.name.isNim:
      continue  # Skip nim - it's the compiler, not a library dependency
    for path in pkg.expandPaths(nimBin, options):
      result.incl(path)

proc getFeatureDefines*(pkgInfo: PackageInfo, options: Options): seq[string] =
  let rootName = options.satResult.rootPackage.basicInfo.name
  let packageName = if rootName.len > 0: rootName else: pkgInfo.basicInfo.name
  var defines = getGloballyActiveFeatures().toHashSet
  for feature in options.features:
    defines.incl &"features.{packageName}.{feature}"
  result = toSeq(defines.items).sorted

proc hasFeatureOverride*(options: Options): bool =
  options.action.typ != actionSetup and options.setupFeatures.isSome and
    options.features != options.setupFeatures.get()

proc setTaskPathsOverride*(pkgInfo: PackageInfo, options: Options, nimBin: Option[string]) =
  # A task can invoke Nim itself. Give that compiler the invocation's paths and
  # defines without changing the saved configuration used by other processes.
  if options.hasFeatureOverride():
    let dir = getNimbleTempDir()
    createDir(dir)
    let file = dir / "task-paths.json"
    writeFile(file, $(%*{
      "paths": toSeq(options.getPathsAllPkgs(nimBin).items),
      "defines": pkgInfo.getFeatureDefines(options)
    }))
    putEnv(taskPathsProjectEnv, getCurrentDir())
    putEnv(taskPathsOverrideEnv, file)

proc hasConfiguredFeatures(): bool =
  if fileExists(nimblePathsFileName):
    for line in lines(nimblePathsFileName):
      if line.strip(leading = true, trailing = false).startsWith("--define:\"features."):
        return true

proc writeTaskCompiler(dir: string, paths: HashSet[string], featureDefines: seq[string],
                       nimBin: Option[string]) =
  let pathCompiler = findExe("nim")
  let compiler = if pathCompiler.len > 0: pathCompiler else: nimBin.getNimBin
  var flags = @["-d:NimbleManagedCompilation"]
  for path in paths:
    flags.add quoteShell("--path:" & path)
  for feature in featureDefines:
    flags.add quoteShell("-d:" & feature)
  when defined(windows):
    let command = compiler.quoteShell & " " & flags.join(" ")
    writeFile(dir / "nim.cmd", "@echo off\r\n" & command & " %*\r\n")
    putEnv(taskCompilerCommandEnv, command)
  else:
    let script = dir / "nim"
    writeFile(script, "#!/bin/sh\nexec " & compiler.quoteShell & " " &
      flags.join(" ") & " \"$@\"\n")
    setFilePermissions(script, {fpUserRead, fpUserWrite, fpUserExec})

proc clearTaskCompiler*() =
  let dir = getEnv(taskCompilerDirEnv)
  if dir.len > 0:
    let path = getEnv("PATH").split(PathSep).filterIt(it != dir)
    putEnv("PATH", path.join($PathSep))
    delEnv(taskCompilerDirEnv)
  when defined(windows):
    delEnv(taskCompilerCommandEnv)

template withTaskCompiler*(paths: HashSet[string], featureDefines: seq[string],
                           nimBin: Option[string], body: untyped) =
  # Bare Nim calls need the resolved features even if nimble.paths contains
  # a selection from an earlier invocation and the current selection is empty.
  if featureDefines.len > 0 or hasConfiguredFeatures():
    let dir =
      when defined(windows): createTempDir("nimble-task-compiler-", "")
      else: mkdtemp(getTempDir() / "nimble-task-compiler-")
    defer: removeDir(dir)
    try:
      writeTaskCompiler(dir, paths, featureDefines, nimBin)
      putEnv(taskCompilerDirEnv, dir)
      putEnv("PATH", dir & PathSep & getEnv("PATH"))
      body
    finally:
      clearTaskCompiler()
  else:
    body

proc setTaskPathsEnv*(paths: HashSet[string]) =
  ## Hands the solved packages' paths, the task's `taskRequires` included, to
  ## `getPaths()`/`getPathsClause()` in the task's NimScript, which reads them
  ## from `__NIMBLE_PATHS` (see nimscriptapi.nim). Quoted, as tasks splice
  ## `getPathsClause()` into the commands they `exec`.
  putEnv("__NIMBLE_PATHS", toSeq(paths.items).map(quoteShell).join("|"))

proc buildFromDir*(pkgInfo: PackageInfo, paths: HashSet[string],
                   args: seq[string], options: Options, nimBin: Option[string]) =
  ## Builds a package as specified by ``pkgInfo``.
  # Handle pre-`build` hook.
  let
    realDir = pkgInfo.getRealDir()
    pkgDir = pkgInfo.myPath.parentDir()
  let featureDefines = pkgInfo.getFeatureDefines(options)
  cd pkgDir: # Make sure `execHook` executes the correct .nimble file.
    withTaskCompiler(paths, featureDefines, nimBin):
      if not execHook(nimBin, options, actionBuild, true, featureDefines):
        raise nimbleError("Pre-hook prevented further execution.")

  if pkgInfo.bin.len == 0:
    raise nimbleError(
        "Nothing to build. Did you specify a module to build using the" &
        " `bin` key in your .nimble file?")

  var
    binariesBuilt = 0
    args = args
  args.add "-d:NimblePkgVersion=" & $pkgInfo.basicInfo.version
  args.add "-d:NimbleManagedCompilation"
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

  for feature in featureDefines:
    args.add quoteShell("-d:" & feature)

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
      nimBin.getNimBin.quoteShell, pkgInfo.backend, if options.noColor: "off" else: "on", join(args, " "),
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
    withTaskCompiler(paths, featureDefines, nimBin):
      discard execHook(nimBin, options, actionBuild, false, featureDefines)

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

proc buildPkg*(nimBin: Option[string], pkgToBuild: PackageInfo, isRootInRootDir: bool, options: Options) {.instrument.} =
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
