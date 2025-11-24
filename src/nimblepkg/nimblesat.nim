import sat/[sat, satvars]
import version, packageinfotypes, download, packageinfo, packageparser, options,
  sha1hashes, tools, downloadnim, cli, declarativeparser

import std/[tables, sequtils, algorithm, sets, strutils, options, strformat, os, json, jsonutils, uri]
import chronos

type  
  SatVarInfo* = object # attached information for a SAT variable
    pkg*: string
    version*: Version
    index*: int

  Form* = object
    f*: Formular
    mapping*: Table[VarId, SatVarInfo]
    idgen*: int32
  
  Requirements* = object
    deps*: seq[PkgTuple] #@[(name, versRange)]
    version*: Version
    nimVersion*: Version
    v*: VarId
    err*: string

  DependencyVersion* = object  # Represents a specific version of a project.
    version*: Version
    url*: string
    req*: int # index into graph.reqs so that it can be shared between versions
    v*: VarId
    # req: Requirements

  Dependency* = object
    pkgName*: string
    url*: string
    versions*: seq[DependencyVersion]
    active*: bool
    activeVersion*: int
    isRoot*: bool

  DepGraph* = object
    nodes*: seq[Dependency]
    reqs*: seq[Requirements]
    packageToDependency*: Table[string, int] #package.name -> index into nodes
    # reqsByDeps: Table[Requirements, int]

    
  GetPackageMinimal* = proc (pv: PkgTuple, options: Options, nimBin: string): seq[PackageMinimalInfo]
  GetPackageMinimalAsync* = proc (pv: PkgTuple, options: Options, nimBin: string): Future[seq[PackageMinimalInfo]] {.gcsafe.}

  TaggedPackageVersions = object
    maxTaggedVersions: int # Maximum number of tags. When number changes, we invalidate the cache
    versions: seq[PackageMinimalInfo]
  
  VersionAttempt = tuple[pkgName: string, version: Version]

  PackageDownloadInfo* = object
    meth*: Option[DownloadMethod] #None for file dependencies. File dependencies are not copied over to the cache
    url*: string
    subdir*: string
    downloadDir*: string
    pv*: PkgTuple #Require request
  
# var urlToName: Table[string, string] = initTable[string, string]()

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
  result.url = pkg.metadata.url

proc getMinimalInfo*(nimbleFile: string, options: Options, nimBin: string): PackageMinimalInfo =
  #TODO we can use the new getPkgInfoFromDirWithDeclarativeParser to get the minimal info and add the features to the packageinfo type so this whole function can be removed
  #TODO we need to handle the url here as well.
  assert options.useDeclarativeParser, "useDeclarativeParser must be set"
  let pkg = getPkgInfoFromDirWithDeclarativeParser(nimbleFile.parentDir, options, nimBin)
  result.name =  if pkg.basicInfo.name.isNim: "nim" else: pkg.basicInfo.name
  result.version = pkg.basicInfo.version
  result.requires = pkg.requires.map(convertNimAliasToNim)
  result.url = pkg.metadata.url
  if options.action.typ in {actionLock, actionDeps} or options.hasNimInLockFile():
    result.requires = result.requires.filterIt(not it.isNim)

proc hasVersion*(packageVersions: PackageVersions, pv: PkgTuple): bool =
  for pkg in packageVersions.versions:
    if pkg.name == pv.name:
      # Special versions must match exactly for collection purposes
      if pv.ver.kind == verSpecial:
        return $pkg.version == $pv.ver
      # Regular version ranges
      elif pkg.version.withinRange(pv.ver):
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

proc hasKey(packageToDependency: Table[string, int], dep: string): bool =
  for k in packageToDependency.keys:
    if cmpIgnoreCase(k, dep) == 0:
      return true
  false

proc getKey(packageToDependency: Table[string, int], dep: string): int =
  for k in packageToDependency.keys:
    if cmpIgnoreCase(k, dep) == 0:
      return packageToDependency[k]
  raise newException(KeyError, dep & " not found")

proc findDependencyForDep(g: DepGraph; dep: string): int {.inline.} =
  if not g.packageToDependency.hasKey(dep):
    return -1
  result = g.packageToDependency.getKey(dep)

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
  result.url = pkg.url

proc toDependency(g: var DepGraph, pkg: PackageVersions): Dependency = 
  result.pkgName = pkg.pkgName
  result.versions = pkg.versions.mapIt(toDependencyVersion(g, it))
  assert pkg.versions.len > 0, "Package must have at least one version"
  result.isRoot = pkg.versions[0].isRoot
  result.url = pkg.versions[0].url

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
    #also add the urls
    for ver in result.nodes[i].versions:
      if ver.url != "":
        # echo "ADDING URL: ", ver.url
        result.packageToDependency[ver.url] = i

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

proc safeSatisfiable(f: Form, s: var Solution): bool =
  try:
    if satisfiable(f.f, s):
      return true
    else:
      return false
  except SatOverflowError:
    return false

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
    if not safeSatisfiable(tempForm, tempSolution):
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
           triedVersions: var seq[VersionAttempt], options: Options): bool {.instrument.} =
  let m = f.idgen
  var s = createSolution(m)
  if safeSatisfiable(f, s):
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
    output.add "\nFailed to find satisfiable solution (pass: {options.satResult.pass}):\n"
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
              if solve(newGraph, newForm, packages, output, triedVersions, options):
                return true
          # Restore original versions if no solution found
          newGraph.nodes[idx].versions = originalVersions
      
      output.add "\n\nFinal error message:\n"  # Add a separator
      output.add errorMsg
    else:
      output.add "\n\nFinal error message:\n"  # Add a separator
      output.add generateUnsatisfiableMessage(g, f, s)
    false


proc solve*(g: var DepGraph; f: Form, packages: var Table[string, Version], output: var string, options: Options): bool =
  var triedVersions = newSeq[VersionAttempt]()
  solve(g, f, packages, output, triedVersions, options)

proc collectReverseDependencies*(targetPkgName: string, graph: DepGraph): seq[(string, Version)] =
  # Build URL lookup table once
  var urlToPkgName = initTable[string, string]()
  for node in graph.nodes:
    if cmpIgnoreCase(node.pkgName, targetPkgName) == 0:
      for version in node.versions:
        if version.url != "":
          urlToPkgName[version.url.toLower] = node.pkgName

  for node in graph.nodes:
    for version in node.versions:
      for (depName, ver) in graph.reqs[version.req].deps:
        if cmpIgnoreCase(depName, targetPkgName) == 0:
          let revDep = (node.pkgName, version.version)
          result.addUnique revDep
        elif urlToPkgName.hasKey(depName.toLower):
          # Check if this dependency matches by URL
          let revDep = (node.pkgName, version.version)
          result.addUnique revDep

proc getSolvedPackages*(pkgVersionTable: Table[string, PackageVersions], output: var string, options: Options): seq[SolvedPackage] {.instrument.} =
  var graph = pkgVersionTable.toDepGraph()
  #Make sure all references are in the graph before calling toFormular
  for p in graph.nodes:
    for ver in p.versions.items:
      for dep, q in items graph.reqs[ver.req].deps:
        if not graph.packageToDependency.hasKey(dep):
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
  discard solve(graph, form, packages, output, triedVersions, options)
  
  for pkg, ver in packages:
    let nodeIdx = graph.packageToDependency.getKey(pkg)
    for dep in graph.nodes[nodeIdx].versions:
      if dep.version == ver:
        let reqIdx = dep.req
        let deps =  graph.reqs[reqIdx].deps
        let solvedPkg = SolvedPackage(pkgName: pkg, version: ver, 
          requirements: deps, 
          reverseDependencies: collectReverseDependencies(pkg, graph),
        )
        result.add solvedPkg

  # Create lookup table for O(1) package access
  var pkgLookup = initTable[string, SolvedPackage]()
  for pkg in result:
    pkgLookup[pkg.pkgName] = pkg

  # Collect the deps for every solved package
  for solvedPkg in result.mitems:
    for (depName, depVer) in solvedPkg.requirements:
      if pkgLookup.hasKey(depName):
        let otherPkg = pkgLookup[depName]
        if otherPkg.version.withinRange(depVer):
          solvedPkg.deps.add(otherPkg)
  # Collect reverse deps as solved package
  for solvedPkg in result.mitems:
    for (depName, depVer) in solvedPkg.reverseDependencies:
      if pkgLookup.hasKey(depName):
        solvedPkg.reverseDeps.add(pkgLookup[depName])

proc isFileUrl*(pkgDownloadInfo: PackageDownloadInfo): bool =
  pkgDownloadInfo.meth.isNone and pkgDownloadInfo.url.isFileURL

proc getCacheDownloadDir*(url: string, ver: VersionRange, options: Options): string =
  # Don't include version in directory name - we download all versions to same location
  # Create a version-agnostic directory name using only the URL (including query for subdirs)
  let puri = parseUri(url)
  var dirName = ""
  for i in puri.hostname:
    case i
    of strutils.Letters, strutils.Digits:
      dirName.add i
    else: discard
  dirName.add "_"
  for i in puri.path:
    case i
    of strutils.Letters, strutils.Digits:
      dirName.add i
    else: discard
  # Include query string (e.g., ?subdir=generator) to differentiate subdirectories
  if puri.query != "":
    dirName.add "_"
    for i in puri.query:
      case i
      of strutils.Letters, strutils.Digits:
        dirName.add i
      else: discard
  options.pkgCachePath / dirName

proc getPackageDownloadInfo*(pv: PkgTuple, options: Options, doPrompt = false): PackageDownloadInfo =
  if pv.name.isFileURL:
    return PackageDownloadInfo(meth: none(DownloadMethod), url: pv.name, subdir: "", downloadDir: "", pv: pv)
  let (meth, url, metadata) =
      getDownloadInfo(pv, options, doPrompt, ignorePackageCache = false)
  let subdir = metadata.getOrDefault("subdir")
  let downloadDir = getCacheDownloadDir(url, pv.ver, options)
  PackageDownloadInfo(meth: some meth, url: url, subdir: subdir, downloadDir: downloadDir, pv: pv)

proc getPackageFromFileUrl*(fileUrl: string, options: Options, nimBin: string): PackageInfo = 
  let absPath = extractFilePathFromURL(fileUrl)
  getPkgInfoFromDirWithDeclarativeParser(absPath, options, nimBin)

proc downloadFromDownloadInfo*(dlInfo: PackageDownloadInfo, options: Options, nimBin: string): (DownloadPkgResult, Option[DownloadMethod]) = 
  if dlInfo.isFileUrl:
    let pkgInfo = getPackageFromFileUrl(dlInfo.url, options, nimBin)
    let downloadRes = (dir: pkgInfo.getNimbleFileDir(), version: pkgInfo.basicInfo.version, vcsRevision: notSetSha1Hash)
    (downloadRes, none(DownloadMethod))
  else:
    let downloadRes = downloadPkg(dlInfo.url, dlInfo.pv.ver, dlInfo.meth.get, dlInfo.subdir, options,
                  dlInfo.downloadDir, vcsRevision = notSetSha1Hash, nimBin = nimBin)
    (downloadRes, dlInfo.meth)

proc downloadPkgFromUrl*(pv: PkgTuple, options: Options, doPrompt = false, nimBin: string): (DownloadPkgResult, Option[DownloadMethod]) = 
  let dlInfo = getPackageDownloadInfo(pv, options, doPrompt)
  downloadFromDownloadInfo(dlInfo, options, nimBin)
        
proc downloadPkInfoForPv*(pv: PkgTuple, options: Options, doPrompt = false, nimBin: string): PackageInfo  =
  let downloadRes = downloadPkgFromUrl(pv, options, doPrompt, nimBin)
  if options.satResult.pass in {satNimSelection}:
    result = getPkgInfoFromDirWithDeclarativeParser(downloadRes[0].dir, options, nimBin)
  else:
    result = getPkgInfo(downloadRes[0].dir, options, nimBin, forValidation = false, onlyMinimalInfo = false)

proc getAllNimReleases(options: Options): seq[PackageMinimalInfo] =
  let releases = getOfficialReleases(options)  
  for release in releases:
    result.add PackageMinimalInfo(name: "nim", version: release)
  
  if options.nimBin.isSome:
    result.addUnique PackageMinimalInfo(name: "nim", version: options.nimBin.get.version)

proc getCacheFileName(repoDir, pkgName: string, options: Options): string =
  # return options.getNimbleDir / "pkgcache" / "tagged" / "test" & ".json"
  if options.localDeps:
    var pkgName = 
      if pkgName.isUrl:
        pkgName.getDownloadDirName(VersionRange(kind: verAny), notSetSha1Hash)
      else:
        pkgName
    return options.getNimbleDir / "pkgcache" / "tagged" / pkgName & ".json"
  else:
    return repoDir / TaggedVersionsFileName

proc getTaggedVersions*(repoDir, pkgName: string, options: Options): Option[TaggedPackageVersions] =
  let file = getCacheFileName(repoDir, pkgName, options)
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
  let file = getCacheFileName(repoDir, pkgName, options)
  try:
    createDir(file.parentDir)
    file.writeFile((taggedVersions.toJson()).pretty)
  except CatchableError as e:
    displayWarning(&"Error saving tagged versions: {e.msg}", HighPriority)

proc getPackageMinimalVersionsFromRepo*(repoDir: string, pkg: PkgTuple, version: Version, downloadMethod: DownloadMethod, options: Options, nimBin: string): seq[PackageMinimalInfo] =
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
      if options.satResult.pass in {satNimSelection}:
        # TODO test this code path
        result.add getPkgInfoFromDirWithDeclarativeParser(repoDir, options, nimBin).getMinimalInfo(options)   
      else:
        result.add getPkgInfo(repoDir, options, nimBin).getMinimalInfo(options)   
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
          displayInfo(&"Ignoring {name}:{tagVersion} because out of range {pkg[1]}", LowPriority)
          continue

        doCheckout(downloadMethod, tempDir, tag, options)
        let nimbleFile = findNimbleFile(tempDir, true, options, warn = false)
        if options.satResult.pass in {satNimSelection}:
          result.addUnique getPkgInfoFromDirWithDeclarativeParser(tempDir, options, nimBin).getMinimalInfo(options)  
        elif options.useDeclarativeParser:
          result.addUnique getMinimalInfo(nimbleFile, options, nimBin)
        else:
          let pkgInfo = getPkgInfoFromFile(nimBin, nimbleFile, options, useCache=false)
          result.addUnique pkgInfo.getMinimalInfo(options)
        #here we copy the directory to its own folder so we have it cached for future usage
        let downloadInfo = getPackageDownloadInfo((name, tagVersion.toVersionRange()), options)
        if not dirExists(downloadInfo.downloadDir):
          copyDir(tempDir, downloadInfo.downloadDir)

      except CatchableError as e:
        displayWarning(
          &"Error reading tag {tag}: for package {name}. This may not be relevant as it could be an old version of the package. \n {e.msg}",
           HighPriority)
    if not (not options.isLegacy and options.satResult.pass == satNimSelection and options.satResult.declarativeParseFailed):
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

proc getPackageMinimalVersionsFromRepoAsync*(repoDir: string, pkg: PkgTuple, version: Version, downloadMethod: DownloadMethod, options: Options, nimBin: string): Future[seq[PackageMinimalInfo]] {.async.} =
  ## Async version of getPackageMinimalVersionsFromRepo that uses async operations for VCS commands.
  result = newSeq[PackageMinimalInfo]()

  let name = pkg[0]
  try:
    let taggedVersions = getTaggedVersions(repoDir, name, options)
    if taggedVersions.isSome:
      return taggedVersions.get.versions
  except Exception:
    discard # Continue with fetching from repo

  let tempDir = repoDir & "_versions"
  try:
    removeDir(tempDir)
    copyDir(repoDir, tempDir)
    var tags = initOrderedTable[Version, string]()
    try:
      await gitFetchTagsAsync(tempDir, downloadMethod, options)
      tags = (await getTagsListAsync(tempDir, downloadMethod)).getVersionList()
    except CatchableError as e:
      displayWarning(&"Error fetching tags for {name}: {e.msg}", HighPriority)

    try:
      try:
        if options.satResult.pass in {satNimSelection}:
          # TODO test this code path
          result.add getPkgInfoFromDirWithDeclarativeParser(repoDir, options, nimBin).getMinimalInfo(options)
        else:
          result.add getPkgInfo(repoDir, options, nimBin).getMinimalInfo(options)
      except Exception as e:
        raise newException(CatchableError, e.msg)
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

        await doCheckoutAsync(downloadMethod, tempDir, tag, options)
        let nimbleFile = findNimbleFile(tempDir, true, options, warn = false)
        try:
          if options.satResult.pass in {satNimSelection}:
            result.addUnique getPkgInfoFromDirWithDeclarativeParser(tempDir, options, nimBin).getMinimalInfo(options)
          elif options.useDeclarativeParser:
            result.addUnique getMinimalInfo(nimbleFile, options, nimBin)
          else:
            let pkgInfo = getPkgInfoFromFile(nimBin, nimbleFile, options, useCache=false)
            result.addUnique pkgInfo.getMinimalInfo(options)
        except Exception as e:
          raise newException(CatchableError, e.msg)
        #here we copy the directory to its own folder so we have it cached for future usage
        try:
          let downloadInfo = getPackageDownloadInfo((name, tagVersion.toVersionRange()), options)
          if not dirExists(downloadInfo.downloadDir):
            copyDir(tempDir, downloadInfo.downloadDir)
        except Exception as e:
          raise newException(CatchableError, e.msg)

      except CatchableError as e:
        displayWarning(
          &"Error reading tag {tag}: for package {name}. This may not be relevant as it could be an old version of the package. \n {e.msg}",
           HighPriority)
    if not (not options.isLegacy and options.satResult.pass == satNimSelection and options.satResult.declarativeParseFailed):
      #Dont save tagged versions if we are in vNext and the declarative parser failed as this could cache the incorrect versions.
      #its suboptimal in the sense that next packages after failure wont be saved in the first past but there is a guarantee that there is a second pass in the case
      #the declarative parser fails so they will be saved then.
      try:
        saveTaggedVersions(repoDir, name,
                          TaggedPackageVersions(
                            maxTaggedVersions: options.maxTaggedVersions,
                            versions: result
                          ), options)
      except Exception as e:
        displayWarning(&"Error saving tagged versions for {name}: {e.msg}", LowPriority)
  finally:
    try:
      removeDir(tempDir)
    except CatchableError as e:
      displayWarning(&"Error cleaning up temporary directory {tempDir}: {e.msg}", LowPriority)

proc getPackageMinimalVersionsFromRepoAsyncFast*(
    repoDir: string,
    pkg: PkgTuple,
    downloadMethod: DownloadMethod,
    options: Options,
    nimBin: string
): Future[seq[PackageMinimalInfo]] {.async.} =
  ## Fast version that reads nimble files directly from git tags without checkout.
  ## Uses git ls-tree and git show to avoid expensive checkout + copyDir operations.
  result = newSeq[PackageMinimalInfo]()
  let name = pkg[0]

  # Find the git repository root (repoDir might be a subdirectory)
  var gitRoot = repoDir
  var subdirPath = ""

  # Check if we're in a subdirectory by looking for .git
  try:
    if not dirExists(gitRoot / ".git"):
      # Walk up to find the git root
      var currentDir = repoDir
      while not dirExists(currentDir / ".git") and currentDir.parentDir() != currentDir:
        currentDir = currentDir.parentDir()

      if dirExists(currentDir / ".git"):
        gitRoot = currentDir
        # Calculate relative path from git root to repoDir
        subdirPath = repoDir.relativePath(gitRoot).replace("\\", "/")
      # If no .git found, proceed anyway - git commands might still work
  except Exception:
    # If anything fails, just use repoDir as-is
    gitRoot = repoDir

  # Check cache first
  try:
    let taggedVersions = getTaggedVersions(repoDir, name, options)
    if taggedVersions.isSome:
      return taggedVersions.get.versions
  except Exception:
    discard

  # Fetch all tags
  var tags = initOrderedTable[Version, string]()
  try:
    await gitFetchTagsAsync(gitRoot, downloadMethod, options)
    tags = (await getTagsListAsync(gitRoot, downloadMethod)).getVersionList()
  except CatchableError as e:
    displayWarning(&"Error fetching tags for {name}: {e.msg}", HighPriority)
    return

  # Get current HEAD version info (files already on disk)
  try:
    try:
      result.add getPkgInfo(repoDir, options, nimBin).getMinimalInfo(options)
    except Exception as e:
      raise newException(CatchableError, e.msg)
  except CatchableError as e:
    displayWarning(&"Error getting package info for {name}: {e.msg}", HighPriority)

  # Process each tag - read nimble file directly from git
  var checkedTags = 0
  for (ver, tag) in tags.pairs:
    if options.maxTaggedVersions > 0 and checkedTags >= options.maxTaggedVersions:
      break
    inc checkedTags

    try:
      # List nimble files in this tag
      let nimbleFiles = await gitListNimbleFilesInCommitAsync(gitRoot, tag)
      if nimbleFiles.len == 0:
        displayInfo(&"No nimble file found in tag {tag} for {name}", LowPriority)
        continue

      # Filter nimble files to those in the subdirectory (if applicable)
      var relevantNimbleFiles: seq[string] = @[]
      if subdirPath != "":
        for nf in nimbleFiles:
          if nf.startsWith(subdirPath & "/") or nf.startsWith(subdirPath):
            relevantNimbleFiles.add(nf)
      else:
        relevantNimbleFiles = nimbleFiles

      if relevantNimbleFiles.len == 0:
        displayInfo(&"No nimble file found in tag {tag} (subdir: {subdirPath}) for {name}", LowPriority)
        continue

      # Prefer nimble file matching package name
      var nimbleFilePath = relevantNimbleFiles[0]
      let expectedName = name & ".nimble"
      for nf in relevantNimbleFiles:
        if nf.endsWith(expectedName) or nf == expectedName:
          nimbleFilePath = nf
          break

      # Read nimble file content from git
      let nimbleContent = await gitShowFileAsync(gitRoot, tag, nimbleFilePath)

      # Write to temp file for parsing
      let tempNimbleFile = getTempDir() / &"{name}_{tag}.nimble"
      try:
        writeFile(tempNimbleFile, nimbleContent)
        try:
          let pkgInfo = getPkgInfoFromFile(nimBin, tempNimbleFile, options, useCache=false)
          result.addUnique(pkgInfo.getMinimalInfo(options))
        except Exception as e:
          raise newException(CatchableError, e.msg)
      finally:
        try:
          removeFile(tempNimbleFile)
        except: discard

    except CatchableError as e:
      displayInfo(&"Error reading tag {tag} for {name}: {e.msg}", LowPriority)

  # Save to cache
  try:
    saveTaggedVersions(repoDir, name,
                      TaggedPackageVersions(
                        maxTaggedVersions: options.maxTaggedVersions,
                        versions: result
                      ), options)
  except Exception as e:
    displayWarning(&"Error saving tagged versions for {name}: {e.msg}", LowPriority)

proc downloadMinimalPackage*(pv: PkgTuple, options: Options, nimBin: string): seq[PackageMinimalInfo] =
  if pv.name == "": return newSeq[PackageMinimalInfo]()
  if pv.isNim and not options.disableNimBinaries: return getAllNimReleases(options)
  if pv.name.isFileURL:
    result = @[getPackageFromFileUrl(pv.name, options, nimBin).getMinimalInfo(options)]
    return
  if pv.ver.kind in [verSpecial, verEq]: #if special or equal, we dont retrieve more versions as we only need one.
    result = @[downloadPkInfoForPv(pv, options, false, nimBin).getMinimalInfo(options)]
  else:
    let (downloadRes, downloadMeth) = downloadPkgFromUrl(pv, options, false, nimBin)
    result = getPackageMinimalVersionsFromRepo(downloadRes.dir, pv, downloadRes.version, downloadMeth.get, options, nimBin)
  #Make sure the url is set for the package
  if pv.name.isUrl:
    for r in result.mitems:
      if r.url == "":
        r.url = pv.name

proc downloadFromDownloadInfoAsync*(dlInfo: PackageDownloadInfo, options: Options, nimBin: string): Future[(DownloadPkgResult, Option[DownloadMethod])] {.async.} =
  ## Async version of downloadFromDownloadInfo that uses async download operations.
  if dlInfo.isFileUrl:
    try:
      let pkgInfo = getPackageFromFileUrl(dlInfo.url, options, nimBin)
      let downloadRes = (dir: pkgInfo.getNimbleFileDir(), version: pkgInfo.basicInfo.version, vcsRevision: notSetSha1Hash)
      return (downloadRes, none(DownloadMethod))
    except Exception as e:
      raise newException(CatchableError, e.msg)
  else:
    let downloadRes = await downloadPkgAsync(dlInfo.url, dlInfo.pv.ver, dlInfo.meth.get, dlInfo.subdir, options,
                  dlInfo.downloadDir, vcsRevision = notSetSha1Hash, nimBin = nimBin)
    return (downloadRes, dlInfo.meth)

proc downloadPkgFromUrlAsync*(pv: PkgTuple, options: Options, doPrompt = false, nimBin: string): Future[(DownloadPkgResult, Option[DownloadMethod])] {.async.} =
  ## Async version of downloadPkgFromUrl that downloads from a package URL.
  try:
    let dlInfo = getPackageDownloadInfo(pv, options, doPrompt)
    return await downloadFromDownloadInfoAsync(dlInfo, options, nimBin)
  except Exception as e:
    raise newException(CatchableError, e.msg)

proc downloadPkInfoForPvAsync*(pv: PkgTuple, options: Options, doPrompt = false, nimBin: string): Future[PackageInfo] {.async.} =
  ## Async version of downloadPkInfoForPv that downloads and gets package info.
  let downloadRes = await downloadPkgFromUrlAsync(pv, options, doPrompt, nimBin)
  try:
    if options.satResult.pass in {satNimSelection}:
      return getPkgInfoFromDirWithDeclarativeParser(downloadRes[0].dir, options, nimBin)
    else:
      return getPkgInfo(downloadRes[0].dir, options, nimBin, forValidation = false, onlyMinimalInfo = false)
  except Exception as e:
    raise newException(CatchableError, e.msg)

var downloadCache {.threadvar.}: Table[string, Future[seq[PackageMinimalInfo]]]

proc downloadMinimalPackageAsyncImpl(pv: PkgTuple, options: Options, nimBin: string): Future[seq[PackageMinimalInfo]] {.async.} =
  ## Internal implementation of async download without caching.
  if pv.name == "": return newSeq[PackageMinimalInfo]()
  try:
    if pv.isNim and not options.disableNimBinaries:
      return getAllNimReleases(options)
  except Exception as e:
    raise newException(CatchableError, e.msg)

  if pv.name.isFileURL:
    try:
      result = @[getPackageFromFileUrl(pv.name, options, nimBin).getMinimalInfo(options)]
      return
    except Exception as e:
      raise newException(CatchableError, e.msg)

  if pv.ver.kind in [verSpecial, verEq]: #if special or equal, we dont retrieve more versions as we only need one.
    let pkgInfo = await downloadPkInfoForPvAsync(pv, options, false, nimBin)
    try:
      result = @[pkgInfo.getMinimalInfo(options)]
    except Exception as e:
      raise newException(CatchableError, e.msg)
  else:
    try:
      let (downloadRes, downloadMeth) = await downloadPkgFromUrlAsync(pv, options, false, nimBin)
      result = await getPackageMinimalVersionsFromRepoAsyncFast(downloadRes.dir, pv, downloadMeth.get, options, nimBin)
    except Exception as e:
      raise newException(CatchableError, e.msg)

  #Make sure the url is set for the package
  try:
    if pv.name.isUrl:
      for r in result.mitems:
        # Always set URL for URL-based packages to ensure subdirectories have correct URL
        r.url = pv.name
  except Exception as e:
    raise newException(CatchableError, e.msg)

proc downloadMinimalPackageAsync*(pv: PkgTuple, options: Options, nimBin: string): Future[seq[PackageMinimalInfo]] {.async.} =
  ## Async version of downloadMinimalPackage with deduplication.
  ## If multiple calls request the same package concurrently, they share the same download.
  ## Cache key uses canonical package URL (not version) since we download all versions anyway.

  # Get canonical URL to use as cache key (handles both short names and full URLs)
  var cacheKey: string
  try:
    if pv.name.isFileURL or pv.name == "" or (pv.isNim and not options.disableNimBinaries):
      # For special cases, use the name as-is
      cacheKey = pv.name
    elif pv.name.isUrl:
      # For direct URLs (including subdirectories), use the URL as-is
      # Don't normalize because subdirectories must be treated as separate packages
      cacheKey = pv.name
    else:
      # For package names, resolve to canonical URL for proper deduplication
      try:
        let dlInfo = getPackageDownloadInfo(pv, options, doPrompt = false)
        cacheKey = dlInfo.url
      except:
        # If resolution fails, fall back to using name
        cacheKey = pv.name
  except Exception as e:
    # If any check fails, use name as-is
    cacheKey = pv.name

  # Check if download is already in progress
  if downloadCache.hasKey(cacheKey):
    # Wait for the existing download to complete and reuse all versions
    return await downloadCache[cacheKey]

  # Start new download and cache the future
  let downloadFuture = downloadMinimalPackageAsyncImpl(pv, options, nimBin)
  downloadCache[cacheKey] = downloadFuture

  try:
    result = await downloadFuture
  finally:
    # Remove from cache after completion (success or failure)
    downloadCache.del(cacheKey)

proc fillPackageTableFromPreferred*(packages: var Table[string, PackageVersions], preferredPackages: seq[PackageMinimalInfo]) =
  for pkg in preferredPackages:
    if not hasVersion(packages, pkg.name, pkg.version):
      if not packages.hasKey(pkg.name):
        packages[pkg.name] = PackageVersions(pkgName: pkg.name, versions: @[pkg])
      else:
        packages[pkg.name].versions.add pkg

proc getInstalledMinimalPackages*(options: Options): seq[PackageMinimalInfo] =
  getInstalledPkgsMin(options.getPkgsDir(), options).mapIt(it.getMinimalInfo(options))

proc getMinimalFromPreferred(pv: PkgTuple,  getMinimalPackage: GetPackageMinimal, preferredPackages: seq[PackageMinimalInfo], options: Options, nimBin: string): seq[PackageMinimalInfo] =
  for pp in preferredPackages:
    if (pp.name == pv.name or pp.url == pv.name) and pp.version.withinRange(pv.ver):
      return @[pp]
  getMinimalPackage(pv, options, nimBin)

proc getMinimalFromPreferredAsync*(pv: PkgTuple, getMinimalPackage: GetPackageMinimalAsync, preferredPackages: seq[PackageMinimalInfo], options: Options, nimBin: string): Future[seq[PackageMinimalInfo]] {.async.} =
  ## Async version of getMinimalFromPreferred that uses async package fetching.
  for pp in preferredPackages:
    if (pp.name == pv.name or pp.url == pv.name) and pp.version.withinRange(pv.ver):
      return @[pp]
  try:
    return await getMinimalPackage(pv, options, nimBin)
  except Exception as e:
    raise newException(CatchableError, e.msg)

proc hasSpecialVersion(versions: Table[string, PackageVersions], pkgName: string): bool =
  if pkgName in versions:
    for pkg in versions[pkgName].versions:
      if pkg.version.isSpecial:
        return true
  return false

proc processRequirements(versions: var Table[string, PackageVersions], pv: PkgTuple, visited: var HashSet[PkgTuple], getMinimalPackage: GetPackageMinimal, preferredPackages: seq[PackageMinimalInfo] = newSeq[PackageMinimalInfo](), options: Options, nimBin: string) =
  if pv in visited:
    return
  
  visited.incl pv
  
  # For special versions, always process them even if we think we have the package
  # This ensures the special version gets downloaded and added to the version table
  try:
    if pv.ver.kind == verSpecial or not hasVersion(versions, pv):    
      var pkgMins = getMinimalFromPreferred(pv, getMinimalPackage, preferredPackages, options, nimBin)
      
      # First, validate all requirements for all package versions before adding anything
      var validPkgMins: seq[PackageMinimalInfo] = @[]
      for pkgMin in pkgMins:
        var allRequirementsValid = true
        # Test if all requirements can be processed without errors
        for req in pkgMin.requires:
          try:
            # Try to get minimal package info for the requirement to validate it exists
            discard getMinimalFromPreferred(req, getMinimalPackage, preferredPackages, options, nimBin)
          except CatchableError:
            allRequirementsValid = false
            displayWarning(&"Skipping package {pkgMin.name}@{pkgMin.version} due to invalid dependency: {req.name}", HighPriority)
            break
        
        if allRequirementsValid:
          validPkgMins.add pkgMin
      
      # Only add packages with valid requirements to the versions table
      for pkgMin in validPkgMins.mitems:
        let pkgName = pkgMin.name.toLower
        if pv.ver.kind == verSpecial:
          # Keep both the commit hash and the actual semantic version
          var specialVer = newVersion($pv.ver)
          specialVer.speSemanticVersion = some($pkgMin.version)  # Store the real version
          pkgMin.version = specialVer
          
          # If this is a special version, clear any existing regular versions
          # to force the SAT solver to use this specific version
          if versions.hasKey(pkgName):
            versions[pkgName].versions = @[pkgMin]
          else:
            versions[pkgName] = PackageVersions(pkgName: pkgName, versions: @[pkgMin])
        else:
          # Don't add regular versions if a special version already exists
          if hasSpecialVersion(versions, pkgName):
            continue
            
          if not versions.hasKey(pkgName):
            versions[pkgName] = PackageVersions(pkgName: pkgName, versions: @[pkgMin])
          else:
            versions[pkgName].versions.addUnique pkgMin
        
        # Now recursively process the requirements (we know they're valid)
        for req in pkgMin.requires:
          processRequirements(versions, req, visited, getMinimalPackage, preferredPackages, options, nimBin)
      
      # Only add URL packages if we have valid versions
      if pv.name.isUrl and validPkgMins.len > 0:
        versions[pv.name] = PackageVersions(pkgName: pv.name, versions: validPkgMins)
        
  except CatchableError as e:
    # Some old packages may have invalid requirements (i.e repos that doesn't exist anymore)
    # we need to avoid adding it to the package table as this will cause the solver to fail
    displayWarning(&"Error processing requirements for {pv.name}: {e.msg}", HighPriority)

proc processRequirementsAsync(pv: PkgTuple, visitedParam: HashSet[PkgTuple], getMinimalPackage: GetPackageMinimalAsync, preferredPackages: seq[PackageMinimalInfo] = newSeq[PackageMinimalInfo](), options: Options, nimBin: string): Future[Table[string, PackageVersions]] {.async.} =
  ## Async version of processRequirements that returns computed versions instead of mutating shared state.
  ## This allows for safe parallel execution since there's no shared mutable state.
  ## Takes visited by value since we pass separate copies to each top-level dependency branch.
  ## Processes all nested dependencies in parallel for maximum performance.
  result = initTable[string, PackageVersions]()

  # Make a local mutable copy
  var visited = visitedParam

  if pv in visited:
    return

  visited.incl pv

  # For special versions, always process them even if we think we have the package
  # This ensures the special version gets downloaded and added to the version table
  try:
    var pkgMins = await getMinimalFromPreferredAsync(pv, getMinimalPackage, preferredPackages, options, nimBin)

    # First, validate all requirements for all package versions before adding anything
    var validPkgMins: seq[PackageMinimalInfo] = @[]
    for pkgMin in pkgMins:
      var allRequirementsValid = true
      # Test if all requirements can be processed without errors
      for req in pkgMin.requires:
        try:
          # Try to get minimal package info for the requirement to validate it exists
          discard await getMinimalFromPreferredAsync(req, getMinimalPackage, preferredPackages, options, nimBin)
        except CatchableError:
          allRequirementsValid = false
          displayWarning(&"Skipping package {pkgMin.name}@{pkgMin.version} due to invalid dependency: {req.name}", HighPriority)
          break

      if allRequirementsValid:
        validPkgMins.add pkgMin

    # Only add packages with valid requirements to the result table
    for pkgMin in validPkgMins.mitems:
      let pkgName = pkgMin.name.toLower
      if pv.ver.kind == verSpecial:
        # Keep both the commit hash and the actual semantic version
        var specialVer = newVersion($pv.ver)
        specialVer.speSemanticVersion = some($pkgMin.version)  # Store the real version
        pkgMin.version = specialVer

        # Special versions replace any existing versions
        result[pkgName] = PackageVersions(pkgName: pkgName, versions: @[pkgMin])
      else:
        # Add to result table
        if not result.hasKey(pkgName):
          result[pkgName] = PackageVersions(pkgName: pkgName, versions: @[pkgMin])
        else:
          result[pkgName].versions.addUnique pkgMin

      # Process all requirements in parallel (full parallelization)
      # Each branch gets its own copy of visited to avoid shared state issues
      var reqFutures: seq[Future[Table[string, PackageVersions]]] = @[]
      for req in pkgMin.requires:
        reqFutures.add processRequirementsAsync(req, visited, getMinimalPackage, preferredPackages, options, nimBin)

      # Wait for all requirement processing to complete
      if reqFutures.len > 0:
        await allFutures(reqFutures)

        # Merge all requirement results
        for reqFut in reqFutures:
          let reqResult = reqFut.read()
          for pkgName, pkgVersions in reqResult:
            if not result.hasKey(pkgName):
              result[pkgName] = pkgVersions
            else:
              for ver in pkgVersions.versions:
                result[pkgName].versions.addUnique ver

    # Only add URL packages if we have valid versions
    try:
      if pv.name.isUrl and validPkgMins.len > 0:
        result[pv.name] = PackageVersions(pkgName: pv.name, versions: validPkgMins)
    except Exception as e:
      raise newException(CatchableError, e.msg)

  except CatchableError as e:
    # Some old packages may have invalid requirements (i.e repos that doesn't exist anymore)
    # we need to avoid adding it to the package table as this will cause the solver to fail
    displayWarning(&"Error processing requirements for {pv.name}: {e.msg}", HighPriority)

proc collectAllVersions*(versions: var Table[string, PackageVersions], package: PackageMinimalInfo, options: Options, getMinimalPackage: GetPackageMinimal, preferredPackages: seq[PackageMinimalInfo] = newSeq[PackageMinimalInfo](), nimBin: string) {.instrument.} =
  var visited = initHashSet[PkgTuple]()
  for pv in package.requires:
    processRequirements(versions, pv, visited, getMinimalPackage, preferredPackages, options, nimBin)

proc mergeVersionTables(dest: var Table[string, PackageVersions], source: Table[string, PackageVersions]) =
  ## Helper proc to merge version tables. Synchronous to avoid closure capture issues.
  for pkgName, pkgVersions in source:
    if not dest.hasKey(pkgName):
      dest[pkgName] = pkgVersions
    else:
      # Merge versions, handling special versions
      var hasSpecial = false
      for ver in pkgVersions.versions:
        if ver.version.isSpecial:
          hasSpecial = true
          # Special version replaces all
          dest[pkgName] = PackageVersions(pkgName: pkgName, versions: @[ver])
          break

      if not hasSpecial:
        # Check if existing has special version
        var existingHasSpecial = false
        for ver in dest[pkgName].versions:
          if ver.version.isSpecial:
            existingHasSpecial = true
            break

        # Only add if existing doesn't have special version
        if not existingHasSpecial:
          for ver in pkgVersions.versions:
            dest[pkgName].versions.addUnique ver

proc collectAllVersionsAsync*(package: PackageMinimalInfo, options: Options, getMinimalPackage: GetPackageMinimalAsync, preferredPackages: seq[PackageMinimalInfo] = newSeq[PackageMinimalInfo](), nimBin: string): Future[Table[string, PackageVersions]] {.async.} =
  ## Async version of collectAllVersions that processes top-level dependencies in parallel.
  ## Uses return-based approach: each branch returns its computed versions, then we merge them.
  ## This allows for safe parallel execution with no shared mutable state during processing.
  ## Returns the merged version table instead of mutating a parameter.

  # Process all top-level requirements in parallel
  # Each gets its own visited set to avoid race conditions
  var futures: seq[Future[Table[string, PackageVersions]]] = @[]
  for pv in package.requires:
    var visitedCopy = initHashSet[PkgTuple]()
    futures.add processRequirementsAsync(pv, visitedCopy, getMinimalPackage, preferredPackages, options, nimBin)

  # Wait for all to complete
  await allFutures(futures)

  # Merge all results into a new table
  result = initTable[string, PackageVersions]()
  for fut in futures:
    let resultTable = fut.read()
    mergeVersionTables(result, resultTable)

proc topologicalSort*(solvedPkgs: seq[SolvedPackage]): seq[SolvedPackage] {.instrument.}  =
  var inDegree = initTable[string, int]()
  var adjList = initTable[string, seq[string]]()
  var zeroInDegree: seq[string] = @[]
  # Create a lookup table for O(1) package access
  var pkgLookup = initTable[string, SolvedPackage]()

  # Initialize in-degree and adjacency list using requirements
  for pkg in solvedPkgs:
    pkgLookup[pkg.pkgName] = pkg
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
    let currentPkg = pkgLookup[current]
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
  solvedPkgs = pkgVersionTable.getSolvedPackages(output, options)
  systemNimCompatible = solvedPkgs.isSystemNimCompatible(options)
  
  for solvedPkg in solvedPkgs:
    if solvedPkg.pkgName.isNim and systemNimCompatible:     
      continue #Dont add nim from the solution as we will use system nim
    for pkgInfo in pkgList:
      if (pkgInfo.basicInfo.name == solvedPkg.pkgName or pkgInfo.metadata.url == solvedPkg.pkgName) and 
        (pkgInfo.basicInfo.version == solvedPkg.version or solvedPkg.version in pkgInfo.metadata.specialVersions):
          result.incl pkgInfo

proc areAllReqAny(dep: SolvedPackage): bool =
  #Checks where all the requirements by other packages in the solution are any
  #This allows for using a special version to meet the requirement of the solution
  #Scenario will be, int he package list there is only a special version but all requirements
  #are any. So it wont need to download a regular version but just use the special version.
  for rev in dep.reverseDeps:
    for req in rev.requirements:
      if dep.pkgName == req.name:
        if req.ver.kind != verAny:
          return false
  true

proc getPackageNameFromUrl*(pv: PkgTuple, pkgVersionTable: Table[string, PackageVersions], options: Options): string =
  var candidates: seq[string] = @[]
  for pkgName, pkgVersions in pkgVersionTable:
    for pkgVersion in pkgVersions.versions:
      if pkgVersion.url == pv.name:
        candidates.add(pkgName)
  
  # Prefer package names that are not URLs
  for candidate in candidates:
    if not candidate.isUrl:
      return candidate
  
  # If no non-URL candidate, return the first one
  if candidates.len > 0:
    return candidates[0]

proc getUrlFromPkgName*(pkgName: string, pkgVersionTable: Table[string, PackageVersions], options: Options): string =
  for pkgTableName, pkgVersions in pkgVersionTable:
    for pkgVersion in pkgVersions.versions:
      if pkgVersion.name.toLower == pkgName.toLower:
        return pkgVersion.url
  return ""
  
proc normalizeRequirements*(pkgVersionTable: var Table[string, PackageVersions], options: Options) {.instrument.} =
  for pkgName, pkgVersions in pkgVersionTable.mpairs:
    for pkgVersion in pkgVersions.versions.mitems:
      for req in pkgVersion.requires.mitems:
        if req.name.isUrl:          
          # echo "*** FOUND URL REQUIREMENT: ", req.name, " for package ", pkgName, " version ", $req.ver
          let newPkgName = getPackageNameFromUrl(req, pkgVersionTable, options)
          if newPkgName != "":
            let oldReq = req.name
            # echo "DEBUG: Normalizing requirement ", req.name, " to ", newPkgName, " for package ", pkgName, " version ", $req.ver
            req.name = newPkgName
            options.satResult.normalizedRequirements[newPkgName] = oldReq
        req.name = req.name.resolveAlias(options)

proc postProcessSolvedPkgs*(solvedPkgs: var seq[SolvedPackage], options: Options, nimBin: string) {.instrument.} =
  #Prioritizes fileUrl packages over the regular packages defined in the requirements
  var fileUrlPkgs: seq[PackageInfo] = @[]
  for solved in solvedPkgs:
    if solved.pkgName.isFileURL:
      let pkg = getPackageFromFileUrl(solved.pkgName, options, nimBin)
      fileUrlPkgs.add pkg
  var toReplace: seq[SolvedPackage] = @[]
  for solved in solvedPkgs:
    for fileUrlPkg in fileUrlPkgs:
      if solved.pkgName == fileUrlPkg.basicInfo.name:
        toReplace.add solved
        break
  solvedPkgs = solvedPkgs.filterIt(it notin toReplace)

proc solvePackages*(rootPkg: PackageInfo, pkgList: seq[PackageInfo], pkgsToInstall: var seq[(string, Version)], options: Options, output: var string, solvedPkgs: var seq[SolvedPackage], nimBin: string): HashSet[PackageInfo] {.instrument.} =
  var root: PackageMinimalInfo = rootPkg.getMinimalInfo(options)
  root.isRoot = true
  var pkgVersionTable: Table[system.string, packageinfotypes.PackageVersions]
  if options.isLegacy:
    pkgVersionTable = initTable[string, PackageVersions]()
    pkgVersionTable[root.name] = PackageVersions(pkgName: root.name, versions: @[root])
    collectAllVersions(pkgVersionTable, root, options, downloadMinimalPackage, pkgList.mapIt(it.getMinimalInfo(options)), nimBin)
  else:
    pkgVersionTable = waitFor collectAllVersionsAsync(root, options, downloadMinimalPackageAsync, pkgList.mapIt(it.getMinimalInfo(options)), nimBin)
    pkgVersionTable[root.name] = PackageVersions(pkgName: root.name, versions: @[root])

  # if not options.isLegacy:
  pkgVersionTable.normalizeRequirements(options)  
  options.satResult.pkgVersionTable = pkgVersionTable
  solvedPkgs = pkgVersionTable.getSolvedPackages(output, options).topologicalSort()
  # echo "DEBUG: SolvedPkgs before post processing: ", solvedPkgs.mapIt(it.pkgName & " " & $it.version).join(", ")
  solvedPkgs.postProcessSolvedPkgs(options, nimBin)
  
  let systemNimCompatible = solvedPkgs.isSystemNimCompatible(options)
  # echo "DEBUG: SolvedPkgs after post processing: ", solvedPkgs.mapIt(it.pkgName & " " & $it.version).join(", ")
  # echo "ACTION IS ", options.action.typ
  for solvedPkg in solvedPkgs:
    if solvedPkg.pkgName == root.name: continue    
    var foundInList = false
    let canUseAny = solvedPkg.areAllReqAny()
    for pkgInfo in pkgList:
      let specialVersions = if pkgInfo.metadata.specialVersions.len > 1: pkgInfo.metadata.specialVersions.toSeq()[1..^1] else: @[]
      let isSpecial = specialVersions.len > 0
      if (cmpIgnoreCase(pkgInfo.basicInfo.name, solvedPkg.pkgName) == 0 or cmpIgnoreCase(pkgInfo.metadata.url, solvedPkg.pkgName) == 0) and 
        (pkgInfo.basicInfo.version == solvedPkg.version and (not isSpecial or canUseAny) or solvedPkg.version in specialVersions) and
        #only add one (we could fall into adding two if there are multiple special versiosn in the package list and we can add any). 
        #But we still allow it on upgrade as they are post proccessed in a later stage
          ((not options.isLegacy and options.action.typ in {actionLock}) or #For lock in vnext the result is cleaned in the lock proc that handles the pass
            (result.toSeq.filterIt(cmpIgnoreCase(it.basicInfo.name, solvedPkg.pkgName) == 0 or 
            cmpIgnoreCase(it.metadata.url, solvedPkg.pkgName) == 0).len == 0 or 
            options.action.typ in {actionUpgrade})): 
          result.incl pkgInfo
          foundInList = true
    if not foundInList:
      # displayInfo(&"Coudlnt find {solvedPkg.pkgName}", priority = HighPriority)
      if solvedPkg.pkgName.isNim and systemNimCompatible:
        continue #Skips systemNim
      pkgsToInstall.addUnique((solvedPkg.pkgName, solvedPkg.version))
      
    # echo "Packages in result: ", result.mapIt(it.basicInfo.name & " " & $it.basicInfo.version & " " & $it.metaData.vcsRevision).join(", ")


proc getPackageInfo*(name: string, pkgs: seq[PackageInfo], version: Option[Version] = none(Version)): Option[PackageInfo] =
    for pkg in pkgs:
      if cmpIgnoreCase(pkg.basicInfo.name, name) == 0 or cmpIgnoreCase(pkg.metadata.url, name) == 0:
        if version.isSome:
          if pkg.basicInfo.version == version.get:
            return some pkg
        else: #No version passed over first match
          return some pkg

proc getPkgVersionTable*(pkgInfo: PackageInfo, pkgList: seq[PackageInfo], options: Options, nimBin: string): Table[string, PackageVersions] =
  result = initTable[string, PackageVersions]()
  var root = pkgInfo.getMinimalInfo(options)
  root.isRoot = true
  result[root.name] = PackageVersions(pkgName: root.name, versions: @[root])
  # Use async version for parallel downloading
  let asyncVersions = waitFor collectAllVersionsAsync(root, options, downloadMinimalPackageAsync, pkgList.mapIt(it.getMinimalInfo(options)), nimBin)
  # Merge async results into the result table
  for pkgName, pkgVersions in asyncVersions:
    if not result.hasKey(pkgName):
      result[pkgName] = pkgVersions
    else:
      for ver in pkgVersions.versions:
        result[pkgName].versions.addUnique ver


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

proc dumpSolvedPackages*(pkgInfo: PackageInfo, pkgList: seq[PackageInfo], options: Options, nimBin: string) =
  var pkgToInstall: seq[(string, Version)] = @[]
  var output = ""
  var solvedPkgs: seq[SolvedPackage] = @[]
  discard solvePackages(pkgInfo, pkgList, pkgToInstall, options, output, solvedPkgs, nimBin)

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

proc dumpPackageVersionTable*(pkg: PackageInfo, pkgList: seq[PackageInfo], options: Options, nimBin: string) =
  let pkgVersionTable = getPkgVersionTable(pkg, pkgList, options, nimBin)

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