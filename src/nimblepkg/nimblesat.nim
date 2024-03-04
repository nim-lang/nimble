import std/tables
import sat, satvars #Notice this two files eventually will be a package. They are copied (untouch) from atlas
import version, packageinfotypes

type  
  SatVarInfo* = object # attached information for a SAT variable
    pkg: string
    version: Version
    index: int

  Form* = object
    f*: Formular
    mapping: Table[VarId, SatVarInfo]
    idgen: int32

proc toFormular*(requirements: seq[PkgTuple], allPackages: seq[PackageBasicInfo]): Form =
  var b = Builder()
  var idgen: int32 = 0
  var mapping = initTable[VarId, SatVarInfo]()
  b.openOpr(AndForm)

  for (pkgName, constraint) in requirements:
    b.openOpr(ExactlyOneOfForm)
    for pkg in allPackages:
      if pkg.name != pkgName: continue
      if pkg.version.withinRange(constraint):
        let vid = VarId(idgen)
        b.add(newVar(vid))
        mapping[vid] = SatVarInfo(pkg: pkgName, version: pkg.version, index: idgen)
        inc idgen
    b.closeOpr()  

  b.closeOpr()
  Form(f: b.toForm(), mapping: mapping, idgen: idgen)

proc getPackageVersions*(form: Form, s: var Solution): Table[string, Version] =
  let m = maxVariable(form.f)
  result = initTable[string, Version]()
  for i in 0..<m:
    let varId = VarId(i)
    if isTrue(s, varId):
      if varId in form.mapping:
        let info = form.mapping[varId]
        result[info.pkg] = info.version

proc areRequirementsWithinPackages*(requirements: seq[PkgTuple], allPackages: seq[PackageBasicInfo]): bool = 
  var found = 0
  for (pkgName, constraint) in requirements:
    for pgk in allPackages:
      if pkgName == pgk.name and pgk.version.withinRange(constraint):
        inc found
        break
  found == requirements.len
      
