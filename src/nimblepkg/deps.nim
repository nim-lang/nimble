import tables, strformat, strutils, terminal, cli
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
                             levelInfos: seq[tuple[skip: bool]] = @[]
                             ) =
  ## print human readable tree deps
  ## 
  if levelInfos.len() == 0:
    displayFormatted(Hint, "\n")
    displayFormatted(Message, pkgInfo.basicInfo.name, " ")
    displayFormatted(Success, "(@", $pkgInfo.basicInfo.version, ")")

  for idx, (name, ver) in pkgInfo.requires:
    var depPkgInfo = initPackageInfo()
    let
      isLast = idx == pkgInfo.requires.len() - 1
      found = dependencies.findPkg((name, ver), depPkgInfo)
      packageName = if found: depPkgInfo.basicInfo.name else: name

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
      printDepsHumanReadable(depPkgInfo, dependencies, errors, levelInfos)
  if levelInfos.len() == 0:
    displayFormatted(Hint, "\n")

