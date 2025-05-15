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
import std/[sequtils, sets, options, strformat]
import nimblesat, packageinfotypes, options, version, declarativeparser, packageinfo, common,
  nimenv, cli

type 
  NimResolved* = object
    pkg*: Option[PackageInfo] #when none, we need to install it
    version*: Version

proc resolveNim*(rootPackage: PackageInfo, pkgList: seq[PackageInfo], options: var Options): NimResolved =
  #TODO when useSystemNim is true, we should just return the nim from the system and fails is there is no nim
  #TODO Add the user Nim in path to the pkgList
  #TODO when there is a lock file, we should just assume its correct and use it straight away. 
  #TODO if we are able to resolve the packages in one go, we should not re-run the solver in the next step.
  options.firstSatPass = true
  var pkgsToInstall = newSeq[(string, Version)]()
  var output = ""
  var solvedPkgs = newSeq[SolvedPackage]()
  #We assume we dont have an available nim yet  
  let pkgListDecl = 
    pkgList
    .mapIt(it.toRequiresInfo(options, forceDeclarativeOnly = true))
  var pkgs = solvePackages(rootPackage, pkgListDecl, pkgsToInstall, options, output, solvedPkgs)
  var nims = pkgs.toSeq.filterIt(it.basicInfo.name.isNim)
  if nims.len == 0:
    let solvedNim = solvedPkgs.toSeq.filterIt(it.pkgName.isNim)
    if solvedNim.len > 0:
      return NimResolved(version: solvedNim[0].version)

  if nims.len == 0:
    #TODO if we ever reach this point, we should just download the latest nim release
    raise newNimbleError[NimbleError]("No Nim found") 
  if nims.len > 1:    
    #Before erroying make sure the version are actually different
    var versions = nims.mapIt(it.basicInfo.version)
    if versions.deduplicate().len > 1:
      raise newNimbleError[NimbleError]("Multiple Nims found " & $nims.mapIt(it.basicInfo)) #TODO this cant be reached
  result = NimResolved(pkg: some(nims[0]), version: nims[0].basicInfo.version)
  options.firstSatPass = false

proc setNimBin*(pkgInfo: PackageInfo, options: var Options) =
  assert pkgInfo.basicInfo.name.isNim
  options.useNimFromDir(pkgInfo.getRealDir, pkgInfo.basicInfo.version.toVersionRange())
  displayInfo(&"Nim version used from now on {pkgInfo.basicInfo.version}")