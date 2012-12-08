import parsecfg, json, streams, strutils, parseutils
import version
type
  TPackageInfo* = object
    name*: string
    version*: string
    author*: string
    description*: string
    license*: string
    skipDirs*: seq[string]
    skipFiles*: seq[string]
    requires*: seq[tuple[name: string, ver: PVersionRange]]

  TPackage* = object
    name*: string
    version*: string
    license*: string
    url*: string
    dvcsTag*: string
    downloadMethod*: string
    tags*: seq[string]
    description*: string

proc initPackageInfo(): TPackageInfo =
  result.name = ""
  result.version = ""
  result.author = ""
  result.description = ""
  result.license = ""
  result.skipDirs = @[]
  result.skipFiles = @[]
  result.requires = @[]

proc validatePackageInfo(pkgInfo: TPackageInfo, path: string) =
  if pkgInfo.name == "":
    quit("Incorrect .babel file: " & path & " does not contain a name field.")
  if pkgInfo.version == "":
    quit("Incorrect .babel file: " & path & " does not contain a version field.")
  if pkgInfo.author == "":
    quit("Incorrect .babel file: " & path & " does not contain an author field.")
  if pkgInfo.description == "":
    quit("Incorrect .babel file: " & path & " does not contain a description field.")
  if pkgInfo.license == "":
    quit("Incorrect .babel file: " & path & " does not contain a license field.")

proc parseRequires(req: string): tuple[name: string, ver: PVersionRange] =
  try:
    var i = skipUntil(req, whitespace)
    result.name = req[0 .. i]
    result.ver = parseVersionRange(req[i .. -1])
  except EParseVersion:
    quit("Unable to parse dependency version range: " & getCurrentExceptionMsg())

proc readPackageInfo*(path: string): TPackageInfo =
  result = initPackageInfo()
  var fs = newFileStream(path, fmRead)
  if fs != nil:
    var p: TCfgParser
    open(p, fs, path)
    var currentSection = ""
    while true:
      var ev = next(p)
      case ev.kind
      of cfgEof:
        break
      of cfgSectionStart:
        currentSection = ev.section
      of cfgKeyValuePair:
        case currentSection.normalize
        of "package":
          case ev.key.normalize
          of "name": result.name = ev.value
          of "version": result.version = ev.value
          of "author": result.author = ev.value
          of "description": result.description = ev.value
          of "license": result.license = ev.value
          of "skipdirs":
            result.skipDirs.add(ev.value.split(','))
          of "skipfiles":
            result.skipFiles.add(ev.value.split(','))
          else:
            quit("Invalid field: " & ev.key, QuitFailure)
        of "deps", "dependencies":
          case ev.key.normalize
          of "requires":
            result.requires.add(parseRequires(ev.value))
          else:
            quit("Invalid field: " & ev.key, QuitFailure)
        else: quit("Invalid section: " & currentSection, QuitFailure)
      of cfgOption: quit("Invalid package info, should not contain --" & ev.value, QuitFailure)
      of cfgError:
        echo(ev.msg)
    close(p)
  else:
    quit("Cannot open package info: " & path, QuitFailure)
  validatePackageInfo(result, path)

proc optionalField(obj: PJsonNode, name: string): string =
  if existsKey(obj, name):
    if obj[name].kind == JString:
      return obj[name].str
    else:
      quit("Corrupted packages.json file. " & name & " field is of unexpected type.")
  else: return ""

proc requiredField(obj: PJsonNode, name: string): string =
  if existsKey(obj, name):
    if obj[name].kind == JString:
      return obj[name].str
    else:
      quit("Corrupted packages.json file. " & name & " field is of unexpected type.")
  else:
    quit("Package in packages.json file does not contain a " & name & " field.")

proc getPackage*(pkg: string, packagesPath: string, resPkg: var TPackage): bool =
  let packages = parseFile(packagesPath)
  for p in packages:
    if p["name"].str != pkg: continue
    resPkg.name = pkg
    resPkg.url = p.requiredField("url")
    resPkg.version = p.optionalField("version")
    resPkg.downloadMethod = p.requiredField("method")
    resPkg.dvcsTag = p.optionalField("dvcs-tag")
    resPkg.license = p.requiredField("license")
    resPkg.tags = @[]
    for t in p["tags"]:
      resPkg.tags.add(t.str)
    resPkg.description = p.requiredField("description")
    return true
  return false
  
proc getPackageList*(packagesPath: string): seq[TPackage] =
  result = @[]
  let packages = parseFile(packagesPath)
  for p in packages:
    var pkg: TPackage
    pkg.name = p.requiredField("name")
    pkg.version = p.optionalField("version")
    pkg.url = p.requiredField("url")
    pkg.downloadMethod = p.requiredField("method")
    pkg.dvcsTag = p.optionalField("dvcs-tag")
    pkg.license = p.requiredField("license")
    pkg.tags = @[]
    for t in p["tags"]:
      pkg.tags.add(t.str)
    pkg.description = p.requiredField("description")
    result.add(pkg)

proc echoPackage*(pkg: TPackage) =
  echo(pkg.name & ":")
  if pkg.version != "":
    echo("  version:     " & pkg.version)
  else:
    echo("  version:     HEAD")
  echo("  url:         " & pkg.url & " (" & pkg.downloadMethod & ")")
  echo("  tags:        " & pkg.tags.join(", "))
  echo("  description: " & pkg.description)
  echo("  license:     " & pkg.license)
  if pkg.dvcsTag != "":
    echo("    dvcs-tag:  " & pkg.dvcsTag)
  
