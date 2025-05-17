#[
Name of the file is temporary.
VNext is a new code path for some actions where we assume solver is SAT and declarative parser are enabled.
The first thing we do, is to try to resolve Nim assuming there is no Nim installed (so we cant fallback to the vm parser to read deps)
After we resolve nim, we try to resolve the dependencies for a root package. Root package can be the package we want to install or the package in the current directory.
]#

#[
Steps:
  - toRequiresInfo should accept an additional argument so we can decide to dont fallback to the vm parser when the declarative parser fails.
  - isolate nim selection
  - if nim cant be decided, we should stop (for now. Later on we can 1. see if there is a nim in the path. 2 See if there is a nim in the pkgklist. 3 Download latest nim release)
  - After we have nim, we can try to resolve the dependencies (later on, only re-run the solver if we needed nim in the step above)
  - Once we have the graph solved. We can proceed with the action.

]#
import std/[sequtils, sets, options, os]
import nimblesat, packageinfotypes, options, version, declarativeparser, packageinfo, common,
  nimenv, lockfile, cli, downloadnim

type 
  SATPass* = enum
    satNone
    satNimSelection

  SATResult* = object
    pkgsToInstall*: seq[(string, Version)]
    solvedPkgs*: seq[SolvedPackage]
    output*: string
    pkgs*: HashSet[PackageInfo]
    pass*: SATPass
    
  NimResolved = object
    pkg: Option[PackageInfo] #when none, we need to install it
    version: Version
    satResult*: SATResult

proc getNimFromSystem*(options: Options): Option[PackageInfo] =
  # --nim:<path> takes priority over system nim but its only forced if we also specify useSystemNim
  # Just filename, search in PATH - nim_temp shortcut
  var pnim = ""
  if options.nimBin.isSome:
    pnim = findExe(options.nimBin.get.path)
  else:
    pnim = findExe("nim")
  if pnim != "": 
    let dir = pnim.parentDir.parentDir
    return some getPkgInfoFromDirWithDeclarativeParser(dir, options, forceDeclarativeOnly = true)
  return none(PackageInfo)

proc resolveNim*(rootPackage: PackageInfo, pkgList: seq[PackageInfo], options: var Options): NimResolved =
  #TODO if we are able to resolve the packages in one go, we should not re-run the solver in the next step.
  #TODO Introduce the concept of bootstrap nimble where we detect a failure in the declarative parser and fallback to a concrete nim version to re-run the nim selection with the vm parser
  let systemNimPkg = getNimFromSystem(options)
  if options.useSystemNim:
    if systemNimPkg.isSome:
      return NimResolved(pkg: some(systemNimPkg.get), version: systemNimPkg.get.basicInfo.version)
    else:
      raise newNimbleError[NimbleError]("No system nim found") 
  
  options.firstSatPass = true #Todo change the options so it uses the SATPass enum
  result.satResult.pass = satNone
  #We assume we dont have an available nim yet  
  var pkgListDecl = 
    pkgList
    .mapIt(it.toRequiresInfo(options, forceDeclarativeOnly = true))
  if systemNimPkg.isSome:
    pkgListDecl.add(systemNimPkg.get)
  
  #If there is a lock file we should use it straight away (if the user didnt specify --useSystemNim)
  let lockFile = options.lockFile(getCurrentDir())
  if options.hasNimInLockFile():
    if options.useSystemNim and systemNimPkg.isSome:
      return NimResolved(pkg: some(systemNimPkg.get), version: systemNimPkg.get.basicInfo.version, satResult: result.satResult)
    else:
      for name, dep in lockFile.getLockedDependencies.lockedDepsFor(options):
        if name.isNim:
          return NimResolved(version: dep.version, satResult: result.satResult)
    
  result.satResult.pass = satNimSelection
  var pkgs = solvePackages(rootPackage, pkgListDecl, result.satResult.pkgsToInstall, options, result.satResult.output, result.satResult.solvedPkgs)
  if result.satResult.solvedPkgs.len == 0:
    displayError(result.satResult.output)
    raise newNimbleError[NimbleError]("Couldnt find a solution for the packages. Check there is no contradictory dependencies.")

  var nims = pkgs.toSeq.filterIt(it.basicInfo.name.isNim)
  if nims.len == 0:
    let solvedNim = result.satResult.solvedPkgs.filterIt(it.pkgName.isNim)
    if solvedNim.len > 0:
      # echo "Solved nim ", solvedNim[0].version
      return NimResolved(version: solvedNim[0].version)
    let pkgListDeclNims = pkgListDecl.filterIt(it.basicInfo.name.isNim)
    # echo "PkgListDeclNims ", pkgListDeclNims.mapIt(it.basicInfo.name & " " & $it.basicInfo.version)
    var bestNim: Option[PackageInfo] = none(PackageInfo)
    #TODO fail if there is none compatible with the current solution
    for pkg in pkgListDeclNims:
      if bestNim.isNone or pkg.basicInfo.version > bestNim.get.basicInfo.version:
        bestNim = some(pkg)
    if bestNim.isSome:
      return NimResolved(pkg: some(bestNim.get), version: bestNim.get.basicInfo.version, satResult: result.satResult)

    echo "SAT result ", result.satResult.pkgs.mapIt(it.basicInfo.name)
    echo "SolvedPkgs ", result.satResult.solvedPkgs
    echo "PkgsToInstall ", result.satResult.pkgsToInstall
    echo "Root package ", rootPackage.basicInfo, " requires ", rootPackage.requires
    echo "PkglistDecl ", pkgListDecl.mapIt(it.basicInfo.name & " " & $it.basicInfo.version)
    echo result.satResult.output
    # echo ""
    #TODO if we ever reach this point, we should just download the latest nim release
    raise newNimbleError[NimbleError]("No Nim found") 
  if nims.len > 1:    
    #Before erroying make sure the version are actually different
    var versions = nims.mapIt(it.basicInfo.version)
    if versions.deduplicate().len > 1:
      raise newNimbleError[NimbleError]("Multiple Nims found " & $nims.mapIt(it.basicInfo)) #TODO this cant be reached
  
  echo "Pgs result ", result.satResult.pkgs.mapIt(it.basicInfo.name)
  echo "SolvedPkgs ", result.satResult.solvedPkgs.mapIt(it.pkgName)
  echo "PkgsToInstall ", result.satResult.pkgsToInstall
  echo "Root package ", rootPackage.basicInfo, " requires ", rootPackage.requires
  echo "PkglistDecl ", pkgListDecl.mapIt(it.basicInfo.name & " " & $it.basicInfo.version)
  result.pkg = some(nims[0])
  result.version = nims[0].basicInfo.version

proc setNimBin(pkgInfo: PackageInfo, options: var Options) =
  assert pkgInfo.basicInfo.name.isNim
  options.useNimFromDir(pkgInfo.getRealDir, pkgInfo.basicInfo.version.toVersionRange())

proc resolveAndConfigureNim*(rootPackage: PackageInfo, pkgList: seq[PackageInfo], options: var Options): SATResult =
  var resolvedNim = resolveNim(rootPackage, pkgList, options)
  if resolvedNim.pkg.isNone:
    #we need to install it
    let nimPkg = (name: "nim", ver: parseVersionRange(resolvedNim.version))
    #TODO handle the case where the user doesnt want to reuse nim binaries 
    #It can be done inside the installNimFromBinariesDir function to simplify things out by
    #forcing a recompilation of nim.
    let nimInstalled = installNimFromBinariesDir(nimPkg, options)
    if nimInstalled.isSome:
      resolvedNim.pkg = some getPkgInfoFromDirWithDeclarativeParser(nimInstalled.get.dir, options, forceDeclarativeOnly = true)
      resolvedNim.version = nimInstalled.get.ver
    else:
      raise nimbleError("Failed to install nim")

  resolvedNim.pkg.get.setNimBin(options)
  options.firstSatPass = false
  resolvedNim.satResult

proc installPkgs*(satResult: SATResult, options: Options) =
  #At this point the packages are already downloaded. 
  #We still need to install them aka copy them from the cache to the nimbleDir
  echo "Installing packages"
  for (name, ver) in satResult.pkgsToInstall:
    let pv = (name: name, ver: ver.toVersionRange())
    let dlInfo = getPackageDownloadInfo(pv, options)
    assert dirExists(dlInfo.downloadDir)
    echo "Download info ", dlInfo

  echo ""