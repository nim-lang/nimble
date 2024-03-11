import sat/[sat, satvars] 
import version, packageinfotypes, download, packageinfo, packageparser, options, sha1hashes
  
import std/[tables, sequtils, algorithm, json, jsonutils, strutils]


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

proc getMinimalInfo*(pkg: PackageInfo): PackageMinimalInfo =
  result.name = pkg.basicInfo.name
  result.version = pkg.basicInfo.version
  result.requires = pkg.requires

proc hasVersion*(packageVersions: PackageVersions, pv: PkgTuple): bool =
  for pkg in packageVersions.versions:
    if pkg.name == pv.name and pkg.version.withinRange(pv.ver):
      return true
  false

proc hasVersion*(packagesVersions: var Table[string, PackageVersions], pv: PkgTuple): bool =
  if pv.name in packagesVersions:
    return packagesVersions[pv.name].hasVersion(pv)
  false

proc getNimVersion*(pvs: seq[PkgTuple]): Version =
  result = newVersion("0.0.0") #?
  for pv in pvs:
    if pv.name == "nim":
      return pv.ver.ver

proc findDependencyForDep(g: DepGraph; dep: string): int {.inline.} =
  assert g.packageToDependency.hasKey(dep), dep & " not found"
  result = g.packageToDependency.getOrDefault(dep)

iterator mvalidVersions*(p: var Dependency; g: var DepGraph): var DependencyVersion =
  for v in mitems p.versions:
    # if g.reqs[v.req].status == Normal: yield v
    yield v #in our case all are valid versions (TODO get rid of this)


proc createRequirements(pkg: PackageMinimalInfo): Requirements =
  result.deps = pkg.requires.filterIt(it.name != "nim")
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

  for p in mitems(g.nodes):
    # if Package p is installed, pick one of its concrete versions, but not versions
    # that are errornous:
    # A -> (exactly one of: A1, A2, A3)
    if p.versions.len == 0: continue

    p.versions.sort(cmp)

    var i = 0
    for ver in mitems p.versions:
      ver.v = VarId(result.idgen)
      result.mapping[ver.v] = SatVarInfo(pkg: p.pkgName, version: ver.version, index: i)

      inc result.idgen
      inc i
    if p.isRoot:
      b.openOpr(ExactlyOneOfForm)
      for ver in mitems p.versions: b.add ver.v
      b.closeOpr # ExactlyOneOfForm
    else:
      # Either one version is selected or none:
      b.openOpr(ZeroOrOneOfForm)
      for ver in mitems p.versions: b.add ver.v
      b.closeOpr # ExactlyOneOfForm

  # # Model the dependency graph:
  for p in mitems(g.nodes):
    for ver in mvalidVersions(p, g):
      # if isValid(g.reqs[ver.req].v):
      #   # already covered this sub-formula (ref semantics!)
      #   continue
      let eqVar = VarId(result.idgen)
      g.reqs[ver.req].v = eqVar

      if g.reqs[ver.req].deps.len == 0: continue
      inc result.idgen

      let beforeEq = b.getPatchPos()

      b.openOpr(OrForm)
      b.addNegated eqVar
      if g.reqs[ver.req].deps.len > 1: b.openOpr(AndForm)
      # if ver.req.deps.len > 1: b.openOpr(AndForm)
      var elements = 0
      for dep, q in items g.reqs[ver.req].deps:
        let av = g.nodes[findDependencyForDep(g, dep)]
        if av.versions.len == 0: continue

        let beforeExactlyOneOf = b.getPatchPos()
        b.openOpr(ExactlyOneOfForm)
        inc elements
        var matchCounter = 0

        for j in countup(0, av.versions.len-1):
          if av.versions[j].version.withinRange(q):
            b.add av.versions[j].v
            inc matchCounter
            break

        b.closeOpr # ExactlyOneOfForm
        if matchCounter == 0:
          b.resetToPatchPos beforeExactlyOneOf
          b.add falseLit()
        
      if g.reqs[ver.req].deps.len > 1: b.closeOpr # AndForm
      b.closeOpr # EqForm
      if elements == 0:
        b.resetToPatchPos beforeEq
       
  # Model the dependency graph:
  for p in mitems(g.nodes):
    for ver in mvalidVersions(p, g):
      if g.reqs[ver.req].deps.len > 0:
      # if ver.req.deps.len > 0:
        b.openOpr(OrForm)
        b.addNegated ver.v # if this version is chosen, these are its dependencies
        b.add g.reqs[ver.req].v
        # b.add ver.req.v
        b.closeOpr # OrForm

  b.closeOpr # AndForm
  result.f = toForm(b)

proc toString(x: SatVarInfo): string =
  "(" & x.pkg & ", " & $x.version & ")"

proc debugFormular(g: var DepGraph; f: Form; s: Solution) =
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


proc solve*(g: var DepGraph; f: Form, packages: var Table[string, Version], listVersions: bool = false) =
  let m = f.idgen
  var s = createSolution(m)
  #debugFormular c, g, f, s
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
            if listVersions:
              echo item.pkg, "[x] " & toString item
          else:
            if listVersions:
              echo item.pkg, "[ ] " & toString item
  else:
    debugFormular(g, f, s)