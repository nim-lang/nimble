import sat/[sat, satvars] 
import version, packageinfotypes, download, packageinfo, packageparser, options, 
  sha1hashes, tools, downloadnim, cli, declarativeparser
  
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

    
  GetPackageMinimal* = proc (pv: PkgTuple, options: Options): seq[PackageMinimalInfo]

  TaggedPackageVersions = object
    maxTaggedVersions: int # Maximum number of tags. When number changes, we invalidate the cache
    versions: seq[PackageMinimalInfo]
  
  VersionAttempt = tuple[pkgName: string, version: Version]

  PackageDownloadInfo* = object
    meth*: DownloadMethod
    url*: string
    subdir*: string
    downloadDir*: string
    pv*: PkgTuple #Require request

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

proc convertNimAliasToNim*(pv: PkgTuple): PkgTuple = 
  #Compiler needs to be treated as Nim as long as it isnt a separated package. See https://github.com/nim-lang/Nim/issues/23049
  #Also notice compiler and nim are aliases.
  if pv.name notin ["nimrod", "compiler"]: pv
  else: (name: "nim", ver: pv.ver)

proc getMinimalInfo*(pkg: PackageInfo, options: Options): PackageMinimalInfo =
  result.name = if pkg.basicInfo.name.isNim: "nim" else: pkg.basicInfo.name
  result.version = pkg.basicInfo.version
  result.requires = pkg.requires.map(convertNimAliasToNim)
  if options.action.typ in {actionLock, actionDeps} or options.hasNimInLockFile():
    result.requires = result.requires.filterIt(not it.isNim)

proc getMinimalInfo*(nimbleFile: string, pkgName: string, options: Options): PackageMinimalInfo =
  #TODO we can use the new getPkgInfoFromDirWithDeclarativeParser to get the minimal info and add the features to the packageinfo type so this whole function can be removed
  assert options.useDeclarativeParser, "useDeclarativeParser must be set"
  let nimbleFileInfo = extractRequiresInfo(nimbleFile)
  result.name =  if pkgName.isNim: "nim" else: pkgName
  result.version = nimbleFileInfo.version.newVersion()
  var activeFeatures = initTable[PkgTuple, seq[string]]() #we can ignore features here as we are solving at this point requires for these features should already be taken into account
  result.requires = nimbleFileInfo.getRequires(activeFeatures) #TODO if package is Nim do not parse the file. Just get the version from the binary.
  if options.action.typ in {actionLock, actionDeps} or options.hasNimInLockFile():
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
  result = Form()
  var b = Builder()
  b.openOpr(AndForm)
  
  # First pass: Assign variables and encode version selection constraints
  for p in mitems(g.nodes):
    if p.versions.len == 0: continue
    p.versions.sort(cmp)
    
    # Version selection constraint
    if p.isRoot:
      b.openOpr(ExactlyOneOfForm)
      for ver in mitems p.versions:
        ver.v = VarId(result.idgen)
        result.mapping[ver.v] = SatVarInfo(pkg: p.pkgName, version: ver.version, index: result.idgen)
        b.add(ver.v)
        inc result.idgen
      b.closeOpr()
    else:
      # For non-root packages, assign variables first
      for ver in mitems p.versions:
        ver.v = VarId(result.idgen)
        result.mapping[ver.v] = SatVarInfo(pkg: p.pkgName, version: ver.version, index: result.idgen)
        inc result.idgen
      
      # Then add ZeroOrOneOf constraint
      b.openOpr(ZeroOrOneOfForm)
      for ver in p.versions:
        b.add(ver.v)
      b.closeOpr()

  # Second pass: Encode dependency implications
  for p in mitems(g.nodes):
    for ver in p.versions.mitems:
      var allDepsCompatible = true
      
      # First check if all dependencies can be satisfied
      for dep, q in items g.reqs[ver.req].deps:
        let depIdx = findDependencyForDep(g, dep)
        if depIdx < 0: continue
        let depNode = g.nodes[depIdx]
        
        var hasCompatible = false
        for depVer in depNode.versions:
          if depVer.version.withinRange(q):
            hasCompatible = true
            break
        
        if not hasCompatible:
          allDepsCompatible = false
          break

      # If any dependency can't be satisfied, make this version unsatisfiable
      if not allDepsCompatible:
        b.addNegated(ver.v)
        continue

      # Add implications for each dependency
      for dep, q in items g.reqs[ver.req].deps:
        let depIdx = findDependencyForDep(g, dep)
        if depIdx < 0: continue
        let depNode = g.nodes[depIdx]
        
        var compatibleVersions: seq[VarId] = @[]
        for depVer in depNode.versions:
          if depVer.version.withinRange(q):
            compatibleVersions.add(depVer.v)
        
        # Add implication: if this version is selected, one of its compatible deps must be selected
        b.openOpr(OrForm)
        b.addNegated(ver.v)  # not A
        b.openOpr(OrForm)    # or (B1 or B2 or ...)
        for compatVer in compatibleVersions:
          b.add(compatVer)
        b.closeOpr()
        b.closeOpr()
  
  b.closeOpr()
  result.f = toForm(b)

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

proc analyzeVersionSelection(g: DepGraph, f: Form, s: Solution): string =
  result = "Version selection analysis:\n"
  
  # Check which versions were selected
  for node in g.nodes:
    result.add &"\nPackage {node.pkgName}:"
    var selectedVersion: Option[Version]
    for ver in node.versions:
      if s.isTrue(ver.v):
        selectedVersion = some(ver.version)
        result.add &"\n  Selected: {ver.version}"
        # Show requirements for selected version
        let reqs = g.reqs[ver.req].deps
        result.add "\n  Requirements:"
        for req in reqs:
          result.add &"\n    {req.name} {req.ver}"
    if selectedVersion.isNone:
      result.add "\n  No version selected!"
      result.add "\n  Available versions:"
      for ver in node.versions:
        result.add &"\n    {ver.version}"

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

proc solve*(g: var DepGraph; f: Form, packages: var Table[string, Version], output: var string, 
           triedVersions: var seq[VersionAttempt]): bool =
  let m = f.idgen
  var s = createSolution(m)
  
  if satisfiable(f.f, s):
    # output.add analyzeVersionSelection(g, f, s)
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
    output.add "\nFailed to find satisfiable solution:\n"
    output.add analyzeVersionSelection(g, f, s)
    let (failingSet, errorMsg) = findMinimalFailingSet(g)
    if failingSet.len > 0:
      var newGraph = g
      
      # Try each failing package
      for pkg in failingSet:
        let idx = findDependencyForDep(newGraph, pkg.name)
        if idx >= 0:
          let originalVersions = newGraph.nodes[idx].versions
          # Try each version once, from newest to oldest
          for ver in originalVersions:
            let attempt = (pkgName: pkg.name, version: ver.version)
            if attempt notin triedVersions:
              triedVersions.add(attempt)
              # echo "Trying package ", pkg.name, " version ", ver.version
              newGraph.nodes[idx].versions = @[ver]  # Try just this version
              let newForm = toFormular(newGraph)
              if solve(newGraph, newForm, packages, output, triedVersions):
                return true
          # Restore original versions if no solution found
          newGraph.nodes[idx].versions = originalVersions
      
      output.add "\n\nFinal error message:\n"  # Add a separator
      output.add errorMsg
    else:
      output.add "\n\nFinal error message:\n"  # Add a separator
      output.add generateUnsatisfiableMessage(g, f, s)
    false


proc solve*(g: var DepGraph; f: Form, packages: var Table[string, Version], output: var string): bool =
  var triedVersions = newSeq[VersionAttempt]()
  solve(g, f, packages, output, triedVersions)

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
  var triedVersions: seq[VersionAttempt] = @[]
  discard solve(graph, form, packages, output, triedVersions)
  
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

  # Collect the deps for every solved package
  for solvedPkg in result.mitems:
    for (depName, depVer) in solvedPkg.requirements:
      for otherPkg in result:
        if otherPkg.pkgName == depName and otherPkg.version.withinRange(depVer):
          solvedPkg.deps.add(otherPkg)
          break

proc getCacheDownloadDir*(url: string, ver: VersionRange, options: Options): string =
  options.pkgCachePath / getDownloadDirName(url, ver, notSetSha1Hash)

proc getPackageDownloadInfo*(pv: PkgTuple, options: Options, doPrompt = false): PackageDownloadInfo =
  let (meth, url, metadata) = 
      getDownloadInfo(pv, options, doPrompt, ignorePackageCache = false)
  let subdir = metadata.getOrDefault("subdir")
  let downloadDir = getCacheDownloadDir(url, pv.ver, options)
  PackageDownloadInfo(meth: meth, url: url, subdir: subdir, downloadDir: downloadDir, pv: pv)

proc downloadFromDownloadInfo*(dlInfo: PackageDownloadInfo, options: Options): (DownloadPkgResult, DownloadMethod) = 
  let downloadRes = downloadPkg(dlInfo.url, dlInfo.pv.ver, dlInfo.meth, dlInfo.subdir, options,
                dlInfo.downloadDir, vcsRevision = notSetSha1Hash)
  (downloadRes, dlInfo.meth)

proc downloadPkgFromUrl*(pv: PkgTuple, options: Options, doPrompt = false): (DownloadPkgResult, DownloadMethod) = 
  let dlInfo = getPackageDownloadInfo(pv, options, doPrompt)
  downloadFromDownloadInfo(dlInfo, options)
        
proc downloadPkInfoForPv*(pv: PkgTuple, options: Options, doPrompt = false): PackageInfo  =
  let downloadRes = downloadPkgFromUrl(pv, options, doPrompt)
  if options.satResult.pass in {satNimSelection, satFallbackToVmParser}:
    getPkgInfoFromDirWithDeclarativeParser(downloadRes[0].dir, options)
  else:
    downloadRes[0].dir.getPkgInfo(options)

proc getAllNimReleases(options: Options): seq[PackageMinimalInfo] =
  let releases = getOfficialReleases(options)  
  for release in releases:
    result.add PackageMinimalInfo(name: "nim", version: release)
  
  if options.nimBin.isSome:
    result.addUnique PackageMinimalInfo(name: "nim", version: options.nimBin.get.version)

proc getTaggedVersions*(repoDir, pkgName: string, options: Options): Option[TaggedPackageVersions] =
  var file: string
  if options.localDeps:
    file = options.getNimbleDir / "pkgcache" / "tagged" / pkgName & ".json"
  else: 
    file = repoDir / TaggedVersionsFileName
  if file.fileExists:
    try:
      let taggedVersions = file.readFile.parseJson().to(TaggedPackageVersions)
      if taggedVersions.maxTaggedVersions != options.maxTaggedVersions:
        return none(TaggedPackageVersions)
      return some taggedVersions
    except CatchableError as e:
      displayWarning(&"Error reading tagged versions: {e.msg} for {pkgName}", HighPriority)
      return none(TaggedPackageVersions)
  else:
    return none(TaggedPackageVersions)

proc saveTaggedVersions*(repoDir, pkgName: string, taggedVersions: TaggedPackageVersions, options: Options) =
  var file: string
  if options.localDeps:
    file = options.getNimbleDir / "pkgcache" / "tagged" / pkgName & ".json"
  else: 
    file = repoDir / TaggedVersionsFileName
  try:
    createDir(file.parentDir)
    file.writeFile((taggedVersions.toJson()).pretty)
  except CatchableError as e:
    displayWarning(&"Error saving tagged versions: {e.msg}", HighPriority)

proc getPackageMinimalVersionsFromRepo*(repoDir: string, pkg: PkgTuple, version: Version, downloadMethod: DownloadMethod, options: Options): seq[PackageMinimalInfo] =
  result = newSeq[PackageMinimalInfo]()
  
  let name = pkg[0]
  let taggedVersions = getTaggedVersions(repoDir, name, options)
  if taggedVersions.isSome:
    return taggedVersions.get.versions

  let tempDir = repoDir & "_versions"
  try:
    removeDir(tempDir) 
    copyDir(repoDir, tempDir)
    var tags = initOrderedTable[Version, string]()
    try:
      gitFetchTags(tempDir, downloadMethod, options)    
      tags = getTagsList(tempDir, downloadMethod).getVersionList()
    except CatchableError as e:
      displayWarning(&"Error fetching tags for {name}: {e.msg}", HighPriority)
    
    try:
      if options.satResult.pass in {satNimSelection, satFallbackToVmParser}:
        #TODO test this code path
        result.add getPkgInfoFromDirWithDeclarativeParser(repoDir, options).getMinimalInfo(options)   
      else:
        result.add getPkgInfo(repoDir, options).getMinimalInfo(options)   
    except CatchableError as e:
      displayWarning(&"Error getting package info for {name}: {e.msg}", HighPriority)
    
    # Process tagged versions in the temporary copy
    var checkedTags = 0
    for (ver, tag) in tags.pairs:    
      if options.maxTaggedVersions > 0 and checkedTags >= options.maxTaggedVersions:
        break
      inc checkedTags
      
      try:
        let tagVersion = newVersion($ver)

        if not tagVersion.withinRange(pkg[1]):
          displayInfo(&"Ignoring {name}:{tagVersion} because out of range {pkg[1]}")
          break

        doCheckout(downloadMethod, tempDir, tag, options)
        let nimbleFile = findNimbleFile(tempDir, true, options)
        if options.satResult.pass in {satNimSelection, satFallbackToVmParser}:
          result.addUnique getPkgInfoFromDirWithDeclarativeParser(repoDir, options).getMinimalInfo(options)  
        elif options.useDeclarativeParser:
          result.addUnique getMinimalInfo(nimbleFile, name, options)
        else:
          let pkgInfo = getPkgInfoFromFile(nimbleFile, options, useCache=false)
          result.addUnique pkgInfo.getMinimalInfo(options)
      except CatchableError as e:
        displayWarning(
          &"Error reading tag {tag}: for package {name}. This may not be relevant as it could be an old version of the package. \n {e.msg}",
           HighPriority)
    if not (options.isVNext and options.satResult.pass == satNimSelection and options.satResult.declarativeParseFailed):
      #Dont save tagged versions if we are in vNext and the declarative parser failed as this could cache the incorrect versions.
      #its suboptimal in the sense that next packages after failure wont be saved in the first past but there is a guarantee that there is a second pass in the case 
      #the declarative parser fails so they will be saved then.
      saveTaggedVersions(repoDir, name, 
                        TaggedPackageVersions(
                          maxTaggedVersions: options.maxTaggedVersions, 
                          versions: result
                        ), options)
  finally:
    try:
      removeDir(tempDir)
    except CatchableError as e:
      displayWarning(&"Error cleaning up temporary directory {tempDir}: {e.msg}", LowPriority)

proc downloadMinimalPackage*(pv: PkgTuple, options: Options): seq[PackageMinimalInfo] =
  if pv.name == "": return newSeq[PackageMinimalInfo]()
  if pv.isNim and not options.disableNimBinaries: return getAllNimReleases(options)
  if pv.ver.kind in [verSpecial, verEq]: #if special or equal, we dont retrieve more versions as we only need one.
    result = @[downloadPkInfoForPv(pv, options).getMinimalInfo(options)]
  else:    
    let (downloadRes, downloadMeth) = downloadPkgFromUrl(pv, options)
    result = getPackageMinimalVersionsFromRepo(downloadRes.dir, pv, downloadRes.version, downloadMeth, options)
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

proc getMinimalFromPreferred(pv: PkgTuple,  getMinimalPackage: GetPackageMinimal, preferredPackages: seq[PackageMinimalInfo], options: Options): seq[PackageMinimalInfo] =
  for pp in preferredPackages:
    if pp.name == pv.name and pp.version.withinRange(pv.ver):
      return @[pp]
  getMinimalPackage(pv, options)

proc processRequirements(versions: var Table[string, PackageVersions], pv: PkgTuple, visited: var HashSet[PkgTuple],  getMinimalPackage: GetPackageMinimal, preferredPackages: seq[PackageMinimalInfo] = newSeq[PackageMinimalInfo](), options: Options) =
  if pv in visited:
    return
  
  visited.incl pv
  
  if not hasVersion(versions, pv):
    var pkgMins = getMinimalFromPreferred(pv, getMinimalPackage, preferredPackages, options)
    for pkgMin in pkgMins.mitems:
      if pv.ver.kind == verSpecial:
        pkgMin.version = newVersion $pv.ver
      if not versions.hasKey(pv.name):
        versions[pv.name] = PackageVersions(pkgName: pv.name, versions: @[pkgMin])
      else:
        versions[pv.name].versions.addUnique pkgMin
      
      for req in pkgMin.requires:
        processRequirements(versions, req, visited, getMinimalPackage, preferredPackages, options)

proc collectAllVersions*(versions: var Table[string, PackageVersions], package: PackageMinimalInfo, options: Options, getMinimalPackage: GetPackageMinimal, preferredPackages: seq[PackageMinimalInfo] = newSeq[PackageMinimalInfo]()) =
  var visited = initHashSet[PkgTuple]()
  for pv in package.requires:
    processRequirements(versions, pv, visited, getMinimalPackage, preferredPackages, options)

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

proc isSystemNimCompatible*(solvedPkgs: seq[SolvedPackage], options: Options): bool =
  if options.action.typ in {actionLock, actionDeps} or options.hasNimInLockFile():
    return false
  for solvedPkg in solvedPkgs:
    for req in solvedPkg.requirements:
      if req.isNim and options.nimBin.isSome and not options.nimBin.get.version.withinRange(req.ver):
        return false
  true

proc solveLocalPackages*(rootPkgInfo: PackageInfo, pkgList: seq[PackageInfo], solvedPkgs: var seq[SolvedPackage], systemNimCompatible: var bool, options: Options): HashSet[PackageInfo] = 
  var root = rootPkgInfo.getMinimalInfo(options)
  root.isRoot = true
  var pkgVersionTable = initTable[string, PackageVersions]()
  pkgVersionTable[root.name] = PackageVersions(pkgName: root.name, versions: @[root])
  fillPackageTableFromPreferred(pkgVersionTable, pkgList.mapIt(it.getMinimalInfo(options)))
  var output = ""
  solvedPkgs = pkgVersionTable.getSolvedPackages(output)
  systemNimCompatible = solvedPkgs.isSystemNimCompatible(options)
  
  for solvedPkg in solvedPkgs:
    if solvedPkg.pkgName.isNim and systemNimCompatible:     
      continue #Dont add nim from the solution as we will use system nim
    for pkgInfo in pkgList:
      if (pkgInfo.basicInfo.name == solvedPkg.pkgName or pkgInfo.metadata.url == solvedPkg.pkgName) and 
        (pkgInfo.basicInfo.version == solvedPkg.version or solvedPkg.version in pkgInfo.metadata.specialVersions):
          result.incl pkgInfo

proc solvePackages*(rootPkg: PackageInfo, pkgList: seq[PackageInfo], pkgsToInstall: var seq[(string, Version)], options: Options, output: var string, solvedPkgs: var seq[SolvedPackage]): HashSet[PackageInfo] =
  var root: PackageMinimalInfo = rootPkg.getMinimalInfo(options)
  root.isRoot = true
  var pkgVersionTable = initTable[string, PackageVersions]()
  pkgVersionTable[root.name] = PackageVersions(pkgName: root.name, versions: @[root])
  collectAllVersions(pkgVersionTable, root, options, downloadMinimalPackage, pkgList.mapIt(it.getMinimalInfo(options)))
  solvedPkgs = pkgVersionTable.getSolvedPackages(output).topologicalSort()
  let systemNimCompatible = solvedPkgs.isSystemNimCompatible(options)
  
  for solvedPkg in solvedPkgs:
    if solvedPkg.pkgName == root.name: continue    
    var foundInList = false
    for pkgInfo in pkgList:
      if (pkgInfo.basicInfo.name == solvedPkg.pkgName or pkgInfo.metadata.url == solvedPkg.pkgName) and 
        (pkgInfo.basicInfo.version == solvedPkg.version or solvedPkg.version in pkgInfo.metadata.specialVersions):
          result.incl pkgInfo
          foundInList = true
    if not foundInList:
      # displayInfo(&"Coudlnt find {solvedPkg.pkgName}", priority = HighPriority)
      if solvedPkg.pkgName.isNim and systemNimCompatible:
        continue #Skips systemNim
      pkgsToInstall.addUnique((solvedPkg.pkgName, solvedPkg.version))

proc getPackageInfo*(name: string, pkgs: seq[PackageInfo], version: Option[Version] = none(Version)): Option[PackageInfo] =
    for pkg in pkgs:
      if pkg.basicInfo.name.tolower == name.tolower or pkg.metadata.url == name:
        if version.isSome:
          if pkg.basicInfo.version == version.get:
            return some pkg
        else: #No version passed over first match
          return some pkg

proc getPkgVersionTable*(pkgInfo: PackageInfo, pkgList: seq[PackageInfo], options: Options): Table[string, PackageVersions] =
  result = initTable[string, PackageVersions]()
  var root = pkgInfo.getMinimalInfo(options)
  root.isRoot = true
  result[root.name] = PackageVersions(pkgName: root.name, versions: @[root])
  collectAllVersions(result, root, options, downloadMinimalPackage, pkgList.mapIt(it.getMinimalInfo(options)))


const maxPkgNameDisplayWidth = 40  # Cap package name width
const maxVersionDisplayWidth = 10  # Cap version width

proc formatPkgName(pkgName: string, maxWidth = maxPkgNameDisplayWidth): string =
  result = pkgName
  if result.startsWith("https:"):
    let parts = result.split('/')
    result = parts[^1]
  # Handle git repo names with extension
  if result.endsWith(".git"):
    result = result[0..^5]  # Remove .git suffix
  
  # Truncate if still too long
  if result.len > maxWidth - 3:
    result = result[0..<(maxWidth - 3)] & "..."

proc dumpSolvedPackages*(pkgInfo: PackageInfo, pkgList: seq[PackageInfo], options: Options) =
  var pkgToInstall: seq[(string, Version)] = @[]
  var output = ""
  var solvedPkgs: seq[SolvedPackage] = @[]
  discard solvePackages(pkgInfo, pkgList, pkgToInstall, options, output, solvedPkgs)

  echo "PACKAGE".alignLeft(maxPkgNameDisplayWidth), "VERSION".alignLeft(maxVersionDisplayWidth), "REQUIREMENTS"
  echo "-".repeat(maxPkgNameDisplayWidth + maxVersionDisplayWidth + 4)
  
  # Sort packages alphabetically
  var sortedPackages = solvedPkgs
  sortedPackages.sort(proc(a, b: SolvedPackage): int =
    result = cmp(a.pkgName, b.pkgName)
    if result == 0:
      result = cmp(a.version, b.version)
  )
  
  # Find the pkgInfo package in the solved packages and move it to the front
  for i, pkg in sortedPackages:
    if pkg.pkgName == pkgInfo.basicInfo.name:
      let rootPkg = sortedPackages[i]
      sortedPackages.delete(i)
      sortedPackages.insert(rootPkg, 0)
      break
  
  # Display each package
  for i, pkg in sortedPackages:
    var displayName = formatPkgName(pkg.pkgName)
    
    # Mark root package with an asterisk (either it's the first package after sorting, or it's pkgInfo)
    let rootMarker = if pkg.pkgName == pkgInfo.basicInfo.name: "*" else: " "
    
    # Format requirements
    var reqStr = ""
    for i, req in pkg.requirements:
      if i > 0: reqStr.add ", "
      
      var reqName = formatPkgName(req.name)
      reqStr.add reqName
      if req.ver.kind != verAny:
        reqStr.add " " & $req.ver
    
    # Display package line
    echo rootMarker, " ", 
         displayName.alignLeft(maxPkgNameDisplayWidth - 1), 
         $pkg.version.version.alignLeft(maxVersionDisplayWidth), 
         if reqStr.len > 0: reqStr.splitLines()[0] else: ""
    
    # If requirements were long, display them on additional indented lines
    if reqStr.len > 0 and (reqStr.contains('\n') or reqStr.len > 80):
      let lines = reqStr.split(", ")
      var currentLine = ""
      for i, req in lines:
        if currentLine.len + req.len + 2 > 80:  # +2 for ", "
          if currentLine.len > 0:
            echo " ".repeat(maxPkgNameDisplayWidth + maxVersionDisplayWidth + 3), currentLine
          currentLine = req
        else:
          if currentLine.len > 0:
            currentLine.add ", "
          currentLine.add req
      
      if currentLine.len > 0:
        echo " ".repeat(maxPkgNameDisplayWidth + maxVersionDisplayWidth + 3), currentLine
    
    # Show reverse dependencies indented underneath - UPDATED to group by package name
    if pkg.reverseDependencies.len > 0:
      var depStr = "Required by: "
      
      # Group dependencies by package name
      var depGroups = initTable[string, seq[Version]]()
      for revDep in pkg.reverseDependencies:
        var depName = revDep[0].formatPkgName()
        
        if not depGroups.hasKey(depName):
          depGroups[depName] = @[]
        depGroups[depName].add(revDep[1])
      
      var depNames = toSeq(depGroups.keys)
      depNames.sort()
      
      # Format each dependency group
      var currentLine = depStr
      var lineLen = depStr.len
      
      for i, depName in depNames:
        var versions = depGroups[depName]
        
        # Sort versions in descending order
        versions.sort(proc(a, b: Version): int = 
          if a > b: -1
          elif a < b: 1
          else: 0
        )
        
        # Format versions as a compact list
        var versionStr = ""
        if versions.len == 1:
          versionStr = $versions[0].version
        else:
          versionStr = "v(" & versions.mapIt($it.version).join(", ") & ")"
        
        let depEntry = depName & " " & versionStr
        
        if i > 0:
          if lineLen + 2 + depEntry.len > 80:
            echo " ".repeat(maxPkgNameDisplayWidth + maxVersionDisplayWidth + 3), currentLine
            currentLine = "            " & depEntry
            lineLen = 12 + depEntry.len
          else:
            currentLine.add ", " & depEntry
            lineLen += 2 + depEntry.len
        else:
          currentLine.add depEntry
          lineLen += depEntry.len
      
      echo " ".repeat(maxPkgNameDisplayWidth + maxVersionDisplayWidth + 3), currentLine

proc dumpPackageVersionTable*(pkg: PackageInfo, pkgList: seq[PackageInfo], options: Options) =
  let pkgVersionTable = getPkgVersionTable(pkg, pkgList, options)

  # Display header
  echo "PACKAGE".alignLeft(maxPkgNameDisplayWidth), "VERSION".alignLeft(maxVersionDisplayWidth), "REQUIREMENTS"
  echo "-".repeat(maxPkgNameDisplayWidth + maxVersionDisplayWidth + 4)
  
  var sortedPackages = toSeq(pkgVersionTable.keys)
  sortedPackages.sort()
  
  if pkg.basicInfo.name in sortedPackages:
    sortedPackages.delete(sortedPackages.find(pkg.basicInfo.name))
    sortedPackages.insert(pkg.basicInfo.name, 0)
  
  # Display each package and its versions
  for pkgName in sortedPackages:
    let pkgVersions = pkgVersionTable[pkgName]
    var isFirstVersion = true
    
    # Sort versions in descending order (newest first)
    var sortedVersions = pkgVersions.versions
    sortedVersions.sort(proc(a, b: PackageMinimalInfo): int = 
      if a.version > b.version: -1
      elif a.version < b.version: 1
      else: 0
    )
    
    for version in sortedVersions:
      # Format package name - extract repo name for GitHub URLs
      var displayName = formatPkgName(pkgName)
      
      # Only show package name for first version
      let name = if isFirstVersion: displayName else: ""
      let rootMarker = if version.isRoot: "*" else: " "
      
      # Format requirements
      var reqStr = ""
      for i, req in version.requires:
        if i > 0: reqStr.add ", "
        
        var reqName = formatPkgName(req.name)
        
        reqStr.add reqName
        if req.ver.kind != verAny:
          reqStr.add " " & $req.ver
      
      # Display version line
      echo rootMarker, " ", 
           name.alignLeft(maxPkgNameDisplayWidth - 1), 
           $version.version.version.alignLeft(maxVersionDisplayWidth), 
           if reqStr.len > 0: reqStr.splitLines()[0] else: ""
      
      # If requirements were long, display them on additional indented lines
      if reqStr.len > 0 and (reqStr.contains('\n') or reqStr.len > 80):
        let lines = reqStr.split(", ")
        var currentLine = ""
        for i, req in lines:
          if currentLine.len + req.len + 2 > 80:  # +2 for ", "
            if currentLine.len > 0:
              echo " ".repeat(maxPkgNameDisplayWidth + maxVersionDisplayWidth + 3), currentLine
            currentLine = req
          else:
            if currentLine.len > 0:
              currentLine.add ", "
            currentLine.add req
        
        if currentLine.len > 0:
          echo " ".repeat(maxPkgNameDisplayWidth + maxVersionDisplayWidth + 3), currentLine
      
      isFirstVersion = false