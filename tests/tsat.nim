{.used.}
import unittest, os
import testscommon
from nimblepkg/common import cd
import std/[tables, sequtils, algorithm, json, jsonutils]
import nimblepkg/[version, sha1hashes, packageinfotypes, nimblesat, options, 
  download, packageinfo, packageparser, config]
import sat/[sat, satvars] 
import nimble

type
  PackageMinimalInfo* = object
    name: string
    version: Version
    requires: seq[PkgTuple]
    isRoot: bool

proc getMinimalInfo(pkg: PackageInfo): PackageMinimalInfo =
  result.name = pkg.basicInfo.name
  result.version = pkg.basicInfo.version
  result.requires = pkg.requires

let allPackages: seq[PackageBasicInfo] = @[
  (name: "a", version: newVersion "3.0", checksum: Sha1Hash()),
  (name: "a", version: newVersion "4.0", checksum: Sha1Hash()),
  (name: "b", version: newVersion "0.1.0", checksum: Sha1Hash()),
  (name: "b", version: newVersion "0.5", checksum: Sha1Hash()),
  (name: "c", version: newVersion "0.1.0", checksum: Sha1Hash()),
  (name: "c", version: newVersion "0.2.1", checksum: Sha1Hash())
]



when false:
  type
    PkgTuple* = tuple[name: string, ver: VersionRange]
    PackageBasicInfo* = tuple
      name: string
      version: Version
      checksum: Sha1Hash
    PackageInfo* = object
      myPath*: string ## The path of this .nimble file
      isNimScript*: bool ## Determines if this pkg info was read from a nims file
      isMinimal*: bool
      isInstalled*: bool ## Determines if the pkg this info belongs to is installed
      author*: string
      description*: string
      license*: string
      skipDirs*: seq[string]
      skipFiles*: seq[string]
      skipExt*: seq[string]
      installDirs*: seq[string]
      installFiles*: seq[string]
      installExt*: seq[string]
      requires*: seq[PkgTuple]

type 

  PackageVersions = object
    pkgName: string
    versions: seq[PackageMinimalInfo]
  
  Requirements* = object
    deps*: seq[PkgTuple] #@[(name, versRange)]
    version*: Version
    nimVersion*: Version
    v*: VarId
    err*: string

  DependencyVersion* = object  # Represents a specific version of a project.
    version*: Version
    # req*: int # index into graph.reqs so that it can be shared between versions
    v: VarId
    req: Requirements

  Dependency* = object
    pkgName*: string
    versions*: seq[DependencyVersion]
    active*: bool
    activeVersion*: int
    isRoot*: bool

  DepGraph* = object
    nodes: seq[Dependency]
    # reqs: seq[Requirements]
    packageToDependency: Table[string, int] #package.name -> index into nodes
    # reqsByDeps: Table[Requirements, int]

proc hasVersion(packageVersions: PackageVersions, pv: PkgTuple): bool =
  for pkg in packageVersions.versions:
    if pkg.name == pv.name and pkg.version.withinRange(pv.ver):
      return true
  false

proc hasVersion(packagesVersions: var Table[string, PackageVersions], pv: PkgTuple): bool =
  if pv.name in packagesVersions:
    return packagesVersions[pv.name].hasVersion(pv)
  false

proc getNimVersion(pvs: seq[PkgTuple]): Version =
  result = newVersion("0.0.0") #?
  for pv in pvs:
    if pv.name == "nim":
      return pv.ver.ver
  
proc downloadPkInfoForPv(pv: PkgTuple, options: Options): PackageInfo  =
  let (meth, url, metadata) = 
    getDownloadInfo(pv, options, doPrompt = true)
  let subdir = metadata.getOrDefault("subdir")
  let res = 
    downloadPkg(url, pv.ver, meth, subdir, options,
                  downloadPath = "", vcsRevision = notSetSha1Hash)
  return getPkgInfo(res.dir, options)

proc collectAllVersions(versions: var Table[string, PackageVersions], package: PackageInfo, options: Options) =
  for pv in package.requires:
    if not hasVersion(versions, pv):  # Not found, meaning this package-version needs to be explored
      let pkgInfo = downloadPkInfoForPv(pv, options)
      if not versions.hasKey(pv.name):
        versions[pv.name] = PackageVersions(pkgName: pv.name, versions: @[pkgInfo.getMinimalInfo()])
      else:
        versions[pv.name].versions.add pkgInfo.getMinimalInfo()
      collectAllVersions(versions, pkgInfo, options)

proc createRequirements(pkg: PackageMinimalInfo): Requirements =
  result.deps = pkg.requires.filterIt(it.name != "nim")
  result.version = pkg.version
  result.nimVersion = pkg.requires.getNimVersion()

proc cmp(a,b: DependencyVersion): int =
  if a.version < b.version: return -1
  elif a.version == b.version: return 0
  else: return 1

proc toDependencyVersion(pkg: PackageMinimalInfo): DependencyVersion =
  result.version = pkg.version
  result.req = createRequirements(pkg) #TODO optimize this by sharing the reqs
  
proc toDependency(pkg: PackageVersions): Dependency = 
  result.pkgName = pkg.pkgName
  result.versions = pkg.versions.map(toDependencyVersion)
  assert pkg.versions.len > 0, "Package must have at least one version"
  result.isRoot = pkg.versions[0].isRoot

proc toDepGraph(versions: Table[string, PackageVersions]): DepGraph =
  result.nodes.add versions.values.toSeq.map(toDependency)
  # Fill the other field and I should be good to go?
  for i in countup(0, result.nodes.len-1):
    result.packageToDependency[result.nodes[i].pkgName] = i
    

proc findDependencyForDep(g: DepGraph; dep: string): int {.inline.} =
  assert g.packageToDependency.hasKey(dep), $(dep, g.packageToDependency)
  result = g.packageToDependency.getOrDefault(dep)

iterator mvalidVersions*(p: var Dependency; g: var DepGraph): var DependencyVersion =
  for v in mitems p.versions:
    # if g.reqs[v.req].status == Normal: yield v
    yield v #in our case all are valid versions (TODO we rid of this)

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

  #   if p.status != Ok:
  #     # all of its versions must be `false`
  #     b.openOpr(AndForm)
  #     for ver in mitems p.versions: b.addNegated ver.v
  #     b.closeOpr # AndForm
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
     #Nimble: Not covered as we are not sharing reqs
      # if isValid(g.reqs[ver.req].v):
  #       # already covered this sub-formula (ref semantics!)
  #       continue
      let eqVar = VarId(result.idgen)
      # g.reqs[ver.req].v = eqVar
      ver.req.v = eqVar
      inc result.idgen

  #     if g.reqs[ver.req].deps.len == 0: continue
      if ver.req.deps.len == 0: continue
      let beforeEq = b.getPatchPos()

      b.openOpr(OrForm)
      b.addNegated eqVar
  #     if g.reqs[ver.req].deps.len > 1: b.openOpr(AndForm)
      if ver.req.deps.len > 1: b.openOpr(AndForm)
      var elements = 0
  #     for dep, query in items g.reqs[ver.req].deps:
      for dep, query in items ver.req.deps:
      
        # let q = if algo == SemVer: toSemVer(query) else: query
        let q = query
  #       let commit = extractSpecificCommit(q)
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
        
      if ver.req.deps.len > 1: b.closeOpr # AndForm
      b.closeOpr # EqForm
      if elements == 0:
        b.resetToPatchPos beforeEq
        #END BLOCK Below
        # if commit.len > 0:
        #   for j in countup(0, av.versions.len-1):
        #     if q.matches(av.versions[j].version) or commit == av.versions[j].commit:
        #       b.add av.versions[j].v
        #       inc matchCounter
        #       break
  #         #mapping.add (g.nodes[i].pkg, commit, v)
  #       elif algo == MinVer:
  #         for j in countup(0, av.versions.len-1):
  #           if q.matches(av.versions[j].version):
  #             b.add av.versions[j].v
  #             inc matchCounter
  #       else:
  #         for j in countdown(av.versions.len-1, 0):
  #           if q.matches(av.versions[j].version):
  #             b.add av.versions[j].v
  #             inc matchCounter
  #       b.closeOpr # ExactlyOneOfForm
  #       if matchCounter == 0:
  #         b.resetToPatchPos beforeExactlyOneOf
  #         b.add falseLit()
  #         #echo "FOUND nothing for ", q, " ", dep

  #     if g.reqs[ver.req].deps.len > 1: b.closeOpr # AndForm
  #     b.closeOpr # EqForm
  #     if elements == 0:
  #       b.resetToPatchPos beforeEq

  # Model the dependency graph:
  for p in mitems(g.nodes):
    for ver in mvalidVersions(p, g):
      # if g.reqs[ver.req].deps.len > 0:
      if ver.req.deps.len > 0:
        b.openOpr(OrForm)
        b.addNegated ver.v # if this version is chosen, these are its dependencies
        # b.add g.reqs[ver.req].v
        b.add ver.req.v
        b.closeOpr # OrForm

  b.closeOpr # AndForm
  result.f = toForm(b)


  #[

    if g.reqs[pv.req].status == Normal:
      for dep, interval in items(g.reqs[pv.req].deps):
        let didx = g.packageToDependency.getOrDefault(dep, -1)
        if didx == -1:
          g.packageToDependency[dep] = g.nodes.len
          g.nodes.add Dependency(pkg: dep, versions: @[], isRoot: idx == 0, activeVersion: -1)
          enrichVersionsViaExplicitHash g.nodes[g.nodes.len-1].versions, interval
        else:
  ]#


proc toString(x: SatVarInfo): string =
  "(" & x.pkg & ", " & $x.version & ")"

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
        # echo "setting ", idx, " to active ", g.nodes[idx].pkg
        g.nodes[idx].active = true
        # assert g.nodes[idx].activeVersion == -1, "too bad: " & g.nodes[idx].pkg.url
        g.nodes[idx].activeVersion = m.index
        # debug c, m.pkg.projectName, "package satisfiable"
  #       if m.commit != "" and g.nodes[idx].status == Ok:
  #         assert g.nodes[idx].ondisk.len > 0, $(g.nodes[idx].pkg, idx)
  #         withDir c, g.nodes[idx].ondisk:
  #           checkoutGitCommit(c, m.pkg.projectName, m.commit)

  #   if NoExec notin c.flags:
  #     runBuildSteps(c, g)
  #     #echo f

    # if ListVersions in c.flags:
      # info c, "../resolve", "selected:"
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
    echo "FORM: ", f.f
    # var notFound = 0
    # for p in mitems(g.nodes):
      # if p.isRoot and p.status != Ok:
  #       error c, c.workspace, "cannot find package: " & p.pkg.projectName
  #       inc notFound
  #   if notFound > 0: return
    # error c, c.workspace, "version conflict; for more information use --showGraph"
    for p in mitems(g.nodes):
      var usedVersions = 0
      for ver in mvalidVersions(p, g):
        if s.isTrue(ver.v): inc usedVersions
      if usedVersions > 1:
        for ver in mvalidVersions(p, g):
          if s.isTrue(ver.v):
            echo "last here"
            # error c, p.pkg.projectName, string(ver.version) & " required"

# proc fromJsonHook(json: JsonNode): VersionRangeEnum =
#   #Kind is int
#   VersionRangeEnum(json.getInt)

proc initFromJson*(dst: var VersionRangeEnum, jsonNode: JsonNode, jsonPath: var string) =
  dst = jsonNode.getInt.VersionRangeEnum


suite "SAT solver":
  test "can solve simple SAT":
    let pkgVersionTable = {
      "a": PackageVersions(pkgName: "a", versions: @[
        PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
          (name:"b", ver: parseVersionRange ">= 0.1.0")
        ], isRoot:true),
      ]),
      "b": PackageVersions(pkgName: "b", versions: @[
        PackageMinimalInfo(name: "b", version: newVersion "0.1.0")
      ])
    }.toTable()
    var graph = pkgVersionTable.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    solve(graph, form, packages, true)
    check packages.len == 2
    check packages["a"] == newVersion "3.0"
    check packages["b"] == newVersion "0.1.0"


  test "solves 'Conflicting dependency resolution' #1162":
    let pkgVersionTable = {
      "a": PackageVersions(pkgName: "a", versions: @[
        PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
          (name:"b", ver: parseVersionRange ">= 0.1.4"),
          (name:"c", ver: parseVersionRange ">= 0.0.5 & <= 0.1.0")
        ], isRoot:true),
      ]),
      "b": PackageVersions(pkgName: "b", versions: @[
        PackageMinimalInfo(name: "b", version: newVersion "0.1.4", requires: @[
          (name:"c", ver: VersionRange(kind: verAny))
        ]),
      ]),
      "c": PackageVersions(pkgName: "c", versions: @[
        PackageMinimalInfo(name: "c", version: newVersion "0.1.0"),
        PackageMinimalInfo(name: "c", version: newVersion "0.2.1")
      ])
    }.toTable()
    var graph = pkgVersionTable.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    solve(graph, form, packages, true)
    check packages.len == 3
    check packages["a"] == newVersion "3.0"
    check packages["b"] == newVersion "0.1.4"
    check packages["c"] == newVersion "0.1.0"


  test "dont solve unsatisfable":
    let pkgVersionTable = {
      "a": PackageVersions(pkgName: "a", versions: @[
        PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
          (name:"b", ver: parseVersionRange ">= 0.5.0")
        ], isRoot:true),
      ]),
      "b": PackageVersions(pkgName: "b", versions: @[
        PackageMinimalInfo(name: "b", version: newVersion "0.1.0")
      ])
    }.toTable()
    var graph = pkgVersionTable.toDepGraph()
    let form = toFormular(graph)
    var packages = initTable[string, Version]()
    solve(graph, form, packages)
    echo packages
    check packages.len == 0

  # test "issue #1162":
  #   cd "conflictingdepres":
  #     #integration version of the test above
  #     #TODO document folder structure setup so others know how to run similar tests
  #     let (_, exitCode) = execNimble("install", "-l")
  #     check exitCode == QuitSuccess


  test "should be able to retrieve the package versions using git":
    #[
      Testear uno que tenga varios paquetes.
      

    ]#
    # let pkgName: string = "nimlangserver"
    # let pv: PkgTuple = (pkgName, VersionRange(kind: verAny))
    # var options = initOptions()
    # options.nimBin = "nim"
    # # options.config.packageLists["uing"] = PackageList(name: pkgName, urls: @[pkgUrl])
    # options.config.packageLists["official"] = PackageList(name: "Official", urls: @[
    #   "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
    #   "https://nim-lang.org/nimble/packages.json"
    # ])

    
    # let pkgInfo = downloadPkInfoForPv(pv, options)
    # var root = pkgInfo.getMinimalInfo()
    # root.isRoot = true
    # var pkgVersionTable = 
    #   { pkgName: PackageVersions(pkgName: pkgName, versions: @[root])}.toTable()
    # collectAllVersions(pkgVersionTable, pkgInfo, options)

    # let json = pkgVersionTable.toJson()
    # writeFile("langserverPgkVersionTable.json", json.pretty())

    let file = readFile("langserverPgkVersionTable.json")
    let pkgVersionTable = parseJson(file).to(Table[string, PackageVersions])

    var graph = pkgVersionTable.toDepGraph()
    let form = graph.toFormular()
    var packages = initTable[string, Version]()
    solve(graph, form, packages, listVersions= true)
    echo "Packages ", packages
    