# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
import parsecfg, json, streams, strutils, parseutils, os
import version, common
type
  TPackageInfo* = object
    mypath*: string ## The path of this .babel file
    name*: string
    version*: string
    author*: string
    description*: string
    license*: string
    skipDirs*: seq[string]
    skipFiles*: seq[string]
    skipExt*: seq[string]
    installDirs*: seq[string]
    installFiles*: seq[string]
    installExt*: seq[string]
    requires*: seq[tuple[name: string, ver: PVersionRange]]
    bin*: seq[string]
    srcDir*: string
    backend*: string

  TPackage* = object
    # Required fields in a package.
    name*: string
    url*: string # Download location.
    license*: string
    downloadMethod*: string
    description*: string
    tags*: seq[string] # Even if empty, always a valid non nil seq. \
    # From here on, optional fields set to the emtpy string if not available.
    version*: string
    dvcsTag*: string
    web*: string # Info url for humans.

  TMetadata* = object
    url*: string

proc initPackageInfo(): TPackageInfo =
  result.mypath = ""
  result.name = ""
  result.version = ""
  result.author = ""
  result.description = ""
  result.license = ""
  result.skipDirs = @[]
  result.skipFiles = @[]
  result.skipExt = @[]
  result.installDirs = @[]
  result.installFiles = @[]
  result.installExt = @[]
  result.requires = @[]
  result.bin = @[]
  result.srcDir = ""
  result.backend = "c"

proc validatePackageInfo(pkgInfo: TPackageInfo, path: string) =
  if pkgInfo.name == "":
    raise newException(EBabel, "Incorrect .babel file: " & path &
                       " does not contain a name field.")
  if pkgInfo.version == "":
    raise newException(EBabel, "Incorrect .babel file: " & path &
                       " does not contain a version field.")
  if pkgInfo.author == "":
    raise newException(EBabel, "Incorrect .babel file: " & path &
                       " does not contain an author field.")
  if pkgInfo.description == "":
    raise newException(EBabel, "Incorrect .babel file: " & path &
                       " does not contain a description field.")
  if pkgInfo.license == "":
    raise newException(EBabel, "Incorrect .babel file: " & path &
                       " does not contain a license field.")
  if pkgInfo.backend notin ["c", "cc", "objc", "cpp", "js"]:
    raise newException(EBabel, "'" & pkgInfo.backend & "' is an invalid backend.")
  for c in pkgInfo.version:
    if c notin ({'.'} + digits):
      raise newException(EBabel,
          "Version may only consist of numbers and the '.' character " &
          "but found '" & c & "'.")

proc parseRequires(req: string): tuple[name: string, ver: PVersionRange] =
  try:
    if ' ' in req:
      var i = skipUntil(req, whitespace)
      result.name = req[0 .. i].strip
      result.ver = parseVersionRange(req[i .. -1])
    elif '#' in req:
      var i = skipUntil(req, {'#'})
      result.name = req[0 .. i-1]
      result.ver = parseVersionRange(req[i .. -1])
    else:
      result.name = req.strip
      result.ver = PVersionRange(kind: verAny)
  except EParseVersion:
    raise newException(EBabel, "Unable to parse dependency version range: " &
                               getCurrentExceptionMsg())

proc multiSplit(s: string): seq[string] =
  ## Returns ``s`` split by newline and comma characters.
  ##
  ## Before returning, all individual entries are stripped of whitespace and
  ## also empty entries are purged from the list. If after all the cleanups are
  ## done no entries are found in the list, the proc returns a sequence with
  ## the original string as the only entry.
  result = split(s, {char(0x0A), char(0x0D), ','})
  map(result, proc(x: var string) = x = x.strip())
  for i in countdown(result.len()-1, 0):
    if len(result[i]) < 1:
      result.del(i)
  # Huh, nothing to return? Return given input.
  if len(result) < 1:
    return @[s]

proc readPackageInfo*(path: string): TPackageInfo =
  result = initPackageInfo()
  result.mypath = path
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
          of "srcdir": result.srcDir = ev.value
          of "skipdirs":
            result.skipDirs.add(ev.value.multiSplit)
          of "skipfiles":
            result.skipFiles.add(ev.value.multiSplit)
          of "skipext":
            result.skipExt.add(ev.value.multiSplit)
          of "installdirs":
            result.installDirs.add(ev.value.multiSplit)
          of "installfiles":
            result.installFiles.add(ev.value.multiSplit)
          of "installext":
            result.installExt.add(ev.value.multiSplit)
          of "bin":
            for i in ev.value.multiSplit:
              result.bin.add(i.addFileExt(ExeExt))
          of "backend":
            result.backend = ev.value.toLower()
            case result.backend.normalize
            of "javascript": result.backend = "js"
          else:
            raise newException(EBabel, "Invalid field: " & ev.key)
        of "deps", "dependencies":
          case ev.key.normalize
          of "requires":
            for v in ev.value.multiSplit:
              result.requires.add(parseRequires(v.strip))
          else:
            raise newException(EBabel, "Invalid field: " & ev.key)
        else: raise newException(EBabel, "Invalid section: " & currentSection)
      of cfgOption: raise newException(EBabel, "Invalid package info, should not contain --" & ev.value)
      of cfgError:
        raise newException(EBabel, "Error parsing .babel file: " & ev.msg)
    close(p)
  else:
    raise newException(EInvalidValue, "Cannot open package info: " & path)
  validatePackageInfo(result, path)

proc optionalField(obj: PJsonNode, name: string, default = ""): string =
  ## Queries ``obj`` for the optional ``name`` string.
  ##
  ## Returns the value of ``name`` if it is a valid string, or aborts execution
  ## if the field exists but is not of string type. If ``name`` is not present,
  ## returns ``default``.
  if existsKey(obj, name):
    if obj[name].kind == JString:
      return obj[name].str
    else:
      raise newException(EBabel, "Corrupted packages.json file. " & name & " field is of unexpected type.")
  else: return default

proc requiredField(obj: PJsonNode, name: string): string =
  ## Queries ``obj`` for the required ``name`` string.
  ##
  ## Aborts execution if the field does not exist or is of invalid json type.
  result = optionalField(obj, name, nil)
  if result == nil:
    raise newException(EBabel, 
        "Package in packages.json file does not contain a " & name & " field.")

proc fromJson(obj: PJSonNode): TPackage =
  ## Constructs a TPackage object from a JSON node.
  ##
  ## Aborts execution if the JSON node doesn't contain the required fields.
  result.name = obj.requiredField("name")
  result.version = obj.optionalField("version")
  result.url = obj.requiredField("url")
  result.downloadMethod = obj.requiredField("method")
  result.dvcsTag = obj.optionalField("dvcs-tag")
  result.license = obj.requiredField("license")
  result.tags = @[]
  for t in obj["tags"]:
    result.tags.add(t.str)
  result.description = obj.requiredField("description")
  result.web = obj.optionalField("web")

proc readMetadata*(path: string): TMetadata =
  ## Reads the metadata present in ``~/.babel/pkgs/pkg-0.1/babelmeta.json``
  let bmeta = path / "babelmeta.json"
  if not existsFile(bmeta):
    result.url = ""
    echo("WARNING: No babelmeta.json file found in " & path)
    return
    # TODO: Make this an error.
  let cont = readFile(path / "babelmeta.json")
  let jsonmeta = parseJson(cont)
  result.url = jsonmeta["url"].str

proc getPackage*(pkg: string, packagesPath: string, resPkg: var TPackage): bool =
  ## Searches ``packagesPath`` file saving into ``resPkg`` the found package.
  ##
  ## Pass in ``pkg`` the name of the package you are searching for. As
  ## convenience the proc returns a boolean specifying if the ``resPkg`` was
  ## successfully filled with good data.
  let packages = parseFile(packagesPath)
  for p in packages:
    if p["name"].str == pkg:
      resPkg = p.fromJson()
      return true

proc getPackageList*(packagesPath: string): seq[TPackage] =
  ## Returns the list of packages found at the specified path.
  result = @[]
  let packages = parseFile(packagesPath)
  for p in packages:
    let pkg: TPackage = p.fromJson()
    result.add(pkg)

proc findBabelFile*(dir: string): string =
  result = ""
  for kind, path in walkDir(dir):
    if kind == pcFile and path.splitFile.ext == ".babel":
      if result != "":
        raise newException(EBabel, "Only one .babel file should be present in " & dir)
      result = path

proc getPkgInfo*(dir: string): TPackageInfo =
  ## Find the .babel file in ``dir`` and parses it, returning a TPackageInfo.
  let babelFile = findBabelFile(dir)
  if babelFile == "":
    raise newException(EBabel, "Specified directory does not contain a .babel file.")
  result = readPackageInfo(babelFile)

proc getInstalledPkgs*(libsDir: string): seq[tuple[pkginfo: TPackageInfo, meta: TMetaData]] =
  ## Gets a list of installed packages.
  ##
  ## ``libsDir`` is in most cases: ~/.babel/pkgs/
  result = @[]
  for kind, path in walkDir(libsDir):
    if kind == pcDir:
      let babelFile = findBabelFile(path)
      if babelFile != "":
        let meta = readMetadata(path)
        result.add((readPackageInfo(babelFile), meta))
      else:
        # TODO: Abstract logging.
        echo("WARNING: No .babel file found for ", path)

proc findPkg*(pkglist: seq[tuple[pkginfo: TPackageInfo, meta: TMetaData]],
             dep: tuple[name: string, ver: PVersionRange],
             r: var TPackageInfo): bool =
  ## Searches ``pkglist`` for a package of which version is within the range
  ## of ``dep.ver``. ``True`` is returned if a package is found. If multiple
  ## packages are found the newest one is returned (the one with the highest
  ## version number)
  for pkg in pkglist:
    if pkg.pkginfo.name != dep.name and pkg.meta.url != dep.name: continue
    if withinRange(newVersion(pkg.pkginfo.version), dep.ver):
      if not result or newVersion(r.version) < newVersion(pkg.pkginfo.version):
        r = pkg.pkginfo
        result = true

proc getRealDir*(pkgInfo: TPackageInfo): string =
  ## Returns the ``pkgInfo.srcDir`` or the .mypath directory if package does
  ## not specify the src dir.
  if pkgInfo.srcDir != "":
    result = pkgInfo.mypath.splitFile.dir / pkgInfo.srcDir
  else:
    result = pkgInfo.mypath.splitFile.dir

proc getNameVersion*(pkgpath: string): tuple[name, version: string] =
  ## Splits ``pkgpath`` in the format ``/home/user/.babel/pkgs/package-0.1``
  ## into ``(packagea, 0.1)``
  result.name = ""
  result.version = ""
  let tail = pkgpath.splitPath.tail
  if '-' notin tail:
    result.name = tail
    return
  
  for i in countdown(tail.len-1, 0):
    if tail[i] == '-':
      result.name = tail[0 .. i-1]
      result.version = tail[i+1 .. -1]
      break

proc echoPackage*(pkg: TPackage) =
  echo(pkg.name & ":")
  echo("  url:         " & pkg.url & " (" & pkg.downloadMethod & ")")
  echo("  tags:        " & pkg.tags.join(", "))
  echo("  description: " & pkg.description)
  echo("  license:     " & pkg.license)
  if pkg.web.len > 0:
    echo("  website:     " & pkg.web)

when isMainModule:
  doAssert getNameVersion("/home/user/.babel/libs/packagea-0.1") == ("packagea", "0.1")
  doAssert getNameVersion("/home/user/.babel/libs/package-a-0.1") == ("package-a", "0.1")