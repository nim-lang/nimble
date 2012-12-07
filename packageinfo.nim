import parsecfg, json, streams, strutils
type
  TPackageInfo* = object
    name*: string
    version*: string
    author*: string
    description*: string
    library*: bool
    skipDirs*: seq[string]
    skipFiles*: seq[string]

  TPackage* = object
    name*: string
    version*: string
    url*: string
    dvcsTag*: string
    downloadMethod*: string
    tags*: seq[string]
    description*: string

proc readPackageInfo*(path: string): TPackageInfo =
  result.skipDirs = @[]
  result.skipFiles = @[]
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
        of "library":
          case ev.key.normalize
          of "skipdirs":
            result.skipDirs.add(ev.value.split(','))
          of "skipfiles":
            result.skipFiles.add(ev.value.split(','))
        else: quit("Invalid section: " & currentSection, QuitFailure)
      of cfgOption: quit("Invalid package info, should not contain --" & ev.value, QuitFailure)
      of cfgError:
        echo(ev.msg)
    close(p)
  else:
    quit("Cannot open package info: " & path, QuitFailure)

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
    pkg.tags = @[]
    for t in p["tags"]:
      pkg.tags.add(t.str)
    pkg.description = p.requiredField("description")
    result.add(pkg)

proc echoPackage*(pkg: TPackage) =
  echo(pkg.name & ":")
  echo("  url:         " & pkg.url & " (" & pkg.downloadMethod & ")")
  echo("  tags:        " & pkg.tags.join(", "))
  echo("  description: " & pkg.description)
