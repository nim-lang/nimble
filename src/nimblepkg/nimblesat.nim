import sat/[sat, satvars] 
import version, packageinfotypes, download, packageinfo, packageparser, options, 
  sha1hashes, tools, downloadnim, cli
  
import std/[tables, sequtils, algorithm, sets, strutils, options, strformat, os, json, jsonutils]


type  
  SatVarInfo* = object # attached information for a SAT variable
    pkg*: string
    version*: Version
    index*: int

  Form* = object
    f*: Formular
    mapping*: Table[VarId, SatVarInfo]
    idgen*: int32
  
  PackageMinimalInfo* = object
    name*: string
    version*: Version
    requires*: seq[PkgTuple]
    isRoot*: bool

  PackageVersions* = object
    pkgName*: string
    versions*: seq[PackageMinimalInfo]
  
  Requirements* = object
    deps*: seq[PkgTuple] #@[(name, versRange)]
    version*: Version
    nimVersion*: Version
    v*: VarId
    err*: string

  DependencyVersion* = object  # Represents a specific version of a project.
    version*: Version
    req*: int # index into graph.reqs so that it can be shared between versions
    v*: VarId
    # req: Requirements

  Dependency* = object
    pkgName*: string
    versions*: seq[DependencyVersion]
    active*: bool
    activeVersion*: int
    isRoot*: bool

  DepGraph* = object
    nodes*: seq[Dependency]
    reqs*: seq[Requirements]
    packageToDependency*: Table[string, int] #package.name -> index into nodes
    # reqsByDeps: Table[Requirements, int]
  SolvedPackage* = object
    pkgName*: string
    version*: Version
    requirements*: seq[PkgTuple] 
    reverseDependencies*: seq[(string, Version)] 
    
  GetPackageMinimal* = proc (pv: PkgTuple, options: Options): seq[PackageMinimalInfo]

  TaggedPackageVersions = object
    maxTaggedVersions: int # Maximum number of tags. When number changes, we invalidate the cache
    versions: seq[PackageMinimalInfo]

const TaggedVersionsFileName* = "tagged_versions.json"

proc initFromJson*(dst: var PkgTuple, jsonNode: JsonNode, jsonPath: var string) =
  dst = parseRequires(jsonNode.str)

proc toJsonHook*(src: PkgTuple): JsonNode =
  let ver = if src.ver.kind == verAny: "" else: $src.ver
  case src.ver.kind
  of verAny: newJString(src.name)
  of verSpecial: newJString(src.name & ver)
  else:
    newJString(src.name & " " & ver)

#From the STD as it is not available in older Nim versions
func addUnique*[T](s: var seq[T], x: sink T) =
  ## Adds `x` to the container `s` if it is not already present. 
  ## Uses `==` to check if the item is already present.
  runnableExamples:
    var a = @[1, 2, 3]
    a.addUnique(4)
    a.addUnique(4)
    assert a == @[1, 2, 3, 4]

  for i in 0..high(s):
    if s[i] == x: return
  when declared(ensureMove):
    s.add ensureMove(x)
  else:
    s.add x

proc isNim*(pv: PkgTuple): bool = pv.name.isNim

proc convertNimrodToNim*(pv: PkgTuple): PkgTuple = 
  if pv.name != "nimrod": pv
  else: (name: "nim", ver: pv.ver)

proc getMinimalInfo*(pkg: PackageInfo, options: Options): PackageMinimalInfo =
  result.name = pkg.basicInfo.name
  result.version = pkg.basicInfo.version
  result.requires = pkg.requires.map(convertNimrodToNim)
  if options.action.typ in {actionLock, actionDeps} or options.lockFileExists(getCurrentDir()):
    result.requires = result.requires.filterIt(not it.isNim)

proc hasVersion*(packageVersions: PackageVersions, pv: PkgTuple): bool =
  for pkg in packageVersions.versions:
    if pkg.name == pv.name and pkg.version.withinRange(pv.ver):
      return true
  false

proc hasVersion*(packagesVersions: Table[string, PackageVersions], pv: PkgTuple): bool =
  if pv.name in packagesVersions:
    return packagesVersions[pv.name].hasVersion(pv)
  false

proc hasVersion*(packagesVersions: Table[string, PackageVersions], name: string, ver: Version): bool =
  if name in packagesVersions:
    for pkg in packagesVersions[name].versions:
      if pkg.version == ver:
        return true
  false

proc findDependencyForDep(g: DepGraph; dep: string): int {.inline.} =
  assert g.packageToDependency.hasKey(dep), dep & " not found"
  result = g.packageToDependency.getOrDefault(dep)

proc createRequirements(pkg: PackageMinimalInfo): Requirements =
  result.deps = pkg.requires
  result.version = pkg.version
  result.nimVersion = pkg.requires.getNimVersion()

proc cmp(a,b: DependencyVersion): int =
  if a.version < b.version: return -1
  elif a.version == b.version: return 0
  else: return 1

proc getRequirementFromGraph(g: var DepGraph, pkg: PackageMinimalInfo): int =
  var temp = createRequirements(pkg)
  for i in countup(0, g.reqs.len-1):
    if g.reqs[i] == temp: return i
  g.reqs.add temp
  g.reqs.len-1
  
proc toDependencyVersion(g: var DepGraph, pkg: PackageMinimalInfo): DependencyVersion =
  result.version = pkg.version
  result.req = getRequirementFromGraph(g, pkg) 

proc toDependency(g: var DepGraph, pkg: PackageVersions): Dependency = 
  result.pkgName = pkg.pkgName
  result.versions = pkg.versions.mapIt(toDependencyVersion(g, it))
  assert pkg.versions.len > 0, "Package must have at least one version"
  result.isRoot = pkg.versions[0].isRoot

proc toDepGraph*(versions: Table[string, PackageVersions]): DepGraph =
  var root: PackageVersions
  for pv in versions.values:
    if pv.versions[0].isRoot:
      root = pv
    else:
      result.nodes.add toDependency(result, pv)
  assert root.pkgName != "", "No root package found"
  result.nodes.insert(toDependency(result, root), 0)
  # Fill the other field and I should be good to go?
  for i in countup(0, result.nodes.len-1):
    result.packageToDependency[result.nodes[i].pkgName] = i

proc toFormular*(g: var DepGraph): Form =
# Key idea: use a SAT variable for every `Requirements` object, which are
# shared.
  result = Form()
  var b = Builder()
  b.openOpr(AndForm)
  # Assign a variable for each package version
  for p in mitems(g.nodes):
    if p.versions.len == 0: continue
    p.versions.sort(cmp)

    for ver in mitems p.versions:
      ver.v = VarId(result.idgen)
      result.mapping[ver.v] = SatVarInfo(pkg: p.pkgName, version: ver.version, index: result.idgen)
      inc result.idgen

    # Encode the rule: for root packages, exactly one of its versions must be true
    if p.isRoot:
      b.openOpr(ExactlyOneOfForm)
      for ver in mitems p.versions:
        b.add(ver.v)
      b.closeOpr()
    else:
      # For non-root packages, either one version is selected or none
      b.openOpr(ZeroOrOneOfForm)
      for ver in mitems p.versions:
        b.add(ver.v)
      b.closeOpr()

  # Model dependencies and their version constraints
  for p in mitems(g.nodes):
    for ver in p.versions.mitems:
      let eqVar = VarId(result.idgen)
      # Mark the beginning position for a potential reset
      let beforeDeps = b.getPatchPos()

      inc result.idgen
      var hasDeps = false

      for dep, q in items g.reqs[ver.req].deps:
        let av = g.nodes[findDependencyForDep(g, dep)]
        if av.versions.len == 0: continue

        hasDeps = true
        b.openOpr(ExactlyOneOfForm)  # Dependency must satisfy at least one of the version constraints

        for avVer in av.versions:
          if avVer.version.withinRange(q):
            b.add(avVer.v)  # This version of the dependency satisfies the constraint

        b.closeOpr()
      
      # If the package version is chosen and it has dependencies, enforce the dependencies' constraints
      if hasDeps:
        b.openOpr(OrForm)
        b.addNegated(ver.v)  # If this package version is not chosen, skip the dependencies constraint
        b.add(eqVar)  # Else, ensure the dependencies' constraints are met
        b.closeOpr()

      # If no dependencies were added, reset to beforeDeps to avoid empty or invalid operations
      if not hasDeps:
        b.resetToPatchPos(beforeDeps)
  
  b.closeOpr()  # Close the main AndForm
  result.f = toForm(b)  # Convert the builder to a formula

proc toString(x: SatVarInfo): string =
  "(" & x.pkg & ", " & $x.version & ")"

proc debugFormular*(g: var DepGraph; f: Form; s: Solution) =
  echo "FORM: ", f.f
  #for n in g.nodes:
  #  echo "v", n.v.int, " ", n.pkg.url
  for k, v in pairs(f.mapping):
    echo "v", k.int, ": ", v
  let m = maxVariable(f.f)
  for i in 0 ..< m:
    if s.isTrue(VarId(i)):
      echo "v", i, ": T"
    else:
      echo "v", i, ": F"

proc getNodeByReqIdx(g: var DepGraph, reqIdx: int): Option[Dependency] =
  for n in g.nodes:
    if n.versions.anyIt(it.req == reqIdx):
      return some n
  none(Dependency)

proc generateUnsatisfiableMessage(g: var DepGraph, f: Form, s: Solution): string =
  var conflicts: seq[string] = @[]
  for reqIdx, req in g.reqs:
    if not s.isTrue(req.v):  # Check if the requirement's corresponding variable was not satisfied
      for dep in req.deps:
        var dep = dep
        let depNodeIdx = findDependencyForDep(g, dep.name)
        let depVersions = g.nodes[depNodeIdx].versions
        let satisfiableVersions = 
          depVersions.filterIt(it.version.withinRange(dep.ver) and s.isTrue(it.v))
        
        if satisfiableVersions.len == 0:
          # No version of this dependency could satisfy the requirement
          # Find which package/version had this requirement
          let reqNode = g.getNodeByReqIdx(reqIdx)
          if reqNode.isSome:
            let pkgName = reqNode.get.pkgName
            conflicts.add(&"Requirement '{dep.name} {dep.ver}' required by '{pkgName} {req.version}' could not be satisfied.")
  
  if conflicts.len == 0:
    return "Dependency resolution failed due to unsatisfiable dependencies, but specific conflicts could not be determined."
  else:
    return "Dependency resolution failed due to the following conflicts:\n" & conflicts.join("\n")

proc findMinimalFailingSet*(g: var DepGraph): tuple[failingSet: seq[PkgTuple], output: string] =
  var minimalFailingSet: seq[PkgTuple] = @[]
  let rootNode = g.nodes[0]
  let rootVersion = rootNode.versions[0]
  var allDeps = g.reqs[rootVersion.req].deps
  
  # Try removing one dependency at a time to see if it makes it satisfiable
  for i in 0..<allDeps.len:
    var reducedDeps = allDeps
    reducedDeps.delete(i)
    var tempGraph = g
    tempGraph.reqs[rootVersion.req].deps = reducedDeps
    let tempForm = toFormular(tempGraph)
    var tempSolution = createSolution(tempForm.idgen)
    if not satisfiable(tempForm.f, tempSolution):
      minimalFailingSet.add(allDeps[i])
  
  # Generate error message
  var output = ""
  if minimalFailingSet.len > 0:
    output = "Dependency resolution failed. Minimal set of conflicting dependencies:\n"
    var allRequirements = initTable[string, seq[VersionRange]]()
    for dep in minimalFailingSet:
      let depNodeIdx = g.findDependencyForDep(dep.name)
      if depNodeIdx >= 0:
        let depNode = g.nodes[depNodeIdx]
        for ver in depNode.versions:
          if ver.version.withinRange(dep.ver):
            let reqs = g.reqs[ver.req].deps
            for req in reqs:
              if req.name notin allRequirements:
                allRequirements[req.name] = @[]
              allRequirements[req.name].add(req.ver)
    
    # Show deps with conflicts
    for dep in minimalFailingSet:
      output.add(&" \n + {dep.name} {dep.ver}")
      let depNodeIdx = g.findDependencyForDep(dep.name)
      if depNodeIdx >= 0:
        let depNode = g.nodes[depNodeIdx]
        var shownReqs = initHashSet[string]()
        for ver in depNode.versions:
          if ver.version.withinRange(dep.ver):
            let reqs = g.reqs[ver.req].deps
            for req in reqs:
              let reqKey = req.name & $req.ver
              if allRequirements[req.name].len > 1 and reqKey notin shownReqs:
                output.add(&"\n\t -{req.name} {req.ver}")
                shownReqs.incl(reqKey)
  
  (minimalFailingSet, output)

proc filterSatisfiableDeps(g: DepGraph, node: Dependency): seq[DependencyVersion] =
  ## Returns a sequence of versions from the node that have satisfiable dependencies
  result = @[]
  for v in node.versions:
    let reqs = g.reqs[v.req].deps
    var hasUnsatisfiableDep = false
    for req in reqs:
      let depIdx = findDependencyForDep(g, req.name)
      if depIdx >= 0:
        var canSatisfy = false
        for depVer in g.nodes[depIdx].versions:
          if depVer.version.withinRange(req.ver):
            canSatisfy = true
            break
        if not canSatisfy:
          hasUnsatisfiableDep = true
          break
    if not hasUnsatisfiableDep:
      result.add(v)

const MaxSolverRetries = 100

proc solve*(g: var DepGraph; f: Form, packages: var Table[string, Version], output: var string, 
           retryCount = 0): bool =
  let m = f.idgen
  var s = createSolution(m)
  
  if satisfiable(f.f, s):
    for n in mitems g.nodes:
      if n.isRoot: n.active = true
    for i in 0 ..< m:
      if s.isTrue(VarId(i)) and f.mapping.hasKey(VarId i):
        let m = f.mapping[VarId i]
        let idx = findDependencyForDep(g, m.pkg)
        g.nodes[idx].active = true
        g.nodes[idx].activeVersion = m.index

    for n in items g.nodes:
      for v in items(n.versions):
        let item = f.mapping[v.v]
        if s.isTrue(v.v):
          packages[item.pkg] = item.version
          output.add &"item.pkg  [x]  {toString item} \n"
        else:
          output.add &"item.pkg  [ ]  {toString item} \n"
    return true
  else:
    let (failingSet, errorMsg) = findMinimalFailingSet(g)
    if retryCount >= MaxSolverRetries:
      output = &"Max retry attempts ({MaxSolverRetries}) exceeded while trying to resolve dependencies \n"
      output.add errorMsg
      return false

    if failingSet.len > 0:
      var newGraph = g
      for pkg in failingSet:
        let idx = findDependencyForDep(newGraph, pkg.name)
        if idx >= 0:
          # echo "Retry #", retryCount + 1, ": Checking package ", pkg.name, " version ", pkg.ver
          let newVersions = filterSatisfiableDeps(newGraph, newGraph.nodes[idx])
          if newVersions.len > 0 and newVersions != newGraph.nodes[idx].versions:
            newGraph.nodes[idx].versions = newVersions
            let newForm = toFormular(newGraph)
            return solve(newGraph, newForm, packages, output, retryCount + 1)
      
      output = errorMsg
    else:
      output = generateUnsatisfiableMessage(g, f, s)
    false

proc collectReverseDependencies*(targetPkgName: string, graph: DepGraph): seq[(string, Version)] =
  for node in graph.nodes:
    for version in node.versions:
      for (depName, ver) in graph.reqs[version.req].deps:
        if depName == targetPkgName:
          let revDep = (node.pkgName, version.version)
          result.addUnique revDep

proc getSolvedPackages*(pkgVersionTable: Table[string, PackageVersions], output: var string): seq[SolvedPackage] =
  var graph = pkgVersionTable.toDepGraph()
  #Make sure all references are in the graph before calling toFormular
  for p in graph.nodes:
    for ver in p.versions.items:
      for dep, q in items graph.reqs[ver.req].deps:
        if dep notin graph.packageToDependency:
          #debug print. show all packacges in the graph
          output.add &"Dependency {dep} not found in the graph \n"
          for k, v in pkgVersionTable:
            output.add &"Package {k} \n"
            for v in v.versions:
              output.add &"\t \t Version {v.version} requires: {v.requires} \n" 
          return newSeq[SolvedPackage]()
    
  let form = toFormular(graph)
  var packages = initTable[string, Version]()
  discard solve(graph, form, packages, output)
  
  for pkg, ver in packages:
    let nodeIdx = graph.packageToDependency[pkg]
    for dep in graph.nodes[nodeIdx].versions:
      if dep.version == ver:
        let reqIdx = dep.req
        let deps =  graph.reqs[reqIdx].deps
        let solvedPkg = SolvedPackage(pkgName: pkg, version: ver, 
          requirements: deps, 
          reverseDependencies: collectReverseDependencies(pkg, graph),
        )
        result.add solvedPkg

proc getCacheDownloadDir*(url: string, ver: VersionRange, options: Options): string =
  options.pkgCachePath / getDownloadDirName(url, ver, notSetSha1Hash)

proc downloadPkgFromUrl*(pv: PkgTuple, options: Options): (DownloadPkgResult, DownloadMethod) = 
  let (meth, url, metadata) = 
      getDownloadInfo(pv, options, doPrompt = false, ignorePackageCache = false)
  let subdir = metadata.getOrDefault("subdir")
  let downloadDir =  getCacheDownloadDir(url, pv.ver, options)
  let downloadRes = downloadPkg(url, pv.ver, meth, subdir, options,
                downloadDir, vcsRevision = notSetSha1Hash)
  (downloadRes, meth)
        
proc downloadPkInfoForPv*(pv: PkgTuple, options: Options): PackageInfo  =
  downloadPkgFromUrl(pv, options)[0].dir.getPkgInfo(options)

proc getAllNimReleases(options: Options): seq[PackageMinimalInfo] =
  let releases = getOfficialReleases(options)
  for release in releases:
    result.add PackageMinimalInfo(name: "nim", version: release)

proc getTaggedVersions*(repoDir: string, options: Options): Option[TaggedPackageVersions] =
  let file = repoDir / TaggedVersionsFileName
  if file.fileExists:
    try:
      let taggedVersions = file.readFile.parseJson().to(TaggedPackageVersions)
      if taggedVersions.maxTaggedVersions != options.maxTaggedVersions:
        return none(TaggedPackageVersions)
      return some taggedVersions
    except CatchableError as e:
      displayWarning(&"Error reading tagged versions: {e.msg}", HighPriority)
      return none(TaggedPackageVersions)
  else:
    none(TaggedPackageVersions)

proc saveTaggedVersions*(repoDir: string, taggedVersions: TaggedPackageVersions) =
  try:
    let file = repoDir / TaggedVersionsFileName
    file.writeFile((taggedVersions.toJson()).pretty)
  except CatchableError as e:
    displayWarning(&"Error saving tagged versions: {e.msg}", HighPriority)

proc getPackageMinimalVersionsFromRepo*(repoDir: string, name: string, version: Version, downloadMethod: DownloadMethod, options: Options): seq[PackageMinimalInfo] =
  #This is expensive. We need to cache it. Potentially it could be also run in parallel
  # echo &"Discovering version for {pkgName}"
  let taggedVersions = getTaggedVersions(repoDir, options)
  if taggedVersions.isSome:
    return taggedVersions.get.versions
  gitFetchTags(repoDir, downloadMethod)    
  #First package must be the current one
  try:
    result.add getPkgInfo(repoDir, options).getMinimalInfo(options)
  except CatchableError as e:
    displayWarning(&"Error getting package info for {name}: {e.msg}", HighPriority)
  let tags = getTagsList(repoDir, downloadMethod).getVersionList()
  var checkedTags = 0
  for (ver, tag) in tags.pairs:    
    if options.maxTaggedVersions > 0 and checkedTags >= options.maxTaggedVersions:
      # echo &"Tag limit reached for {pkgName}"
      break
    inc checkedTags
    #For each version, we need to parse the requires so we need to checkout and initialize the repo
    try:
      doCheckout(downloadMethod, repoDir, tag)
      let nimbleFile = findNimbleFile(repoDir, true, options)
      let pkgInfo = getPkgInfoFromFile(nimbleFile, options, useCache=false)
      result.addUnique  pkgInfo.getMinimalInfo(options)
    except CatchableError as e:
      displayWarning(&"Error reading tag {tag}: for package {name}. This may not be relevant as it could be an old version of the package. \n {e.msg}", HighPriority)
  
  #make sure we let this folder as it was
  for (ver, tag) in tags.pairs:    
    if ver == version:
      doCheckout(downloadMethod, repoDir, tag)

  saveTaggedVersions(repoDir, TaggedPackageVersions(maxTaggedVersions: options.maxTaggedVersions, versions: result))

proc downloadMinimalPackage*(pv: PkgTuple, options: Options): seq[PackageMinimalInfo] =
  if pv.name == "": return newSeq[PackageMinimalInfo]()
  if pv.isNim and not options.disableNimBinaries: return getAllNimReleases(options)
  if pv.ver.kind in [verSpecial, verEq]: #if special or equal, we dont retrieve more versions as we only need one.
    result = @[downloadPkInfoForPv(pv, options).getMinimalInfo(options)]
  else:
    let (downloadRes, downloadMeth) = downloadPkgFromUrl(pv, options)
    result = getPackageMinimalVersionsFromRepo(downloadRes.dir, pv.name, downloadRes.version, downloadMeth, options)
  # echo "Downloading minimal package for ", pv.name, " ", $pv.ver, result

proc fillPackageTableFromPreferred*(packages: var Table[string, PackageVersions], preferredPackages: seq[PackageMinimalInfo]) =
  for pkg in preferredPackages:
    if not hasVersion(packages, pkg.name, pkg.version):
      if not packages.hasKey(pkg.name):
        packages[pkg.name] = PackageVersions(pkgName: pkg.name, versions: @[pkg])
      else:
        packages[pkg.name].versions.add pkg

proc getInstalledMinimalPackages*(options: Options): seq[PackageMinimalInfo] =
  getInstalledPkgsMin(options.getPkgsDir(), options).mapIt(it.getMinimalInfo(options))


proc collectAllVersions*(versions: var Table[string, PackageVersions], package: PackageMinimalInfo, options: Options, getMinimalPackage: GetPackageMinimal, preferredPackages: seq[PackageMinimalInfo] = newSeq[PackageMinimalInfo]()) =
  proc getMinimalFromPreferred(pv: PkgTuple): seq[PackageMinimalInfo] =
    for pp in preferredPackages:
      if pp.name == pv.name and pp.version.withinRange(pv.ver):
        return @[pp]
    # echo "Getting minimal from getMinimalPackage for ", pv.name, " ", $pv.ver
    getMinimalPackage(pv, options)

  proc processRequirements(versions: var Table[string, PackageVersions], pv: PkgTuple) =
    if not hasVersion(versions, pv):
      var pkgMins = getMinimalFromPreferred(pv)
      for pkgMin in pkgMins.mitems:
        if pv.ver.kind == verSpecial:
          pkgMin.version = newVersion $pv.ver
        if not versions.hasKey(pv.name):
          versions[pv.name] = PackageVersions(pkgName: pv.name, versions: @[pkgMin])
        else:
          versions[pv.name].versions.addUnique pkgMin
        
        # Process requirements from both the package and GetMinimalPackage results
        for req in pkgMin.requires:
          # echo "Processing requirement: ", req.name, " ", $req.ver
          processRequirements(versions, req)

  for pv in package.requires:
    processRequirements(versions, pv)

proc topologicalSort*(solvedPkgs: seq[SolvedPackage]): seq[SolvedPackage] =
  var inDegree = initTable[string, int]()
  var adjList = initTable[string, seq[string]]()
  var zeroInDegree: seq[string] = @[]  
  # Initialize in-degree and adjacency list using requirements
  for pkg in solvedPkgs:
    if not inDegree.hasKey(pkg.pkgName):
      inDegree[pkg.pkgName] = 0  # Ensure every package is in the inDegree table
    for dep in pkg.requirements:
      if dep.name notin adjList:
        adjList[dep.name] = @[pkg.pkgName]  
      else:
        adjList[dep.name].add(pkg.pkgName)  
      inDegree[pkg.pkgName].inc  # Increase in-degree of this pkg since it depends on dep

  # Find all nodes with zero in-degree
  for (pkgName, degree) in inDegree.pairs:
    if degree == 0:
      zeroInDegree.add(pkgName)

  # Perform the topological sorting
  while zeroInDegree.len > 0:
    let current = zeroInDegree.pop()
    let currentPkg = solvedPkgs.filterIt(it.pkgName == current)[0]
    result.add(currentPkg)
    for neighbor in adjList.getOrDefault(current, @[]):
      inDegree[neighbor] -= 1
      if inDegree[neighbor] == 0:
        zeroInDegree.add(neighbor) 

proc solveLocalPackages*(rootPkgInfo: PackageInfo, pkgList: seq[PackageInfo], solvedPkgs: var seq[SolvedPackage], options: Options): HashSet[PackageInfo] = 
  var root = rootPkgInfo.getMinimalInfo(options)
  root.isRoot = true
  var pkgVersionTable = initTable[string, PackageVersions]()
  pkgVersionTable[root.name] = PackageVersions(pkgName: root.name, versions: @[root])
  fillPackageTableFromPreferred(pkgVersionTable, pkgList.mapIt(it.getMinimalInfo(options)))
  var output = ""
  solvedPkgs = pkgVersionTable.getSolvedPackages(output)
  for solvedPkg in solvedPkgs:
    for pkgInfo in pkgList:
      if pkgInfo.basicInfo.name == solvedPkg.pkgName and pkgInfo.basicInfo.version == solvedPkg.version:
        result.incl pkgInfo

proc solvePackages*(rootPkg: PackageInfo, pkgList: seq[PackageInfo], pkgsToInstall: var seq[(string, Version)], options: Options, output: var string, solvedPkgs: var seq[SolvedPackage]): HashSet[PackageInfo] =
  var root: PackageMinimalInfo = rootPkg.getMinimalInfo(options)
  root.isRoot = true
  var pkgVersionTable = initTable[string, PackageVersions]()
  pkgVersionTable[root.name] = PackageVersions(pkgName: root.name, versions: @[root])
  collectAllVersions(pkgVersionTable, root, options, downloadMinimalPackage, pkgList.mapIt(it.getMinimalInfo(options)))
  solvedPkgs = pkgVersionTable.getSolvedPackages(output).topologicalSort()

  for solvedPkg in solvedPkgs:
    if solvedPkg.pkgName == root.name: continue
    var foundInList = false
    for pkgInfo in pkgList:
      if pkgInfo.basicInfo.name == solvedPkg.pkgName and pkgInfo.basicInfo.version == solvedPkg.version:
        result.incl pkgInfo
        foundInList = true
    if not foundInList:
      pkgsToInstall.addUnique((solvedPkg.pkgName, solvedPkg.version))

proc getPackageInfo*(name: string, pkgs: seq[PackageInfo], version: Option[Version] = none(Version)): Option[PackageInfo] =
    for pkg in pkgs:
      if pkg.basicInfo.name.tolower == name.tolower or pkg.metadata.url == name:
        if version.isSome:
          if pkg.basicInfo.version == version.get:
            return some pkg
        else: #No version passed over first match
          return some pkg
