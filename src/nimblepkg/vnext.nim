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
  nimenv, lockfile

type 
  NimResolved* = object
    pkg*: Option[PackageInfo] #when none, we need to install it
    version*: Version

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
  #TODO handle undecideble cases
  #TODO if we are able to resolve the packages in one go, we should not re-run the solver in the next step.
  #TODO Introduce the concept of bootstrap nimble where we detect a failure in the declarative parser and fallback to a concrete nim version to re-run the nim selection with the vm parser
  let systemNimPkg = getNimFromSystem(options)
  if options.useSystemNim:
    if systemNimPkg.isSome:
      return NimResolved(pkg: some(systemNimPkg.get), version: systemNimPkg.get.basicInfo.version)
    else:
      raise newNimbleError[NimbleError]("No system nim found") 
  
  options.firstSatPass = true
  var pkgsToInstall = newSeq[(string, Version)]()
  var output = ""
  var solvedPkgs = newSeq[SolvedPackage]()
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
      return NimResolved(pkg: some(systemNimPkg.get), version: systemNimPkg.get.basicInfo.version)
    else:
      for name, dep in lockFile.getLockedDependencies.lockedDepsFor(options):
        if name.isNim:
          return NimResolved(version: dep.version)
    
  var pkgs = solvePackages(rootPackage, pkgListDecl, pkgsToInstall, options, output, solvedPkgs)
  # echo "Pgs result nims ", pkgs.mapIt(it.basicInfo.name).filterIt(it.isNim)
  # echo "SolvedPkgs nims ", solvedPkgs.mapIt(it.pkgName).filterIt(it.isNim)

  var nims = pkgs.toSeq.filterIt(it.basicInfo.name.isNim)
  if nims.len == 0:
    let solvedNim = solvedPkgs.toSeq.filterIt(it.pkgName.isNim)
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
      return NimResolved(pkg: some(bestNim.get), version: bestNim.get.basicInfo.version)

    echo "Pgs result ", pkgs.mapIt(it.basicInfo.name)
    echo "SolvedPkgs ", solvedPkgs
    echo "PkgsToInstall ", pkgsToInstall
    echo "Root package ", rootPackage.basicInfo, " requires ", rootPackage.requires
    echo "PkglistDecl ", pkgListDecl.mapIt(it.basicInfo.name & " " & $it.basicInfo.version)
    echo output
    # echo ""
    #TODO if we ever reach this point, we should just download the latest nim release
    raise newNimbleError[NimbleError]("No Nim found") 
  if nims.len > 1:    
    #Before erroying make sure the version are actually different
    var versions = nims.mapIt(it.basicInfo.version)
    if versions.deduplicate().len > 1:
      raise newNimbleError[NimbleError]("Multiple Nims found " & $nims.mapIt(it.basicInfo)) #TODO this cant be reached
  result = NimResolved(pkg: some(nims[0]), version: nims[0].basicInfo.version)

proc setNimBin*(pkgInfo: PackageInfo, options: var Options) =
  assert pkgInfo.basicInfo.name.isNim
  options.useNimFromDir(pkgInfo.getRealDir, pkgInfo.basicInfo.version.toVersionRange())
