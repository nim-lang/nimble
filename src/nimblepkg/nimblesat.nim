import sat/[sat, satvars]
import version, packageinfotypes, options, tools, cli
import versiondiscovery
import nimblepubgrub

import compat/[sequtils]
import std/[tables, algorithm, sets, strutils, options, strformat]

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

proc cmp(a, b: DependencyVersion, algorithm: ResolutionAlgorithm): int =
  ## Orders versions so the SAT solver's "try FALSE first" strategy lands on the
  ## desired one. The solver assigns lower VarIds (earlier in this order) first
  ## and tries them FALSE, so the LAST version in this order is the most
  ## preferred. Special versions (#head, #branch, …) are always placed FIRST
  ## (least preferred) so regular/tagged versions win, in both algorithms.
  ##
  ## - raMaxVer: regular versions ascending  -> newest is last  -> newest wins.
  ## - raMinVer: regular versions descending -> oldest is last  -> oldest wins.
  let aIsSpecial = a.version.isSpecial
  let bIsSpecial = b.version.isSpecial

  # Special versions come first (treated as "least preferred") in both modes.
  if aIsSpecial and not bIsSpecial:
    return -1
  elif bIsSpecial and not aIsSpecial:
    return 1

  # Both special or both regular: normal comparison, reversed for raMinVer.
  let c =
    if a.version < b.version: -1
    elif a.version == b.version: 0
    else: 1
  if algorithm == raMinVer: -c else: c

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

proc toFormular*(g: var DepGraph, algorithm = raMaxVer): Form =
  result = Form()
  var b = Builder()
  b.openOpr(AndForm)

  # First pass: Assign variables and encode version selection constraints
  for p in mitems(g.nodes):
    if p.versions.len == 0: continue
    p.versions.sort(proc (x, y: DependencyVersion): int = cmp(x, y, algorithm))
    
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
        if depIdx < 0:
          # Dependency not in the graph at all (e.g. removed from registry).
          # This version cannot be selected.
          allDepsCompatible = false
          break
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
        let depVersions =
          if depNodeIdx < 0: newSeq[DependencyVersion]()
          else: g.nodes[depNodeIdx].versions
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

type SatAttemptOutcome = enum
  saoSat, saoUnsat, saoOverflow

proc attemptSatisfiable(f: Form; s: var Solution): SatAttemptOutcome =
  ## Keeps "ran out of iterations" distinct from a
  ## definitive "no solution exists": the two must not be conflated, because
  ## the DPLL search giving up says nothing about the formula.
  try:
    if satisfiable(f.f, s): saoSat else: saoUnsat
  except SatOverflowError:
    saoOverflow

const MaxSolveRotations = 24
  ## How many alternative node orderings to try when the SAT search exceeds its
  ## iteration budget. Each attempt is bounded by the solver's own budget
  ## (~hundreds of ms), so this caps the extra work at a few seconds.

proc rotatedGraph(g: DepGraph; shift: int): DepGraph =
  ## Same graph, with the non-root nodes rotated by `shift`. The DPLL search
  ## branches on variables in formula order, which follows node order, so a
  ## rotation gives it a genuinely different search tree. Root stays at
  ## index 0 — consumers rely on that.
  result = DepGraph(reqs: g.reqs)
  result.nodes.add g.nodes[0]
  let n = g.nodes.len - 1
  for i in 0 ..< n:
    result.nodes.add g.nodes[1 + ((i + shift) mod n)]
  for i in 0 ..< result.nodes.len:
    result.packageToDependency[result.nodes[i].pkgName] = i
    for ver in result.nodes[i].versions:
      if ver.url != "":
        result.packageToDependency[ver.url] = i

proc decideSatisfiable(g0: DepGraph; algorithm: ResolutionAlgorithm;
                       gUsed: var DepGraph; fUsed: var Form; s: var Solution;
                       startShift = 0): SatAttemptOutcome =
  ## Decides satisfiability, retrying under rotated node orders when the
  ## search overflows its iteration budget: the DPLL search is extremely
  ## sensitive to variable order, and real dependency graphs that overflow
  ## under one order are typically solved in milliseconds under another
  ## (found while chasing the nimlangserver tree, see
  ## tests/packageMinimal/nimlangserver.json). Returns the first definitive
  ## outcome, leaving the decisive graph/formula/solution in gUsed/fUsed/s;
  ## saoOverflow means every attempted ordering ran out of budget.
  result = saoOverflow
  for shift in startShift .. min(g0.nodes.len - 1, MaxSolveRotations):
    var g2 = if shift == 0: g0 else: rotatedGraph(g0, shift)
    let f2 = toFormular(g2, algorithm)
    var s2 = createSolution(f2.idgen)
    let o = attemptSatisfiable(f2, s2)
    if o == saoOverflow:
      continue
    gUsed = g2
    fUsed = f2
    s = s2
    return o

proc findMinimalFailingSet*(g: var DepGraph): tuple[failingSet, implicated: seq[PkgTuple], output: string] =
  var minimalFailingSet: seq[PkgTuple] = @[]
  var implicated: seq[PkgTuple] = @[]
  let rootNode = g.nodes[0]
  let rootVersion = rootNode.versions[0]
  var allDeps = g.reqs[rootVersion.req].deps

  # Try removing one dependency at a time to see if it makes it satisfiable
  for i in 0..<allDeps.len:
    var reducedDeps = allDeps
    reducedDeps.delete(i)
    var tempGraph = g
    tempGraph.reqs[rootVersion.req].deps = reducedDeps
    var gU: DepGraph
    var fU: Form
    var sU: Solution
    case decideSatisfiable(tempGraph, raMaxVer, gU, fU, sU)
    of saoSat:
      # Removing this dependency resolves the conflict, so it is one of the
      # actual participants — these are the packages worth pinning to an
      # older version in the fallback retry (e.g. libp2p when a pinned quic
      # commit is incompatible with the newest libp2p).
      implicated.add(allDeps[i])
    of saoUnsat, saoOverflow:
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
  
  (minimalFailingSet, implicated, output)

proc solve*(g: var DepGraph; f: Form, packages: var Table[string, Version], output: var string,
           triedVersions: var seq[VersionAttempt], options: Options): bool {.instrument.} =
  var fUsed = f
  var s = createSolution(fUsed.idgen)
  var outcome = attemptSatisfiable(fUsed, s)
  if outcome == saoOverflow:
    # Retry under rotated node orders before concluding anything; adopt the
    # ordering that produced a definitive answer (see decideSatisfiable).
    outcome = decideSatisfiable(g, options.resolutionAlgorithm, g, fUsed, s,
                                startShift = 1)
  if outcome == saoSat:
    # output.add analyzeVersionSelection(g, fUsed, s)
    for n in mitems g.nodes:
      if n.isRoot: n.active = true
    for i in 0 ..< fUsed.idgen:
      if s.isTrue(VarId(i)) and fUsed.mapping.hasKey(VarId i):
        let m = fUsed.mapping[VarId i]
        let idx = findDependencyForDep(g, m.pkg)
        g.nodes[idx].active = true
        g.nodes[idx].activeVersion = m.index

    for n in items g.nodes:
      for v in items(n.versions):
        let item = fUsed.mapping[v.v]
        if s.isTrue(v.v):
          packages[item.pkg] = item.version
          output.add &"{item.pkg}  [x]  {toString item} \n"
        else:
          output.add &"{item.pkg}  [ ]  {toString item} \n"
    return true
  else:
    if outcome == saoOverflow:
      output.add "\nThe dependency search exceeded its iteration budget on " &
                 "every attempted ordering; the analysis below may be incomplete.\n"
    output.add &"\nFailed to find satisfiable solution (pass: {options.satResult.pass}):\n"
    output.add analyzeVersionSelection(g, fUsed, s)
    let (failingSet, implicated, errorMsg) = findMinimalFailingSet(g)
    # Pin the packages actually implicated in the conflict (removing them
    # resolves it), falling back to the failing set when nothing is: pinning a
    # package whose removal changes nothing cannot fix the solve.
    let retryCandidates = if implicated.len > 0: implicated else: failingSet
    if retryCandidates.len > 0:
      var newGraph = g

      # Try each failing package
      for pkg in retryCandidates:
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
              let newForm = toFormular(newGraph, options.resolutionAlgorithm)
              if solve(newGraph, newForm, packages, output, triedVersions, options):
                return true
          # Restore original versions if no solution found
          newGraph.nodes[idx].versions = originalVersions
      
      output.add "\n\nFinal error message:\n"  # Add a separator
      output.add errorMsg
    else:
      output.add "\n\nFinal error message:\n"  # Add a separator
      output.add generateUnsatisfiableMessage(g, fUsed, s)
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

const solverDisagreementNote =
  "\nNote: the dependency graph appears solvable (PubGrub found a solution " &
  "where the SAT solver did not). This is a solver bug - please report it at " &
  "https://github.com/nim-lang/nimble/issues\n"

proc toSolvedPackages*(graph: DepGraph, packages: Table[string, Version]): seq[SolvedPackage] =
  ## The chosen version of every package, with what it requires and what
  ## requires it - the shape installation and lock files read, whichever
  ## solver made the choice.
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

proc satPackages*(graph: var DepGraph, pkgVersionTable: Table[string, PackageVersions],
                  output: var string, options: Options): Table[string, Version] =
  ## `--solver:sat`: the version chosen for each package in `graph` (built
  ## from `pkgVersionTable`), or none, with the reason in `output`. When SAT
  ## finds no solution, PubGrub re-solves the table to explain why.

  # Only validate packages reachable from root, not ALL packages in the table.
  # Pre-loaded cached packages may have deps not relevant to this resolution;
  # those will be handled by toFormular (marked as unsatisfiable).

  var lowerCasePackages = initHashSet[string]()
  for key in graph.packageToDependency.keys:
    lowerCasePackages.incl(key.toLowerAscii)

  let reachable = getReachablePackages(graph)
  var missingDeps: seq[string]
  for pkgName in reachable:
    if pkgName.toLowerAscii notin lowerCasePackages:
      missingDeps.add pkgName
  if missingDeps.len > 0:
    # Check if ALL versions that require the missing deps also have alternative
    # versions that don't. If so, the solver can still find a solution by picking
    # versions that don't need the missing packages.
    var allMissingAreOptional = true
    for missing in missingDeps:
      # Find which packages require this missing dep
      for node in graph.nodes:
        var hasVersionWithout = false
        var hasVersionWith = false
        for ver in node.versions:
          var needsMissing = false
          for dep, q in items graph.reqs[ver.req].deps:
            if dep.toLowerAscii == missing.toLowerAscii:
              needsMissing = true
              break
          if needsMissing:
            hasVersionWith = true
          else:
            hasVersionWithout = true
        # If a package has versions requiring the missing dep but no alternatives, it's fatal
        if hasVersionWith and not hasVersionWithout:
          allMissingAreOptional = false
          break
      if not allMissingAreOptional:
        break
    if not allMissingAreOptional:
      # A package nothing can provide is a resolution failure like any other,
      # so explain it the same way instead of dumping the whole universe: the
      # table only helps when debugging the resolver itself (--verbose).
      let (foundSolution, explanation) = explainSolveFailure(pkgVersionTable)
      if explanation.len > 0 and options.verbosity > LowPriority:
        output = "Dependency resolution failed:\n" & explanation & "\n"
      else:
        output.add "Missing dependencies: " & missingDeps.join(", ") & "\n"
        for k, v in pkgVersionTable:
          output.add &"Package {k} \n"
          for v in v.versions:
            output.add &"\t \t Version {v.version} requires: {v.requires} \n"
        if explanation.len > 0:
          output.add "\n" & explanation & "\n"
        elif foundSolution:
          # The missing-dependency heuristic above scans every node, reachable
          # or not, so it can declare fatal what the solver would route around.
          output.add solverDisagreementNote
      output.addDiscoveryErrors(options)
      return
    
  let form = toFormular(graph, options.resolutionAlgorithm)
  var packages = initTable[string, Version]()
  var triedVersions: seq[VersionAttempt] = @[]
  if not solve(graph, form, packages, output, triedVersions, options):
    # SAT found no solution. PubGrub re-solves the same universe to produce
    # an explanation of *why* - and if it finds a solution instead, one of
    # the two solvers is wrong, which is worth surfacing loudly.
    let (foundSolution, explanation) = explainSolveFailure(pkgVersionTable)
    if explanation.len > 0:
      if options.verbosity <= LowPriority:
        # --verbose/--debug: keep the SAT solver's full search dump above.
        output.add "\n" & explanation & "\n"
      else:
        # The explanation is the user-facing error; the search dump is noise.
        output = "Dependency resolution failed:\n" & explanation & "\n"
    elif foundSolution:
      output.add solverDisagreementNote

  result = packages
