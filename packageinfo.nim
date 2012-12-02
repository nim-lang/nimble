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
    url*: string
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

proc getPackage*(pkg: string, packagesPath: string, resPkg: var TPackage): bool =
  let packages = parseFile(packagesPath)
  for p in packages:
    if p["name"].str != pkg: continue
    resPkg.name = pkg
    resPkg.url = p["url"].str
    resPkg.downloadMethod = p["method"].str
    resPkg.tags = @[]
    for t in p["tags"]:
      resPkg.tags.add(t.str)
    resPkg.description = p["description"].str
    return true
  return false
  
proc getPackageList*(packagesPath: string): seq[TPackage] =
  result = @[]
  let packages = parseFile(packagesPath)
  for p in packages:
    var pkg: TPackage
    pkg.name = p["name"].str
    pkg.url = p["url"].str
    pkg.downloadMethod = p["method"].str
    pkg.tags = @[]
    for t in p["tags"]:
      pkg.tags.add(t.str)
    pkg.description = p["description"].str
    result.add(pkg)

proc echoPackage*(pkg: TPackage) =
  echo(pkg.name & ":")
  echo("  url:         " & pkg.url & " (" & pkg.downloadMethod & ")")
  echo("  tags:        " & pkg.tags.join(", "))
  echo("  description: " & pkg.description)
