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
                             level: int = 1) =
  # [fgRed, fgYellow, fgBlue, fgWhite, fgCyan, fgGreen]
  if level == 1:
    stdout.styledWrite("\n")
    stdout.styledWriteLine(
      fgGreen, styleBright, pkgInfo.basicInfo.name,
      " ",
      fgCyan, $pkgInfo.basicInfo.version
    )
  for (name, ver) in pkgInfo.requires:
    var depPkgInfo = initPackageInfo()
    let
      found = dependencies.findPkg((name, ver), depPkgInfo)
      packageName = if found: depPkgInfo.basicInfo.name else: name

    stdout.styledWriteLine(
      " ".repeat(level * 2),
      fgCyan, styleBright,
      packageName,
      resetStyle, fgGreen,
      if found: fmt " {depPkgInfo.basicInfo.version}" else: "",
      resetStyle, fgBlue, 
      " ",
      resetStyle, fgYellow,
      "(requires ", if ver.kind == verAny: "@any" else: $ver, ")",
      fgRed, styleBright,
      if errors.contains(packageName):
        " - error: " & getValidationErrorMessage(packageName, errors.getOrDefault packageName)
      else:
        ""
    )
    if found:
      printDepsHumanReadable(depPkgInfo, dependencies, errors, level + 1)
