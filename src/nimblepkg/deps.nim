import tables, strformat, sequtils, algorithm, cli
import packageinfotypes, developfile, packageinfo, version

type
  DependencyNode = ref object of RootObj
    name*: string
    version*: string
    resolvedTo*: string
    error*: string
    dependencies*: seq[DependencyNode]

proc depsRecursive*(pkgInfo: PackageInfo,
                    dependencies: seq[PackageInfo],
                    errors: ValidationErrors): seq[DependencyNode] =
  result = @[]

  for (name, ver) in pkgInfo.fullRequirements:
    var depPkgInfo = initPackageInfo()
    let
      found = dependencies.findPkg((name, ver), depPkgInfo)
      packageName = if found: depPkgInfo.basicInfo.name else: name

    let node = DependencyNode(name: packageName)

    result.add node
    node.version = if ver.kind == verAny: "@any" else: $ver
    node.resolvedTo = if found: $depPkgInfo.basicInfo.version else: ""
    node.error = if errors.contains(packageName):
      getValidationErrorMessage(packageName, errors.getOrDefault packageName)
    else: ""

    if found:
      node.dependencies = depsRecursive(depPkgInfo, dependencies, errors)

proc printDepsHumanReadable*(pkgInfo: PackageInfo,
                             dependencies: seq[PackageInfo],
                             errors: ValidationErrors,
                             directOnly = false,
                             levelInfos: seq[tuple[skip: bool]] = @[],
                             ) =
  ## print human readable tree deps
  ## 
  if levelInfos.len() == 0:
    displayLineReset()
    displayInfo("Dependency tree format: {PackageName} {Requirements} (@{Resolved Version})")
    displayFormatted(Hint, "\n")
    displayFormatted(Message, pkgInfo.basicInfo.name, " ")
    displayFormatted(Success, "(@", $pkgInfo.basicInfo.version, ")")

  var requires: seq[(string, VersionRange, bool, PackageInfo)]
  for idx, (name, ver) in pkgInfo.requires.sorted():
    var depPkgInfo = initPackageInfo()
    let
      found = dependencies.findPkg((name, ver), depPkgInfo)
      packageName = if found: depPkgInfo.basicInfo.name else: name
    requires.add((packageName, ver, found, depPkgInfo))

  proc reqCmp[T](x, y: T): int = cmp(x[0], y[0])
  requires.sort(reqCmp)

  for idx, (packageName, ver, found, depPkgInfo) in requires:
    let
      isLast = idx == pkgInfo.requires.len() - 1

    displayFormatted(Hint, "\n")
    for levelInfo in levelInfos:
      if levelInfo.skip:
        displayFormatted(Hint, "    ")
      else:
        displayFormatted(Hint, "│   ")
    if not isLast:
      displayFormatted(Hint, "├── ")
    else:
      displayFormatted(Hint, "└── ")
    displayFormatted(Message, packageName)
    displayFormatted(Hint, " ")
    displayFormatted(Warning, if ver.kind == verAny: "@any" else: $ver)
    displayFormatted(Hint, " ")
    if found:
      displayFormatted(Success, fmt"(@{depPkgInfo.basicInfo.version})")
    if errors.contains(packageName):
      let errMsg = getValidationErrorMessage(packageName, errors.getOrDefault packageName)
      displayFormatted(Error, fmt" - error: {errMsg}")
    if found:
      var levelInfos = levelInfos & @[(skip: isLast)]
      if not directOnly:
        printDepsHumanReadable(depPkgInfo, dependencies, errors, directOnly, levelInfos)
  if levelInfos.len() == 0:
    displayFormatted(Hint, "\n")

proc printDepsHumanReadableInverted*(pkgInfo: PackageInfo,
                             dependencies: seq[PackageInfo],
                             errors: ValidationErrors,
                             pkgs = newTable[string, TableRef[string, VersionRange]](),
                             ) =
  ## print human readable tree deps
  ## 
  let
    parent = pkgInfo.basicInfo.name
    isRoot = pkgs.len() == 0

  if isRoot:
    displayInfo("Dependency tree format: {PackageName} (@{Resolved Version})")
    displayInfo("Dependency tree format:    {Source Package} {Source Requirements}")
    displayFormatted(Hint, "\n")
    displayFormatted(Message, pkgInfo.basicInfo.name, " ")
    displayFormatted(Success, "(@", $pkgInfo.basicInfo.version, ")")
    displayFormatted(Hint, "\n")

  for (name, ver) in pkgInfo.requires:
    var depPkgInfo = initPackageInfo()
    let
      found = dependencies.findPkg((name, ver), depPkgInfo)
      packageName = if found: depPkgInfo.basicInfo.name else: name

    pkgs.mgetOrPut(packageName, newTable[string, VersionRange]())[parent] = ver

    if found:
      printDepsHumanReadableInverted(depPkgInfo, dependencies, errors, pkgs)

  if isRoot:
    # for pkg, info in pkgs:
    for idx, name in pkgs.keys().toSeq().sorted():
      let
        info = pkgs[name]
        isOuterLast = idx == pkgs.len() - 1
      if not isOuterLast:
        displayFormatted(Hint, "├── ")
      else:
        displayFormatted(Hint, "└── ")
      displayFormatted(Message, name, " ")
      displayFormatted(Success, "(@", $pkgInfo.basicInfo.version, ")")
      displayFormatted(Hint, "\n")
      # echo "name: ", pkg, " info: ", $info
      # for idx, (source, ver) in info.pairs().toSeq():
      proc printOuter() =
        if not isOuterLast:
          displayFormatted(Hint, "│   ")
        else:
          displayFormatted(Hint, "    ")
      for idx, source in info.keys().toSeq().sorted():
        let
          ver = info[source]
          isLast = idx == info.len() - 1

        if not isLast:
          printOuter()
          displayFormatted(Hint, "╟── ")
        else:
          printOuter()
          displayFormatted(Hint, "╙── ")
        displayFormatted(Warning, if ver.kind == verAny: "@any" else: $ver)
        displayFormatted(Hint, " ")
        displayFormatted(Message, source)
        displayFormatted(Hint, "\n")
    displayFormatted(Hint, "\n")

