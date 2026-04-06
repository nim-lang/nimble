import sat/[sat, satvars]
import version, packageinfotypes, packageinfo, options, tools, cli, common, urls
import versiondiscovery

import compat/[sequtils]
import std/[tables, algorithm, sets, strutils, options, strformat]
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

    
  VersionAttempt = tuple[pkgName: string, version: Version]

# var urlToName: Table[string, string] = initTable[string, string]()

proc dumpPackageVersionTable*(pkg: PackageInfo, pkgVersionTable: Table[string, PackageVersions], options: Options, nimBin: string)


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
  ## Compare dependency versions in ascending order (oldest first).
  ## This ensures the SAT solver prefers newer versions because it tries
  ## to set variables to FALSE first - by assigning variables to older
  ## versions first (lower indices), the solver will try to set them false,
  ## leaving newer versions (higher indices) more likely to be selected.
  ##
  ## Special versions (#head, #branch, etc.) are always placed FIRST (as if they
  ## were the "oldest"), so the SAT solver will try to set them FALSE first,
  ## preferring tagged/regular versions over special versions.
  let aIsSpecial = a.version.isSpecial
  let bIsSpecial = b.version.isSpecial

  # Special versions come first (treated as oldest) so SAT solver prefers regular versions
  if aIsSpecial and not bIsSpecial:
    return -1  # a (special) comes before b (regular)
  elif bIsSpecial and not aIsSpecial:
    return 1   # b (special) comes before a (regular), so a comes after

  # Both special or both regular: use normal version comparison
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
    # Assign variables to all versions first (in ascending order, so older = lower VarId)
    for ver in mitems p.versions:
      ver.v = VarId(result.idgen)
      result.mapping[ver.v] = SatVarInfo(pkg: p.pkgName, version: ver.version, index: result.idgen)
      inc result.idgen
    
    # Add constraint with versions in ascending order (oldest first)
    # SAT solver's freeVariable picks the first variable it sees, then tries FALSE first.
    # By putting older versions first, the solver tries to set them FALSE, preferring newer versions.
    if p.isRoot:
      b.openOpr(ExactlyOneOfForm)
      for i in countup(0, p.versions.high):
        b.add(p.versions[i].v)
      b.closeOpr()
    else:
      b.openOpr(ZeroOrOneOfForm)
      for i in countup(0, p.versions.high):
        b.add(p.versions[i].v)
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
          if depVer.version.satisfiesConstraint(q):
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
        if depIdx < 0:
          continue
        let depNode = g.nodes[depIdx]

        # Collect compatible versions (node is sorted oldest first)
        var compatibleVersions: seq[VarId] = @[]
        for depVer in depNode.versions:
          if depVer.version.satisfiesConstraint(q):
            compatibleVersions.add(depVer.v)

        if compatibleVersions.len == 0:
          continue

        # Add implication: if this version is selected, one of its compatible deps must be selected
        # Add oldest versions first in the OR clause so solver tries to set them FALSE
        b.openOpr(OrForm)
        b.addNegated(ver.v)  # not A
        b.openOpr(OrForm)    # or (B_oldest or B_... or B_newest)
        for i in countup(0, compatibleVersions.high):
          b.add(compatibleVersions[i])
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

proc getReachablePackages(graph: DepGraph): HashSet[string] =
  ## BFS traversal to find all packages reachable from root.
  ## Returns package names that are required by the root's dependency tree.
  ## Names are stored lowercase for case-insensitive comparison.
  result = initHashSet[string]()  # Lowercase names
  var queue: seq[string] = @[]

  var graphPackages = initTable[string, string]()  # lowercase -> original
  for key in graph.packageToDependency.keys:
    graphPackages[key.toLowerAscii] = key

  let rootNode = graph.nodes[0]
  result.incl(rootNode.pkgName.toLowerAscii)
  for ver in rootNode.versions:
    for dep, q in items graph.reqs[ver.req].deps:
      let depLower = dep.toLowerAscii
      if depLower notin result:
        result.incl(depLower)
        if depLower in graphPackages:
          queue.add(graphPackages[depLower])  # Use graph's version of the name

  while queue.len > 0:
    let current = queue.pop()
    let idx = graph.packageToDependency[current]
    for ver in graph.nodes[idx].versions:
      for dep, q in items graph.reqs[ver.req].deps:
        let depLower = dep.toLowerAscii
        if depLower notin result:
          result.incl(depLower)
          if depLower in graphPackages:
            queue.add(graphPackages[depLower])  # Use graph's version of the name

proc getSolvedPackages*(pkgVersionTable: Table[string, PackageVersions], output: var string, options: Options): seq[SolvedPackage] {.instrument.} =
  var graph = pkgVersionTable.toDepGraph()

  # Only validate packages reachable from root, not ALL packages in the table.
  # Pre-loaded cached packages may have deps not relevant to this resolution;
  # those will be handled by toFormular (marked as unsatisfiable).

  var lowerCasePackages = initHashSet[string]()
  for key in graph.packageToDependency.keys:
    lowerCasePackages.incl(key.toLowerAscii)

  let reachable = getReachablePackages(graph)
  for pkgName in reachable:
    if pkgName.toLowerAscii notin lowerCasePackages:
      output.add &"Dependency {pkgName} not found in the graph \n"
      for k, v in pkgVersionTable:
        output.add &"Package {k} \n"
        for v in v.versions:
          output.add &"\t \t Version {v.version} requires: {v.requires} \n"
      if options.satResult.gitErrors.len > 0:
        output.add "The following errors occurred during package discovery (could be network issues):\n"
        for err in options.satResult.gitErrors:
          output.add &"  - {err}\n"
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

proc topologicalSort*(solvedPkgs: seq[SolvedPackage]): seq[SolvedPackage] {.instrument.}  =
  var inDegree = initTable[string, int]()
  var adjList = initTable[string, seq[string]]()
  var zeroInDegree: seq[string] = @[]
  # Create a lookup table for O(1) package access
  var pkgLookup = initTable[string, SolvedPackage]()

  # Initialize in-degree and adjacency list using requirements
  for pkg in solvedPkgs:
    let pkgNameLower = pkg.pkgName.toLowerAscii
    pkgLookup[pkgNameLower] = pkg
    if not inDegree.hasKey(pkgNameLower):
      inDegree[pkgNameLower] = 0  # Ensure every package is in the inDegree table
    for dep in pkg.requirements:
      let depNameLower = dep.name.toLowerAscii
      if depNameLower notin adjList:
        adjList[depNameLower] = @[pkgNameLower]
      else:
        adjList[depNameLower].add(pkgNameLower)
      inDegree[pkgNameLower].inc  # Increase in-degree of this pkg since it depends on dep

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

proc isSystemNimCompatible*(solvedPkgs: seq[SolvedPackage], options: Options, nimVersion: Option[Version]): bool =
  if options.action.typ in {actionLock, actionDeps} or options.hasNimInLockFile():
    return false
  for solvedPkg in solvedPkgs:
    for req in solvedPkg.requirements:
      if req.isNim and nimVersion.isSome and not nimVersion.get.withinRange(req.ver):
        return false
  true

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
          let newPkgName = getPackageNameFromUrl(req, pkgVersionTable, options)
          if newPkgName != "":
            let oldReq = req.name
            req.name = newPkgName
            options.satResult.normalizedRequirements[newPkgName] = oldReq
        req.name = req.name.resolveAlias(options)

proc normalizeSpecialVersions*(pkgVersionTable: var Table[string, PackageVersions], options: Options) {.instrument.} =
  ## First-#-wins: when multiple special versions exist for the same package
  ## (e.g. asynctools#commit_a from jester, asynctools#commit_b from httpbeast),
  ## keep only the first one encountered (topologically closest to root, since
  ## processRequirements traverses depth-first from root). Rewrite all other
  ## special requirements for that package to use the winner.
  var winners = initTable[string, Version]()  # pkgName -> winning special version

  # Phase 1: find packages with multiple special versions, pick the first one
  for pkgName, pkgVersions in pkgVersionTable.mpairs:
    if pkgName.isNim:
      continue
    var specialVersions: seq[Version] = @[]
    for v in pkgVersions.versions:
      if v.version.isSpecial:
        specialVersions.add v.version
    if specialVersions.len > 1:
      let winner = specialVersions[0]  # first = topologically first (DFS order)
      let others = specialVersions[1..^1].mapIt($it).join(", ")
      if not options.lenient:
        raise newNimbleError[NimbleError](
          &"Multiple dependencies require different special versions of '{pkgName}': " &
          &"{specialVersions[0]}, {others}.")
      winners[pkgName] = winner
      pkgVersions.versions = pkgVersions.versions.filterIt(
        not it.version.isSpecial or it.version == winner
      )
      displayWarning(&"Multiple dependencies require different special versions of '{pkgName}': " &
        &"using {winner}, ignoring {others}. This will become an error in future versions.", HighPriority)

  # Phase 2: remove URL-keyed table entries for packages that have a winner
  # and fix normalizedRequirements so it points to the correct URL
  if winners.len > 0:
    var keysToRemove: seq[string] = @[]
    var winnerUrls = initTable[string, string]()  # pkgName -> URL of fork that has the winning version
    for key, pkgVersions in pkgVersionTable:
      if key.isUrl and pkgVersions.versions.len > 0:
        let name = pkgVersions.versions[0].name.toLower
        if name in winners:
          for v in pkgVersions.versions:
            if v.version == winners[name]:
              winnerUrls[name] = key
              break
          keysToRemove.add key
    for key in keysToRemove:
      pkgVersionTable.del key
    # Update normalizedRequirements: point to the winning fork's URL,
    # or remove the entry if the winner came from a name-based requirement
    # (so normal package resolution finds the official URL from packages.json)
    for name, winner in winners:
      if name in winnerUrls:
        options.satResult.normalizedRequirements[name] = winnerUrls[name]
      elif name in options.satResult.normalizedRequirements:
        options.satResult.normalizedRequirements.del name

    # Phase 3: rewrite requirements across the table to use winning versions
    for pkgName, pkgVersions in pkgVersionTable.mpairs:
      for pkgVersion in pkgVersions.versions.mitems:
        for req in pkgVersion.requires.mitems:
          let reqName = req.name.toLower
          if reqName in winners and req.ver.kind == verSpecial and req.ver.spe != winners[reqName]:
            req.ver = VersionRange(kind: verSpecial, spe: winners[reqName])
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

proc solveLocalPackages(root: PackageMinimalInfo, pkgList: seq[PackageInfo], options: Options, output: var string, solvedPkgs: var seq[SolvedPackage], nimBin: string): HashSet[PackageInfo] =
  ## Try to solve using only installed packages (no cache, no downloads).
  ## Returns the solved packages if successful, or an empty set if local
  ## packages don't satisfy all constraints. See #1648.
  var localTable = initTable[string, PackageVersions]()
  localTable[root.name] = PackageVersions(pkgName: root.name, versions: @[root])
  localTable.fillPackageTableFromPreferred(pkgList.mapIt(it.getMinimalInfo(options)))
  var localOutput = ""
  let localSolved = localTable.getSolvedPackages(localOutput, options)
  if localSolved.len == 0:
    return  # Local solve failed, caller should fall back to full resolution
  localTable.normalizeRequirements(options)
  localTable.normalizeSpecialVersions(options)
  options.satResult.pkgVersionTable = localTable
  solvedPkgs = localTable.getSolvedPackages(output, options).topologicalSort()
  solvedPkgs.postProcessSolvedPkgs(options, nimBin)
  var pkgs: HashSet[PackageInfo]
  for solvedPkg in solvedPkgs:
    if solvedPkg.pkgName == root.name: continue
    for pkgInfo in pkgList:
      if (cmpIgnoreCase(pkgInfo.basicInfo.name, solvedPkg.pkgName) == 0 or cmpIgnoreCase(pkgInfo.metadata.url, solvedPkg.pkgName) == 0) and
        pkgInfo.basicInfo.version == solvedPkg.version:
        pkgs.incl pkgInfo
        break
  return pkgs

proc solvePackages*(rootPkg: PackageInfo, pkgList: seq[PackageInfo], pkgsToInstall: var seq[(string, Version)], options: Options, output: var string, solvedPkgs: var seq[SolvedPackage], nimBin: string): HashSet[PackageInfo] {.instrument.} =
  var root: PackageMinimalInfo = rootPkg.getMinimalInfo(options)
  root.isRoot = true

  # Try local solve first: if installed packages satisfy all constraints,
  # use them without fetching newer versions. Skip for upgrade/lock which
  # explicitly want fresh resolution.
  if pkgList.len > 0 and options.action.typ notin {actionUpgrade, actionLock}:
    let localResult = solveLocalPackages(root, pkgList, options, output, solvedPkgs, nimBin)
    if localResult.len > 0 or solvedPkgs.len > 0:
      return localResult

  var pkgVersionTable: Table[system.string, packageinfotypes.PackageVersions]
  # Load cached package versions to skip re-fetching known packages
  pkgVersionTable = cacheToPackageVersionTable(options)
  pkgVersionTable[root.name] = PackageVersions(pkgName: root.name, versions: @[root])

  if not options.useAsyncDownloads:
    collectAllVersions(pkgVersionTable, root, options, downloadMinimalPackage, pkgList.mapIt(it.getMinimalInfo(options)), nimBin)
  else:
    # Async version: collect versions in parallel, then merge with cache
    let asyncVersions = waitFor collectAllVersionsAsync(root, options, downloadMinimalPackageAsync, pkgList.mapIt(it.getMinimalInfo(options)), nimBin)
    for pkgName, pkgVersions in asyncVersions:
      if pkgName notin pkgVersionTable:
        pkgVersionTable[pkgName] = pkgVersions
      else:
        for ver in pkgVersions.versions:
          pkgVersionTable[pkgName].versions.addUnique ver

  # dumpPackageVersionTable(rootPkg, pkgVersionTable, options, nimBin)

  pkgVersionTable.normalizeRequirements(options)
  pkgVersionTable.normalizeSpecialVersions(options)

  options.satResult.pkgVersionTable = pkgVersionTable
  solvedPkgs = pkgVersionTable.getSolvedPackages(output, options).topologicalSort()
  solvedPkgs.postProcessSolvedPkgs(options, nimBin)
  
  let systemNimCompatible = solvedPkgs.isSystemNimCompatible(options, getNimVersionFromBin(nimBin))
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
          ((options.action.typ in {actionLock}) or #For lock the result is cleaned in the lock proc that handles the pass
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
  # Load cached package versions to skip re-fetching known packages
  result = cacheToPackageVersionTable(options)
  var root = pkgInfo.getMinimalInfo(options)
  root.isRoot = true
  result[root.name] = PackageVersions(pkgName: root.name, versions: @[root])
  if options.useAsyncDownloads:
    # Use async version for parallel downloading
    let asyncVersions = waitFor collectAllVersionsAsync(root, options, downloadMinimalPackageAsync, pkgList.mapIt(it.getMinimalInfo(options)), nimBin)
    # Merge async results into the result table
    for pkgName, pkgVersions in asyncVersions:
      if not result.hasKey(pkgName):
        result[pkgName] = pkgVersions
      else:
        for ver in pkgVersions.versions:
          result[pkgName].versions.addUnique ver
  else:
    # Use sync version (default, stable behavior)
    collectAllVersions(result, root, options, downloadMinimalPackage, pkgList.mapIt(it.getMinimalInfo(options)), nimBin)


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

proc dumpPackageVersionTable*(pkg: PackageInfo, pkgVersionTable: Table[string, PackageVersions], options: Options, nimBin: string) =
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

proc dumpPackageVersionTable*(pkg: PackageInfo, pkgList: seq[PackageInfo], options: Options, nimBin: string) =
  let pkgVersionTable = getPkgVersionTable(pkg, pkgList, options, nimBin)
  dumpPackageVersionTable(pkg, pkgVersionTable, options, nimBin)
