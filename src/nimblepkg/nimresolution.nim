## Nim binary discovery, bootstrap, and SAT-driven Nim selection.
##
## Extracted from vnext.nim during Phase 4 of the vnext dissolution.

import std/[sequtils, sets, options, os, strutils, algorithm]
import nimblesat, packageinfotypes, options, version, declarativeparser,
       packageinfo, common, lockfile, cli, downloadnim, tools,
       packageinstaller

when defined(windows):
  import std/strscans

proc getNimFromSystem*(options: Options): Option[PackageInfo] =
  # --nim:<path> takes priority over system nim but its only forced if we also specify useSystemNim
  # Just filename, search in PATH - nim_temp shortcut
  var pnim = ""
  if options.nimBin.isSome:
    pnim = findExe(options.nimBin.get.path)
  else:
    pnim = findExe("nim")
  if pnim != "":
    var effectivePnim = pnim
    when defined(windows):
      if pnim.toLowerAscii().endsWith(".cmd"):
        let nearbyNim = pnim.changeFileExt("") # Remove .cmd extension
        if fileExists(nearbyNim):
          try:
            let scriptContent = readFile(nearbyNim).strip()
            # Extract path from: "`dirname "$0"`\..\nimbinaries\nim-2.2.4\bin\nim.exe" "$@"
            var ignore, pathPath: string
            if scanf(scriptContent, """$*\$*"""", ignore, pathPath):
              var resolvedPath = pnim.parentDir / pathPath.replace("\\", $DirSep)
              normalizePath(resolvedPath)
              if fileExists(resolvedPath):
                effectivePnim = resolvedPath
          except CatchableError:
            discard # Fall back to original pnim
    var dir = effectivePnim.parentDir.parentDir
    if not fileExists(dir / "nim.nimble"):
      # Non-standard layout (e.g. NixOS wrapper, custom symlink): query the compiler
      # directly for its lib path to find the actual installation root. See #1609.
      let (output, exitCode) = doCmdEx(pnim.quoteShell & " --hints:off --eval:" & quoteShell("import std/compilesettings; echo querySetting(libPath)"))
      if exitCode == 0:
        dir = output.strip().parentDir
    try:
      var pkgInfo = getPkgInfo(dir, options, nimBin = "", level = pikRequires) #Can be empty as the code path for nim doesnt need it.
      pkgInfo.nimBinPath = some pnim  # preserve the PATH-resolved binary for later use
      return some pkgInfo
    except CatchableError:
      discard # Fall back to original pnim
  return none(PackageInfo)

proc isSystemNim*(resolvedNim: NimResolved, options: Options): bool =
  if resolvedNim.pkg.isSome:
    let systemNimPkg = getNimFromSystem(options)
    if systemNimPkg.isSome:
      return resolvedNim.pkg.get.basicInfo.version == systemNimPkg.get.basicInfo.version
  return false

proc solvePackagesWithSystemNimFallback*(
    rootPackage: PackageInfo,
    pkgList: seq[PackageInfo],
    options: var Options,
    resolvedNim: Option[NimResolved], nimBin: string): HashSet[PackageInfo] {.instrument.} =
  ## Solves packages with system Nim as a hard requirement, falling back to
  ## solving without it if the first attempt fails due to unsatisfiable dependencies.

  var rootPackageWithSystemNim = rootPackage
  var systemNimPass = false

  # If there is systemNim, we will try to do a first pass with the systemNim
  # as a hard requirement. If it fails, we will fallback to
  # retry without it as a hard requirement. The idea behind it is that a
  # compatible version of the packages is used for the current nim.
  if resolvedNim.isSome and resolvedNim.get.isSystemNim(options):
    rootPackageWithSystemNim.requires.add(parseRequires("nim " & $resolvedNim.get.version))
    systemNimPass = true

  result = solvePackages(rootPackageWithSystemNim, pkgList,
                        options.satResult.pkgsToInstall, options,
                        options.satResult.output, options.satResult.solvedPkgs, nimBin)
  if options.satResult.solvedPkgs.len == 0 and systemNimPass:
    # If the first pass failed, we will retry without the systemNim as a hard requirement
    result = solvePackages(rootPackage, pkgList,
                          options.satResult.pkgsToInstall, options,
                          options.satResult.output, options.satResult.solvedPkgs, nimBin)

proc compPkgListByVersion*(a, b: PackageInfo): int =
  if  a.basicInfo.version > b.basicInfo.version: return -1
  elif a.basicInfo.version < b.basicInfo.version: return 1
  else: return 0

proc resolveNim*(rootPackage: PackageInfo, pkgListDecl: seq[PackageInfo], systemNimPkg: Option[PackageInfo], options: var Options): NimResolved {.instrument.} =

  options.satResult.pkgList = pkgListDecl.toHashSet()

  #If there is a lock file we should use it straight away (if the user didnt specify --useSystemNim)
  let lockFile = options.lockFile(rootPackage.myPath.parentDir())

  if options.hasNimInLockFile(rootPackage.myPath.parentDir()):
    if options.useSystemNim and systemNimPkg.isSome:
      return NimResolved(pkg: some(systemNimPkg.get), version: systemNimPkg.get.basicInfo.version)
    else:
      for name, dep in lockFile.getLockedDependencies.lockedDepsFor(options):
        if name.isNim:
          # Check if the locked version satisfies the current requirement
          let nimRequirement = rootPackage.requires.filterIt(it.name.isNim)
          if nimRequirement.len > 0:
            if not dep.version.withinRange(nimRequirement[0].ver):
              # Lock file nim doesn't match current requirement - need to re-solve
              break
          #Test if the version in the lock is the same as in the system nim (in case devel is set in the lock file and system nim is devel)
          if systemNimPkg.isSome and dep.version == systemNimPkg.get.basicInfo.version:
            return NimResolved(pkg: some(systemNimPkg.get), version: systemNimPkg.get.basicInfo.version)
          return NimResolved(version: dep.version)

  let runSolver = options.satResult.pass notin [satLockFile]
  if not runSolver:
    #We come from a lock file with no Nim so we can use any Nim.
    #First system nim
    if systemNimPkg.isSome:
      return NimResolved(pkg: some(systemNimPkg.get), version: systemNimPkg.get.basicInfo.version)

    #TODO look in the installed binaries dir
    #If none is found return the latest version by looking at getOfficialReleases
    raise newNimbleError[NimbleError]("No Nim found in lock file and no Nim in the system")

    #Then latest nim release
    # let latestNim = getLatestNimRelease()
    # if latestNim.isSome:
    #   return NimResolved(version: latestNim.get)
  var resolvedNim: Option[NimResolved]
  if systemNimPkg.isSome:
    resolvedNim = some(NimResolved(pkg: systemNimPkg, version: systemNimPkg.get.basicInfo.version))
  var nimBin: string
  if resolvedNim.isSome:
    nimBin = resolvedNim.get.getNimBin()
  else:
    if options.satResult.bootstrapNim.nimResolved.pkg.isNone:
      let nimPkg = (name: "nim", ver: parseVersionRange(options.satResult.bootstrapNim.nimResolved.version))
      let nimInstalled = installNimFromBinariesDir(nimPkg, options)
      if nimInstalled.isSome:
        options.satResult.bootstrapNim.nimResolved.pkg = some getPkgInfo(nimInstalled.get.dir, options, nimBin = "", level = pikRequires) #Can be empty as the code path for nim doesnt need it.
      else:
        raise newNimbleError[NimbleError]("Failed to install nim")
    nimBin = options.satResult.bootstrapNim.nimResolved.getNimBin()

  options.satResult.pkgs = solvePackagesWithSystemNimFallback(
      rootPackage, pkgListDecl, options,  resolvedNim, nimBin)
  if options.satResult.solvedPkgs.len == 0:
    displayError(options.satResult.output)
    raise newNimbleError[NimbleError]("Couldnt find a solution for the packages. Unsatisfiable dependencies. Check there is no contradictory dependencies.")

  var nims = options.satResult.pkgs.toSeq.filterIt(it.basicInfo.name.isNim)
  if nims.len == 0:
    let pkgListDeclNims = pkgListDecl.filterIt(it.basicInfo.name.isNim)
    # echo "PkgListDeclNims ", pkgListDeclNims.mapIt(it.basicInfo.name & " " & $it.basicInfo.version)
    var bestNim: Option[PackageInfo] = none(PackageInfo)
    let solvedNim = options.satResult.solvedPkgs.filterIt(it.pkgName.isNim)
    # echo "SolvedPkgs ", options.satResult.solvedPkgs
    if solvedNim.len > 0:

      # echo "Solved nim ", solvedNim[0].version, " len ", solvedNim.len
      result = NimResolved(version: solvedNim[0].version)
      #Now we need to see if any of the nim pkgs is compatible with the Nim from the solution so
      #we dont download it again.
      for nimPkg in pkgListDeclNims:
        #At this point we lost range information, but we should be ok
        #as we feed the solver with all the versions available already.
        # echo "Checking ", nimPkg.basicInfo.name, " ", nimPkg.basicInfo.version, " ", solvedNim[0].version
        if nimPkg.basicInfo.version == solvedNim[0].version:
          options.satResult.pkgs.incl(nimPkg)
          return NimResolved(pkg: some(nimPkg), version: nimPkg.basicInfo.version)
      return result

    for pkg in pkgListDeclNims:
      #TODO test if its compatible with the current solution.
      if bestNim.isNone or pkg.basicInfo.version > bestNim.get.basicInfo.version:
        bestNim = some(pkg)
    if bestNim.isSome:
      options.satResult.pkgs.incl(bestNim.get)
      return NimResolved(pkg: some(bestNim.get), version: bestNim.get.basicInfo.version)

    #TODO if we ever reach this point, we should just download the latest nim release
    raise newNimbleError[NimbleError]("No Nim found")
  if nims.len > 1:
    #Before erroying make sure the version are actually different
    var versions = nims.mapIt(it.basicInfo.version)
    if versions.deduplicate().len > 1:
      raise newNimbleError[NimbleError]("Multiple Nims found " & $nims.mapIt(it.basicInfo)) #TODO this cant be reached

  result.pkg = some(nims[0])
  result.version = nims[0].basicInfo.version

proc setBootstrapNim*(systemNimPkg: Option[PackageInfo], pkgList: seq[PackageInfo], options: var Options) =
  var bootstrapNim: NimResolved
  let nimPkgList = pkgList.filterIt(it.basicInfo.name.isNim)
  #we want to use actual systemNimPkg as bootstrap nim.
  if systemNimPkg.isSome:
    # echo "SETTING BOOTSTRAP NIM TO SYSTEM NIM PKG: ", systemNimPkg.get.basicInfo.name, " ", systemNimPkg.get.basicInfo.version, " path ", systemNimPkg.get.getNimbleFileDir()
    bootstrapNim.pkg = some(systemNimPkg.get)
    bootstrapNim.version = systemNimPkg.get.basicInfo.version
  elif nimPkgList.len > 0: #If no system nim, we use the best nim available (they are ordered by version)
    # echo nimPkgList.mapIt(it.basicInfo.name & " " & $it.basicInfo.version & " path " & it.getNimbleFileDir())
    # echo "SETTING BOOTSTRAP NIM TO: ", nimPkgList[0].basicInfo.name, " ", nimPkgList[0].basicInfo.version, " path ", nimPkgList[0].getNimbleFileDir()
    bootstrapNim.pkg = some(nimPkgList[0])
    bootstrapNim.version = nimPkgList[0].basicInfo.version
  else:
    #if none of the above, we just set the version to be used. We dont want to install a nim until we
    #are clear that we need to actually use it. In order to pick the version, we get the releases.
    #Notice we should never call setNimBin for it. Rather we should attempt to use it directly.
    let bestRelease = getOfficialReleases(options).max
    bootstrapNim.version = bestRelease

    # echo "SETTING BOOTSTRAP NIM TO BEST RELEASE: ", bestRelease
    #TODO Only install when we actually need it. Meaning in a subsequent PR when we failed to parse a nimble fail with the declarative parser.
    #Ideally it should be triggered from the declarative parser when it detects the failure.
    #Important: we need to refactor the code path to the nim parser to make sure we parametrize the Nim instead of setting the bootstrap nim directly, this should never be the case.

  options.satResult.bootstrapNim = BootstrapNim(nimResolved: bootstrapNim, allowToUse: true)

proc getNimBinariesPackages*(options: Options): seq[PackageInfo] =
  for kind, path in walkDir(options.nimBinariesDir):
    if kind == pcDir:
      let nimbleFile = path / "nim.nimble"
      if fileExists(nimbleFile):
        var pkgInfo = getNimPkgInfo(nimbleFile.parentDir, options, nimBin = "") #Can be empty as the code path for nim doesnt need it.
        # Check if directory name indicates a special version (e.g., nim-#devel)
        # The directory name format is "nim-<version>"
        let dirName = path.extractFilename
        if dirName.startsWith("nim-#"):
          # This is a special version like #devel
          let specialVersionStr = dirName[4..^1]  # Extract "#devel" from "nim-#devel"
          var specialVer = newVersion(specialVersionStr)
          let semanticVer = extractNimVersion(nimbleFile)
          if semanticVer != "":
            specialVer.speSemanticVersion = some(semanticVer)
          pkgInfo.basicInfo.version = specialVer
        result.add pkgInfo

proc getBootstrapNimResolved*(options: var Options): NimResolved =
  var pkgList: seq[PackageInfo] = @[] #Should we use the install nim pkgs? In most cases they should already be in the nim binaries dir
  let nimBinariesPackages = getNimBinariesPackages(options).sortedByIt(it.basicInfo.version).reversed()
  pkgList.add(nimBinariesPackages)
  setBootstrapNim(getNimFromSystem(options), pkgList, options)
  var bootstrapNim = options.satResult.bootstrapNim
  if bootstrapNim.nimResolved.pkg.isNone:
    let nimInstalled = installNimFromBinariesDir(("nim", bootstrapNim.nimResolved.version.toVersionRange()), options)
    if nimInstalled.isSome:
      bootstrapNim.nimResolved.pkg = some getPkgInfo(nimInstalled.get.dir, options, nimBin = "", level = pikRequires) #Can be empty as the code path for nim doesnt need it.
    else:
      raise nimbleError("Failed to install nim") #What to do here? Is this ever possible?
  options.satResult.bootstrapNim = bootstrapNim
  return bootstrapNim.nimResolved

proc resolveAndConfigureNim*(rootPackage: PackageInfo, pkgList: seq[PackageInfo], options: var Options, nimBin: string): NimResolved {.instrument.} =
  #Before resolving nim, we bootstrap it, so if we fail resolving it when can use the bootstrapped version.
  #Notice when implemented it would make the second sat pass obsolete.
  let systemNimPkg = getNimFromSystem(options)
  if options.useSystemNim:
    if systemNimPkg.isNone:
      raise newNimbleError[NimbleError]("No system nim found")
    # If there's a lock file, return early - solveLockFileDeps will handle resolution
    # If there's no lock file, we need to run the SAT solver with system nim
    if rootPackage.hasLockFile(options) and not options.disableLockFile:
      return NimResolved(pkg: some(systemNimPkg.get), version: systemNimPkg.get.basicInfo.version)
    var pkgListDecl = pkgList.mapIt(it.toRequiresInfo(options, nimBin))
    pkgListDecl.add(systemNimPkg.get)
    pkgListDecl.sort(compPkgListByVersion)
    options.satResult.pkgList = pkgListDecl.toHashSet()
    options.satResult.pkgs = solvePackagesWithSystemNimFallback(
        rootPackage, pkgListDecl, options, some(NimResolved(pkg: systemNimPkg, version: systemNimPkg.get.basicInfo.version)), nimBin)
    if options.satResult.solvedPkgs.len == 0:
      displayError(options.satResult.output)
      raise newNimbleError[NimbleError]("Couldnt find a solution for the packages. Unsatisfiable dependencies.")
    return NimResolved(pkg: some(systemNimPkg.get), version: systemNimPkg.get.basicInfo.version)

  # Special case: when installing nim itself globally, we want to install that specific version
  # Don't run SAT solver which would pick a nim for compilation - we want the nim we're installing
  if rootPackage.basicInfo.name.isNim:
    # Use the requested version from the command line (e.g. #head, #devel, >= 2.0.0)
    # not the declared version from nim.nimble (e.g. 2.3.1) which may not have binaries
    var requestedVer = parseVersionRange(rootPackage.basicInfo.version)
    for pkg in options.action.packages:
      if pkg.name.isNim:
        requestedVer = pkg.ver
        break
    let nimPkg = (name: "nim", ver: requestedVer)
    let nimInstalled = installNimFromBinariesDir(nimPkg, options)
    if nimInstalled.isSome:
      let resolvedNim = NimResolved(
        pkg: some getPkgInfo(nimInstalled.get.dir, options, nimBin = "", level = pikRequires), #Can be empty as the code path for nim doesnt need it.
        version: nimInstalled.get.ver
      )
      # Still need to set bootstrap nim and configure it
      var pkgListDecl = pkgList.mapIt(it.toRequiresInfo(options, resolvedNim.getNimBin()))
      if systemNimPkg.isSome:
        pkgListDecl.add(systemNimPkg.get)
      pkgListDecl.sort(compPkgListByVersion)
      options.satResult.pkgList = pkgListDecl.toHashSet()
      return resolvedNim
    else:
      raise nimbleError("Failed to install nim version " & $requestedVer)

  var pkgListDecl =
    pkgList
    .mapIt(it.toRequiresInfo(options, nimBin)) #Notice this could fail to parse, but shouldnt be an issue as it wont be falling back yet. We are only interested in selecting nim
  if systemNimPkg.isSome:
    pkgListDecl.add(systemNimPkg.get)
  #Order the pkglist by version
  pkgListDecl.sort(compPkgListByVersion)

  options.satResult.pkgList = pkgListDecl.toHashSet()
  # setBootstrapNim(systemNimPkg, pkgListDecl, options)
  #TODO NEXT PR
  #At this point, if we failed before to parse the pkglist. We need to reparse with the bootsrapped nim as we may have missed some deps.


  var resolvedNim = resolveNim(rootPackage, pkgListDecl, systemNimPkg, options)
  if resolvedNim.pkg.isNone:
    #we need to install it
    let nimPkg = (name: "nim", ver: parseVersionRange(resolvedNim.version))
    #TODO handle the case where the user doesnt want to reuse nim binaries
    #It can be done inside the installNimFromBinariesDir function to simplify things out by
    #forcing a recompilation of nim.
    let nimInstalled = installNimFromBinariesDir(nimPkg, options)
    if nimInstalled.isSome:
      resolvedNim.pkg = some getPkgInfo(nimInstalled.get.dir, options, nimBin = "", level = pikRequires) #Can be empty as the code path for nim doesnt need it.
      resolvedNim.version = nimInstalled.get.ver
    elif rootPackage.basicInfo.name.isNim: #special version/not in releases nim binaries
      resolvedNim.pkg = some rootPackage
      resolvedNim.version = rootPackage.basicInfo.version
    else:
      raise nimbleError("Failed to install nim")

  return resolvedNim

proc createBinSymlinkForNim*(pkgInfo: PackageInfo, options: Options) =
  let binDir = options.getBinDir()
  createDir(binDir)
  let nimBinDir = pkgInfo.getNimbleFileDir() / "bin"
  for kind, path in walkDir(nimBinDir):
    if kind in {pcFile, pcLinkToFile}:
      let filename = path.extractFilename
      # Never replace nimble itself — we are nimble
      let baseName = filename.changeFileExt("")
      if baseName == "nimble":
        continue
      # Skip non-executable files (e.g., .bat files on unix, empty.txt)
      when defined(windows):
        if not (filename.endsWith(".exe") or filename.endsWith(".cmd") or filename.endsWith(".bat")):
          continue
      else:
        if filename.endsWith(".bat") or filename.endsWith(".cmd"):
          continue
      let symlinkFilename = binDir / filename.changeFileExt("")
      discard setupBinSymlink(path, symlinkFilename, options)
