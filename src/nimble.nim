# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import system except TResult

import os, tables, strtabs, json, algorithm, sets, uri, sugar, sequtils, osproc
import std/options as std_opt

import strutils except toLower
from unicode import toLower
from sequtils import toSeq
from strformat import fmt

import nimblepkg/packageinfo, nimblepkg/version, nimblepkg/tools,
       nimblepkg/download, nimblepkg/config, nimblepkg/common,
       nimblepkg/publish, nimblepkg/options, nimblepkg/packageparser,
       nimblepkg/cli, nimblepkg/packageinstaller, nimblepkg/reversedeps,
       nimblepkg/nimscriptexecutor, nimblepkg/init

import nimblepkg/nimscriptwrapper

proc refresh(options: Options) =
  ## Downloads the package list from the specified URL.
  ##
  ## If the download is not successful, an exception is raised.
  let parameter =
    if options.action.typ == actionRefresh:
      options.action.optionalURL
    else:
      ""

  if parameter.len > 0:
    if parameter.isUrl:
      let cmdLine = PackageList(name: "commandline", urls: @[parameter])
      fetchList(cmdLine, options)
    else:
      if parameter notin options.config.packageLists:
        let msg = "Package list with the specified name not found."
        raise newException(NimbleError, msg)

      fetchList(options.config.packageLists[parameter], options)
  else:
    # Try each package list in config
    for name, list in options.config.packageLists:
      fetchList(list, options)

proc install(packages: seq[PkgTuple],
             options: Options,
             doPrompt = true): tuple[deps: seq[PackageInfo], pkg: PackageInfo]
proc processDeps(pkginfo: PackageInfo, options: Options): seq[PackageInfo] =
  ## Verifies and installs dependencies.
  ##
  ## Returns the list of PackageInfo (for paths) to pass to the compiler
  ## during build phase.
  result = @[]
  assert(not pkginfo.isMinimal, "processDeps needs pkginfo.requires")
  display("Verifying",
          "dependencies for $1@$2" % [pkginfo.name, pkginfo.specialVersion],
          priority = HighPriority)

  var pkgList {.global.}: seq[tuple[pkginfo: PackageInfo, meta: MetaData]] = @[]
  once: pkgList = getInstalledPkgsMin(options.getPkgsDir(), options)
  var reverseDeps: seq[tuple[name, version: string]] = @[]
  for dep in pkginfo.requires:
    if dep.name == "nimrod" or dep.name == "nim":
      let nimVer = getNimrodVersion(options)
      if not withinRange(nimVer, dep.ver):
        let msg = "Unsatisfied dependency: " & dep.name & " (" & $dep.ver & ")"
        raise newException(NimbleError, msg)
    else:
      let resolvedDep = dep.resolveAlias(options)
      display("Checking", "for $1" % $resolvedDep, priority = MediumPriority)
      var pkg: PackageInfo
      var found = findPkg(pkgList, resolvedDep, pkg)
      # Check if the original name exists.
      if not found and resolvedDep.name != dep.name:
        display("Checking", "for $1" % $dep, priority = MediumPriority)
        found = findPkg(pkgList, dep, pkg)
        if found:
          display("Warning:", "Installed package $1 should be renamed to $2" %
                  [dep.name, resolvedDep.name], Warning, HighPriority)

      if not found:
        display("Installing", $resolvedDep, priority = HighPriority)
        let toInstall = @[(resolvedDep.name, resolvedDep.ver)]
        let (pkgs, installedPkg) = install(toInstall, options)
        result.add(pkgs)

        pkg = installedPkg # For addRevDep

        # This package has been installed so we add it to our pkgList.
        pkgList.add((pkg, readMetaData(pkg.getRealDir())))
      else:
        display("Info:", "Dependency on $1 already satisfied" % $dep,
                priority = HighPriority)
        result.add(pkg)
        # Process the dependencies of this dependency.
        result.add(processDeps(pkg.toFullInfo(options), options))
      reverseDeps.add((pkg.name, pkg.specialVersion))

  # Check if two packages of the same name (but different version) are listed
  # in the path.
  var pkgsInPath: StringTableRef = newStringTable(modeCaseSensitive)
  for pkgInfo in result:
    let currentVer = pkgInfo.getConcreteVersion(options)
    if pkgsInPath.hasKey(pkgInfo.name) and
       pkgsInPath[pkgInfo.name] != currentVer:
      raise newException(NimbleError,
        "Cannot satisfy the dependency on $1 $2 and $1 $3" %
          [pkgInfo.name, currentVer, pkgsInPath[pkgInfo.name]])
    pkgsInPath[pkgInfo.name] = currentVer

  # We add the reverse deps to the JSON file here because we don't want
  # them added if the above errorenous condition occurs
  # (unsatisfiable dependendencies).
  # N.B. NimbleData is saved in installFromDir.
  for i in reverseDeps:
    addRevDep(options.nimbleData, i, pkginfo)

proc buildFromDir(
  pkgInfo: PackageInfo, paths, args: seq[string],
  options: Options
) =
  ## Builds a package as specified by ``pkgInfo``.
  # Handle pre-`build` hook.
  let
    realDir = pkgInfo.getRealDir()
    pkgDir = pkgInfo.myPath.parentDir()
  cd pkgDir: # Make sure `execHook` executes the correct .nimble file.
    if not execHook(options, actionBuild, true):
      raise newException(NimbleError, "Pre-hook prevented further execution.")

  if pkgInfo.bin.len == 0:
    raise newException(NimbleError,
        "Nothing to build. Did you specify a module to build using the" &
        " `bin` key in your .nimble file?")
  var
    binariesBuilt = 0
    args = args
  args.add "-d:NimblePkgVersion=" & pkgInfo.version
  for path in paths:
    args.add("--path:" & path.quoteShell)
  if options.verbosity >= HighPriority:
    # Hide Nim hints by default
    args.add("--hints:off")
  if options.verbosity == SilentPriority:
    # Hide Nim warnings
    args.add("--warnings:off")

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

    let outputOpt = "-o:" & pkgInfo.getOutputDir(bin).quoteShell
    display("Building", "$1/$2 using $3 backend" %
            [pkginfo.name, bin, pkgInfo.backend], priority = HighPriority)

    let outputDir = pkgInfo.getOutputDir("")
    if not dirExists(outputDir):
      createDir(outputDir)

    let input = realDir / src.changeFileExt("nim")
    # `quoteShell` would be more robust than `\"` (and avoid quoting when
    # un-necessary) but would require changing `extractBin`
    let cmd = "$# $# --colors:on --noNimblePath $# $# $#" % [
      getNimBin(options).quoteShell, pkgInfo.backend, join(args, " "),
      outputOpt, input.quoteShell]
    try:
      doCmd(cmd)
      binariesBuilt.inc()
    except NimbleError:
      let currentExc = (ref NimbleError)(getCurrentException())
      let exc = newException(BuildFailed, "Build failed for package: " &
                             pkgInfo.name)
      let (error, hint) = getOutputInfo(currentExc)
      exc.msg.add("\n" & error)
      exc.hint = hint
      raise exc

  if binariesBuilt == 0:
    raiseNimbleError(
      "No binaries built, did you specify a valid binary name?"
    )

  # Handle post-`build` hook.
  cd pkgDir: # Make sure `execHook` executes the correct .nimble file.
    discard execHook(options, actionBuild, false)

proc removePkgDir(dir: string, options: Options) =
  ## Removes files belonging to the package in ``dir``.
  try:
    var nimblemeta = parseFile(dir / "nimblemeta.json")
    if not nimblemeta.hasKey("files"):
      raise newException(JsonParsingError,
                         "Meta data does not contain required info.")
    for file in nimblemeta["files"]:
      removeFile(dir / file.str)

    removeFile(dir / "nimblemeta.json")

    # If there are no files left in the directory, remove the directory.
    if toSeq(walkDirRec(dir)).len == 0:
      removeDir(dir)
    else:
      display("Warning:", ("Cannot completely remove $1. Files not installed " &
              "by nimble are present.") % dir, Warning, HighPriority)

    if nimblemeta.hasKey("binaries"):
      # Remove binaries.
      for binary in nimblemeta["binaries"]:
        removeFile(options.getBinDir() / binary.str)

      # Search for an older version of the package we are removing.
      # So that we can reinstate its symlink.
      let (pkgName, _) = getNameVersion(dir)
      let pkgList = getInstalledPkgsMin(options.getPkgsDir(), options)
      var pkgInfo: PackageInfo
      if pkgList.findPkg((pkgName, newVRAny()), pkgInfo):
        pkgInfo = pkgInfo.toFullInfo(options)
        for bin, src in pkgInfo.bin:
          let symlinkDest = pkgInfo.getOutputDir(bin)
          let symlinkFilename = options.getBinDir() / bin.extractFilename
          discard setupBinSymlink(symlinkDest, symlinkFilename, options)
    else:
      display("Warning:", ("Cannot completely remove $1. Binary symlinks may " &
                          "have been left over in $2.") %
                          [dir, options.getBinDir()])
  except OSError, JsonParsingError:
    display("Warning", "Unable to read nimblemeta.json: " &
            getCurrentExceptionMsg(), Warning, HighPriority)
    if not options.prompt("Would you like to COMPLETELY remove ALL files " &
                          "in " & dir & "?"):
      raise NimbleQuit(msg: "")
    removeDir(dir)

proc vcsRevisionInDir(dir: string): string =
  ## Returns current revision number of HEAD if dir is inside VCS, or nil in
  ## case of failure.
  var cmd = ""
  if dirExists(dir / ".git"):
    cmd = "git -C " & quoteShell(dir) & " rev-parse HEAD"
  elif dirExists(dir / ".hg"):
    cmd = "hg --cwd " & quoteShell(dir) & " id -i"

  if cmd.len > 0:
    try:
      let res = doCmdEx(cmd)
      if res.exitCode == 0:
        result = string(res.output).strip()
    except:
      discard

proc installFromDir(dir: string, requestedVer: VersionRange, options: Options,
                    url: string): tuple[
                      deps: seq[PackageInfo],
                      pkg: PackageInfo
                    ] =
  ## Returns where package has been installed to, together with paths
  ## to the packages this package depends on.
  ## The return value of this function is used by
  ## ``processDeps`` to gather a list of paths to pass to the nim compiler.

  # Handle pre-`install` hook.
  if not options.depsOnly:
    cd dir: # Make sure `execHook` executes the correct .nimble file.
      if not execHook(options, actionInstall, true):
        raise newException(NimbleError, "Pre-hook prevented further execution.")

  var pkgInfo = getPkgInfo(dir, options)
  let realDir = pkgInfo.getRealDir()
  let binDir = options.getBinDir()
  var depsOptions = options
  depsOptions.depsOnly = false

  # Overwrite the version if the requested version is "#head" or similar.
  if requestedVer.kind == verSpecial:
    pkgInfo.specialVersion = $requestedVer.spe

  # Dependencies need to be processed before the creation of the pkg dir.
  result.deps = processDeps(pkgInfo, depsOptions)

  if options.depsOnly:
    result.pkg = pkgInfo
    return result

  display("Installing", "$1@$2" % [pkginfo.name, pkginfo.specialVersion],
          priority = HighPriority)

  # Build before removing an existing package (if one exists). This way
  # if the build fails then the old package will still be installed.
  if pkgInfo.bin.len > 0:
    let paths = result.deps.map(dep => dep.getRealDir())
    let flags = if options.action.typ in {actionInstall, actionPath, actionUninstall, actionDevelop}:
                  options.action.passNimFlags
                else:
                  @[]
    buildFromDir(pkgInfo, paths, "-d:release" & flags, options)

  # Don't copy artifacts if project local deps mode and "installing" the top level package
  if not (options.localdeps and options.isInstallingTopLevel(dir)):
    let pkgDestDir = pkgInfo.getPkgDest(options)
    if dirExists(pkgDestDir) and fileExists(pkgDestDir / "nimblemeta.json"):
      let msg = "$1@$2 already exists. Overwrite?" %
                [pkgInfo.name, pkgInfo.specialVersion]
      if not options.prompt(msg):
        return

      # Remove reverse deps.
      let pkgInfo = getPkgInfo(pkgDestDir, options)
      options.nimbleData.removeRevDep(pkgInfo)

      removePkgDir(pkgDestDir, options)
      # Remove any symlinked binaries
      for bin, src in pkgInfo.bin:
        # TODO: Check that this binary belongs to the package being installed.
        when defined(windows):
          removeFile(binDir / bin.changeFileExt("cmd"))
          removeFile(binDir / bin.changeFileExt(""))
        else:
          removeFile(binDir / bin)

    createDir(pkgDestDir)
    # Copy this package's files based on the preferences specified in PkgInfo.
    var filesInstalled = initHashSet[string]()
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

    var binariesInstalled = initHashSet[string]()
    if pkgInfo.bin.len > 0:
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
        for filename in setupBinSymlink(symlinkDest, symlinkFilename, options):
          binariesInstalled.incl(filename)

    let vcsRevision = vcsRevisionInDir(realDir)

    # Save a nimblemeta.json file.
    saveNimbleMeta(pkgDestDir, url, vcsRevision, filesInstalled,
                  binariesInstalled)

    # Save the nimble data (which might now contain reverse deps added in
    # processDeps).
    saveNimbleData(options)

    # update package path to point to installed directory rather than the temp directory
    pkgInfo.myPath = dest
  else:
    display("Warning:", "Skipped copy in project local deps mode", Warning)

  pkgInfo.isInstalled = true

  # Return the dependencies of this package (mainly for paths).
  result.deps.add pkgInfo
  result.pkg = pkgInfo

  display("Success:", pkgInfo.name & " installed successfully.",
          Success, HighPriority)

  # Run post-install hook now that package is installed. The `execHook` proc
  # executes the hook defined in the CWD, so we set it to where the package
  # has been installed.
  cd pkgInfo.myPath.splitFile.dir:
    discard execHook(options, actionInstall, false)

proc getDownloadInfo*(pv: PkgTuple, options: Options,
                      doPrompt: bool): (DownloadMethod, string,
                                        Table[string, string]) =
  if pv.name.isURL:
    let (url, metadata) = getUrlData(pv.name)
    return (checkUrlType(url), url, metadata)
  else:
    var pkg: Package
    if getPackage(pv.name, options, pkg):
      let (url, metadata) = getUrlData(pkg.url)
      return (pkg.downloadMethod.getDownloadMethod(), url, metadata)
    else:
      # If package is not found give the user a chance to refresh
      # package.json
      if doPrompt and
          options.prompt(pv.name & " not found in any local packages.json, " &
                         "check internet for updated packages?"):
        refresh(options)

        # Once we've refreshed, try again, but don't prompt if not found
        # (as we've already refreshed and a failure means it really
        # isn't there)
        return getDownloadInfo(pv, options, false)
      else:
        raise newException(NimbleError, "Package not found.")

proc install(packages: seq[PkgTuple],
             options: Options,
             doPrompt = true): tuple[deps: seq[PackageInfo], pkg: PackageInfo] =
  if packages == @[]:
    result = installFromDir(getCurrentDir(), newVRAny(), options, "")
  else:
    # Install each package.
    for pv in packages:
      let (meth, url, metadata) = getDownloadInfo(pv, options, doPrompt)
      let subdir = metadata.getOrDefault("subdir")
      let (downloadDir, downloadVersion) =
          downloadPkg(url, pv.ver, meth, subdir, options)
      try:
        result = installFromDir(downloadDir, pv.ver, options, url)
      except BuildFailed:
        # The package failed to build.
        # Check if we tried building a tagged version of the package.
        let headVer = getHeadName(meth)
        if pv.ver.kind != verSpecial and downloadVersion != headVer:
          # If we tried building a tagged version of the package then
          # ask the user whether they want to try building #head.
          let promptResult = doPrompt and
              options.prompt(("Build failed for '$1@$2', would you" &
                  " like to try installing '$1@#head' (latest unstable)?") %
                  [pv.name, $downloadVersion])
          if promptResult:
            let toInstall = @[(pv.name, headVer.toVersionRange())]
            result = install(toInstall, options, doPrompt)
          else:
            raise newException(BuildFailed,
              "Aborting installation due to build failure")
        else:
          raise

proc build(options: Options) =
  var pkgInfo = getPkgInfo(getCurrentDir(), options)
  nimScriptHint(pkgInfo)
  let deps = processDeps(pkginfo, options)
  let paths = deps.map(dep => dep.getRealDir())
  var args = options.getCompilationFlags()
  buildFromDir(pkgInfo, paths, args, options)

proc execBackend(pkgInfo: PackageInfo, options: Options) =
  let
    bin = options.getCompilationBinary(pkgInfo).get("")
    binDotNim = bin.addFileExt("nim")
  if bin == "":
    raise newException(NimbleError, "You need to specify a file.")

  if not (fileExists(bin) or fileExists(binDotNim)):
    raise newException(NimbleError,
      "Specified file, " & bin & " or " & binDotNim & ", does not exist.")

  var pkgInfo = getPkgInfo(getCurrentDir(), options)
  nimScriptHint(pkgInfo)
  let deps = processDeps(pkginfo, options)

  if not execHook(options, options.action.typ, true):
    raise newException(NimbleError, "Pre-hook prevented further execution.")

  var args = @["-d:NimblePkgVersion=" & pkgInfo.version]
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
            [bin, pkgInfo.name, backend], priority = HighPriority)
  else:
    display("Generating", ("documentation for $1 (from package $2) using $3 " &
            "backend") % [bin, pkgInfo.name, backend], priority = HighPriority)
  doCmd(getNimBin(options).quoteShell & " $# --noNimblePath $# $#" %
        [backend, join(args, " "), bin.quoteShell])
  display("Success:", "Execution finished", Success, HighPriority)

  # Run the post hook for action if it exists
  discard execHook(options, options.action.typ, false)

proc search(options: Options) =
  ## Searches for matches in ``options.action.search``.
  ##
  ## Searches are done in a case insensitive way making all strings lower case.
  assert options.action.typ == actionSearch
  if options.action.search == @[]:
    raise newException(NimbleError, "Please specify a search string.")
  if needsRefresh(options):
    raise newException(NimbleError, "Please run nimble refresh.")
  let pkgList = getPackageList(options)
  var found = false
  template onFound {.dirty.} =
    echoPackage(pkg)
    if pkg.alias.len == 0 and options.queryVersions:
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
    raise newException(NimbleError, "Please run nimble refresh.")
  let pkgList = getPackageList(options)
  for pkg in pkgList:
    echoPackage(pkg)
    if pkg.alias.len == 0 and options.queryVersions:
      echoPackageVersions(pkg)
    echo(" ")

proc listInstalled(options: Options) =
  var h = initOrderedTable[string, seq[string]]()
  let pkgs = getInstalledPkgsMin(options.getPkgsDir(), options)
  for x in pkgs.items():
    let
      pName = x.pkginfo.name
      pVer = x.pkginfo.specialVersion
    if not h.hasKey(pName): h[pName] = @[]
    var s = h[pName]
    add(s, pVer)
    h[pName] = s

  h.sort(proc (a, b: (string, seq[string])): int = cmpIgnoreCase(a[0], b[0]))
  for k in keys(h):
    echo k & "  [" & h[k].join(", ") & "]"

type VersionAndPath = tuple[version: Version, path: string]

proc listPaths(options: Options) =
  ## Loops over the specified packages displaying their installed paths.
  ##
  ## If there are several packages installed, only the last one (the version
  ## listed in the packages.json) will be displayed. If any package name is not
  ## found, the proc displays a missing message and continues through the list,
  ## but at the end quits with a non zero exit error.
  ##
  ## On success the proc returns normally.
  cli.setSuppressMessages(true)
  assert options.action.typ == actionPath

  if options.action.packages.len == 0:
    raise newException(NimbleError, "A package name needs to be specified")

  var errors = 0
  let pkgs = getInstalledPkgsMin(options.getPkgsDir(), options)
  for name, version in options.action.packages.items:
    var installed: seq[VersionAndPath] = @[]
    # There may be several, list all available ones and sort by version.
    for x in pkgs.items():
      let
        pName = x.pkginfo.name
        pVer = x.pkginfo.specialVersion
      if name == pName:
        var v: VersionAndPath
        v.version = newVersion(pVer)
        v.path = x.pkginfo.getRealDir()
        installed.add(v)

    if installed.len > 0:
      sort(installed, cmp[VersionAndPath], Descending)
      # The output for this command is used by tools so we do not use display().
      echo installed[0].path
    else:
      display("Warning:", "Package '$1' is not installed" % name, Warning,
              MediumPriority)
      errors += 1
  if errors > 0:
    raise newException(NimbleError,
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
    var skeletonInfo: PackageInfo
    if not findPkg(packages, identTuple, skeletonInfo):
      raise newException(NimbleError,
          "Specified package not found"
      )
    result = getPkgInfoFromFile(skeletonInfo.myPath, options)

# import std/jsonutils
proc `%`(a: Version): JsonNode = %a.string

# proc dump(options: Options, json: bool) =
proc dump(options: Options) =
  cli.setSuppressMessages(true)
  let p = getPackageByPattern(options.action.projName, options)
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
  fn "name", p.name
  fn "version", p.version
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
  fn "bin", toSeq(p.bin.keys)
  fn "binDir", p.binDir
  fn "srcDir", p.srcDir
  fn "backend", p.backend
  if json:
    s = j.pretty
  echo s

proc init(options: Options) =
  # Check whether the vcs is installed.
  let vcsBin = options.action.vcsOption
  if vcsBin != "" and findExe(vcsBin, true) == "":
    raise newException(NimbleError, "Please install git or mercurial first")

  # Determine the package name.
  let pkgName =
    if options.action.projName != "":
      options.action.projName
    else:
      os.getCurrentDir().splitPath.tail.toValidPackageName()

  # Validate the package name.
  validatePackageName(pkgName)

  # Determine the package root.
  let pkgRoot =
    if pkgName == os.getCurrentDir().splitPath.tail:
      os.getCurrentDir()
    else:
      os.getCurrentDir() / pkgName

  let nimbleFile = (pkgRoot / pkgName).changeFileExt("nimble")

  if fileExists(nimbleFile):
    let errMsg = "Nimble file already exists: $#" % nimbleFile
    raise newException(NimbleError, errMsg)

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

proc uninstall(options: Options) =
  if options.action.packages.len == 0:
    raise newException(NimbleError,
        "Please specify the package(s) to uninstall.")

  var pkgsToDelete: HashSet[PackageInfo]
  pkgsToDelete.init()
  # Do some verification.
  for pkgTup in options.action.packages:
    display("Looking", "for $1 ($2)" % [pkgTup.name, $pkgTup.ver],
            priority = HighPriority)
    let installedPkgs = getInstalledPkgsMin(options.getPkgsDir(), options)
    var pkgList = findAllPkgs(installedPkgs, pkgTup)
    if pkgList.len == 0:
      raise newException(NimbleError, "Package not found")

    display("Checking", "reverse dependencies", priority = HighPriority)
    for pkg in pkgList:
      # Check whether any packages depend on the ones the user is trying to
      # uninstall.
      if options.uninstallRevDeps:
        getAllRevDeps(options, pkg, pkgsToDelete)
      else:
        let
          revDeps = getRevDeps(options, pkg)
        var reason = ""
        for revDep in revDeps:
          if reason.len != 0: reason.add ", "
          reason.add("$1 ($2)" % [revDep.name, revDep.version])
        if reason.len != 0:
          reason &= " depend" & (if revDeps.len == 1: "s" else: "") & " on it"

        if len(revDeps - pkgsToDelete) > 0:
          display("Cannot", "uninstall $1 ($2) because $3" %
                  [pkgTup.name, pkg.specialVersion, reason], Warning, HighPriority)
        else:
          pkgsToDelete.incl pkg

  if pkgsToDelete.len == 0:
    raise newException(NimbleError, "Failed uninstall - no packages to delete")

  var pkgNames = ""
  for pkg in pkgsToDelete.items:
    if pkgNames.len != 0: pkgNames.add ", "
    pkgNames.add("$1 ($2)" % [pkg.name, pkg.specialVersion])

  # Let's confirm that the user wants these packages removed.
  let msg = ("The following packages will be removed:\n  $1\n" &
            "Do you wish to continue?") % pkgNames
  if not options.prompt(msg):
    raise NimbleQuit(msg: "")

  for pkg in pkgsToDelete:
    # If we reach this point then the package can be safely removed.

    # removeRevDep needs the package dependency info, so we can't just pass
    # a minimal pkg info.
    removeRevDep(options.nimbleData, pkg.toFullInfo(options))
    removePkgDir(options.getPkgsDir / (pkg.name & '-' & pkg.specialVersion),
                 options)
    display("Removed", "$1 ($2)" % [pkg.name, $pkg.specialVersion], Success,
            HighPriority)

  saveNimbleData(options)

proc listTasks(options: Options) =
  let nimbleFile = findNimbleFile(getCurrentDir(), true)
  nimscriptwrapper.listTasks(nimbleFile, options)

proc developFromDir(dir: string, options: Options) =
  cd dir: # Make sure `execHook` executes the correct .nimble file.
    if not execHook(options, actionDevelop, true):
      raise newException(NimbleError, "Pre-hook prevented further execution.")

  var pkgInfo = getPkgInfo(dir, options)
  if pkgInfo.bin.len > 0:
    if "nim" in pkgInfo.skipExt:
      raiseNimbleError("Cannot develop packages that are binaries only.")

    display("Warning:", "This package's binaries will not be compiled " &
            "nor symlinked for development.", Warning, HighPriority)

  # Overwrite the version to #head always.
  pkgInfo.specialVersion = "#head"

  if options.developLocaldeps:
    var optsCopy: Options
    optsCopy.forcePrompts = options.forcePrompts
    optsCopy.nimbleDir = dir / nimbledeps
    createDir(optsCopy.getPkgsDir())
    optsCopy.verbosity = options.verbosity
    optsCopy.action = Action(typ: actionDevelop)
    optsCopy.config = options.config
    optsCopy.nimbleData = %{"reverseDeps": newJObject()}
    optsCopy.pkgInfoCache = newTable[string, PackageInfo]()
    optsCopy.noColor = options.noColor
    optsCopy.disableValidation = options.disableValidation
    optsCopy.forceFullClone = options.forceFullClone
    optsCopy.startDir = dir
    optsCopy.nim = options.nim
    cd dir:
      discard processDeps(pkgInfo, optsCopy)
  else:
    # Dependencies need to be processed before the creation of the pkg dir.
    discard processDeps(pkgInfo, options)

  # Don't link if project local deps mode and "developing" the top level package
  if not (options.localdeps and options.isInstallingTopLevel(dir)):
    # This is similar to the code in `installFromDir`, except that we
    # *consciously* not worry about the package's binaries.
    let pkgDestDir = pkgInfo.getPkgDest(options)
    if dirExists(pkgDestDir) and fileExists(pkgDestDir / "nimblemeta.json"):
      let msg = "$1@$2 already exists. Overwrite?" %
                [pkgInfo.name, pkgInfo.specialVersion]
      if not options.prompt(msg):
        raise NimbleQuit(msg: "")
      removePkgDir(pkgDestDir, options)

    createDir(pkgDestDir)
    # The .nimble-link file contains the path to the real .nimble file,
    # and a secondary path to the source directory of the package.
    # The secondary path is necessary so that the package's .nimble file doesn't
    # need to be read. This will mean that users will need to re-run
    # `nimble develop` if they change their `srcDir` but I think it's a worthy
    # compromise.
    let nimbleLinkPath = pkgDestDir / pkgInfo.name.addFileExt("nimble-link")
    let nimbleLink = NimbleLink(
      nimbleFilePath: pkgInfo.myPath,
      packageDir: pkgInfo.getRealDir()
    )
    writeNimbleLink(nimbleLinkPath, nimbleLink)

    # Save a nimblemeta.json file.
    saveNimbleMeta(pkgDestDir, dir, vcsRevisionInDir(dir), nimbleLinkPath)

    # Save the nimble data (which might now contain reverse deps added in
    # processDeps).
    saveNimbleData(options)

    display("Success:", (pkgInfo.name & " linked successfully to '$1'.") %
            dir, Success, HighPriority)
  else:
    display("Warning:", "Skipping link in project local deps mode", Warning)

  # Execute the post-develop hook.
  cd dir:
    discard execHook(options, actionDevelop, false)

proc develop(options: Options) =
  if options.action.packages == @[]:
    developFromDir(getCurrentDir(), options)
  else:
    # Install each package.
    for pv in options.action.packages:
      let name =
        if isURL(pv.name):
          parseUri(pv.name).path.splitPath().tail
        else:
          pv.name
      let downloadDir = getCurrentDir() / name
      if dirExists(downloadDir):
        let msg = "Cannot clone into '$1': directory exists." % downloadDir
        let hint = "Remove the directory, or run this command somewhere else."
        raiseNimbleError(msg, hint)

      let (meth, url, metadata) = getDownloadInfo(pv, options, true)
      let subdir = metadata.getOrDefault("subdir")

      # Download the HEAD and make sure the full history is downloaded.
      let ver =
        if pv.ver.kind == verAny:
          parseVersionRange("#head")
        else:
          pv.ver
      var options = options
      options.forceFullClone = true
      discard downloadPkg(url, ver, meth, subdir, options, downloadDir)
      developFromDir(downloadDir / subdir, options)

proc test(options: Options) =
  ## Executes all tests starting with 't' in the ``tests`` directory.
  ## Subdirectories are not walked.
  var pkgInfo = getPkgInfo(getCurrentDir(), options)

  var
    files = toSeq(walkDir(getCurrentDir() / "tests"))
    tests, failures: int

  if files.len < 1:
    display("Warning:", "No tests found!", Warning, HighPriority)
    return

  if not execHook(options, actionCustom, true):
    raise newException(NimbleError, "Pre-hook prevented further execution.")

  files.sort((a, b) => cmp(a.path, b.path))

  for file in files:
    let (_, name, ext) = file.path.splitFile()
    if ext == ".nim" and name[0] == 't' and file.kind in {pcFile, pcLinkToFile}:
      var optsCopy = options.briefClone()
      optsCopy.action = Action(typ: actionCompile)
      optsCopy.action.file = file.path
      optsCopy.action.backend = pkgInfo.backend
      optsCopy.getCompilationFlags() = options.getCompilationFlags()
      # treat run flags as compile for default test task
      optsCopy.getCompilationFlags().add(options.action.custRunFlags)
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
    let error = "Only " & $(tests - failures) & "/" & $tests & " tests passed"
    display("Error:", error, Error, HighPriority)

  if not execHook(options, actionCustom, false):
    return

proc check(options: Options) =
  ## Validates a package in the current working directory.
  let nimbleFile = findNimbleFile(getCurrentDir(), true)
  var error: ValidationError
  var pkgInfo: PackageInfo
  var validationResult = false
  try:
    validationResult = validate(nimbleFile, options, error, pkgInfo)
  except:
    raiseNimbleError("Could not validate package:\n" & getCurrentExceptionMsg())

  if validationResult:
    display("Success:", pkgInfo.name & " is valid!", Success, HighPriority)
  else:
    display("Error:", error.msg, Error, HighPriority)
    display("Hint:", error.hint, Warning, HighPriority)
    display("Failure:", "Validation failed", Error, HighPriority)
    quit(QuitFailure)

proc run(options: Options) =
  # Verify parameters.
  var pkgInfo = getPkgInfo(getCurrentDir(), options)

  let binary = options.getCompilationBinary(pkgInfo).get("")
  if binary.len == 0:
    raiseNimbleError("Please specify a binary to run")

  if binary notin toSeq(pkgInfo.bin.keys):
    raiseNimbleError(
      "Binary '$#' is not defined in '$#' package." % [binary, pkgInfo.name]
    )

  # Build the binary.
  build(options)

  let binaryPath = pkgInfo.getOutputDir(binary)
  let cmd = quoteShellCommand(binaryPath & options.action.runFlags)
  displayDebug("Executing", cmd)
  cmd.execCmd.quit


proc doAction(options: var Options) =
  if options.showHelp:
    writeHelp()
  if options.showVersion:
    writeVersion()

  setNimBin(options)
  setNimbleDir(options)

  if options.action.typ in {actionTasks, actionRun, actionBuild, actionCompile}:
    # Implicitly disable package validation for these commands.
    options.disableValidation = true

  case options.action.typ
  of actionRefresh:
    refresh(options)
  of actionInstall:
    let (_, pkgInfo) = install(options.action.packages, options)
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
    if options.queryInstalled: listInstalled(options)
    else: list(options)
  of actionPath:
    listPaths(options)
  of actionBuild:
    build(options)
  of actionRun:
    run(options)
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
  of actionNil:
    assert false
  of actionCustom:
    let
      command = options.action.command.normalize
      nimbleFile = findNimbleFile(getCurrentDir(), true)
      pkgInfo = getPkgInfoFromFile(nimbleFile, options)

    if command in pkgInfo.nimbleTasks:
      # If valid task defined in nimscript, run it
      var execResult: ExecutionResult[bool]
      if execCustom(nimbleFile, options, execResult):
        if execResult.hasTaskRequestedCommand():
          var options = execResult.getOptionsForCommand(options)
          doAction(options)
    elif command == "test":
      # If there is no task defined for the `test` task, we run the pre-defined
      # fallback logic.
        test(options)
    else:
      raiseNimbleError(msg = "Could not find task $1 in $2" %
                            [options.action.command, nimbleFile],
                      hint = "Run `nimble --help` and/or `nimble tasks` for" &
                              " a list of possible commands.")

when isMainModule:
  var error = ""
  var hint = ""

  var opt: Options
  try:
    opt = parseCmdLine()
    opt.startDir = getCurrentDir()
    opt.doAction()
  except NimbleError:
    let currentExc = (ref NimbleError)(getCurrentException())
    (error, hint) = getOutputInfo(currentExc)
  except NimbleQuit:
    discard
  finally:
    try:
      let folder = getNimbleTempDir()
      if opt.shouldRemoveTmp(folder):
        removeDir(folder)
    except OSError:
      let msg = "Couldn't remove Nimble's temp dir"
      display("Warning:", msg, Warning, MediumPriority)

  if error.len > 0:
    displayTip()
    display("Error:", error, Error, HighPriority)
    if hint.len > 0:
      display("Hint:", hint, Warning, HighPriority)
    quit(1)
