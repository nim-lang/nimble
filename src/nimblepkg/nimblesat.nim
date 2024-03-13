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
      case pv.ver.kind:
      of verLater, verEarlier, verEqLater, verEqEarlier, verEq:
        result = pv.ver.ver
      of verSpecial:
        result = pv.ver.spe
      else:
        #TODO range
        discard
      

proc findDependencyForDep(g: DepGraph; dep: string): int {.inline.} =
  assert g.packageToDependency.hasKey(dep), dep & " not found"
  result = g.packageToDependency.getOrDefault(dep)

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