# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
import parsecfg, json, streams, strutils, parseutils, os
import version, tools, nimbletypes, nimscriptsupport

when not declared(system.map):
  from sequtils import map

type
  Package* = object
    # Required fields in a package.
    name*: string
    url*: string # Download location.
    license*: string
    downloadMethod*: string
    description*: string
    tags*: seq[string] # Even if empty, always a valid non nil seq. \
    # From here on, optional fields set to the empty string if not available.
    version*: string
    dvcsTag*: string
    web*: string # Info url for humans.

  MetaData* = object
    url*: string

  NimbleFile* = string

  ValidationError* = object of NimbleError
    warnInstalled*: bool # Determines whether to show a warning for installed pkgs

proc initPackageInfo(path: string): PackageInfo =
  result.mypath = path
  # reasonable default:
  result.name = path.splitFile.name
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
  result.binDir = ""
  result.backend = "c"

proc newValidationError(msg: string, warnInstalled: bool): ref ValidationError =
  result = newException(ValidationError, msg)
  result.warnInstalled = warnInstalled

proc validatePackageName*(name: string) =
  ## Raises an error if specified package name contains invalid characters.
  ##
  ## A valid package name is one which is a valid nim module name. So only
  ## underscores, letters and numbers allowed.
  if name.len == 0: return

  if name[0] in {'0'..'9'}:
    raise newValidationError(name &
        "\"$1\" is an invalid package name: cannot begin with $2" %
        [name, $name[0]], true)

  var prevWasUnderscore = false
  for c in name:
    case c
    of '_':
      if prevWasUnderscore:
        raise newValidationError(
            "$1 is an invalid package name: cannot contain \"__\"" % name, true)
      prevWasUnderscore = true
    of AllChars - IdentChars:
      raise newValidationError(
          "$1 is an invalid package name: cannot contain '$2'" % [name, $c],
          true)
    else:
      prevWasUnderscore = false

proc toValidPackageName*(name: string): string =
  result = ""
  for c in name:
    case c
    of '_', '-':
      if result[^1] != '_': result.add('_')
    of AllChars - IdentChars - {'-'}: discard
    else: result.add(c)

proc validateVersion*(ver: string) =
  for c in ver:
    if c notin ({'.'} + Digits):
      raise newValidationError(
          "Version may only consist of numbers and the '.' character " &
          "but found '" & c & "'.", false)

proc validatePackageInfo(pkgInfo: PackageInfo, path: string) =
  if pkgInfo.name == "":
    raise newValidationError("Incorrect .nimble file: " & path &
        " does not contain a name field.", false)

  if pkgInfo.name.normalize != path.splitFile.name.normalize:
    raise newValidationError(
        "The .nimble file name must match name specified inside " & path, true)

  if pkgInfo.version == "":
    raise newValidationError("Incorrect .nimble file: " & path &
        " does not contain a version field.", false)

  if not pkgInfo.isMinimal:
    if pkgInfo.author == "":
      raise newValidationError("Incorrect .nimble file: " & path &
          " does not contain an author field.", false)
    if pkgInfo.description == "":
      raise newValidationError("Incorrect .nimble file: " & path &
          " does not contain a description field.", false)
    if pkgInfo.license == "":
      raise newValidationError("Incorrect .nimble file: " & path &
          " does not contain a license field.", false)
    if pkgInfo.backend notin ["c", "cc", "objc", "cpp", "js"]:
      raise newValidationError("'" & pkgInfo.backend &
          "' is an invalid backend.", false)

  validateVersion(pkgInfo.version)

proc nimScriptHint*(pkgInfo: PackageInfo) =
  if not pkgInfo.isNimScript:
    # TODO: Turn this into a warning.
    # TODO: Add a URL explaining more.
    echo("NOTE: The .nimble file for this project could make use of " &
         "additional features, if converted into the new NimScript format.")

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

proc readPackageInfoFromNimble(path: string; result: var PackageInfo) =
  var fs = newFileStream(path, fmRead)
  if fs != nil:
    var p: CfgParser
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
          of "bindir": result.binDir = ev.value
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
            else: discard
          else:
            raise newException(NimbleError, "Invalid field: " & ev.key)
        of "deps", "dependencies":
          case ev.key.normalize
          of "requires":
            for v in ev.value.multiSplit:
              result.requires.add(parseRequires(v.strip))
          else:
            raise newException(NimbleError, "Invalid field: " & ev.key)
        else: raise newException(NimbleError,
              "Invalid section: " & currentSection)
      of cfgOption: raise newException(NimbleError,
            "Invalid package info, should not contain --" & ev.value)
      of cfgError:
        raise newException(NimbleError, "Error parsing .nimble file: " & ev.msg)
    close(p)
  else:
    raise newException(ValueError, "Cannot open package info: " & path)

proc getNameVersion*(pkgpath: string): tuple[name, version: string] =
  ## Splits ``pkgpath`` in the format ``/home/user/.nimble/pkgs/package-0.1``
  ## into ``(packagea, 0.1)``
  ##
  ## Also works for file paths like:
  ##   ``/home/user/.nimble/pkgs/package-0.1/package.nimble``

  if pkgPath.splitFile.ext == ".nimble":
    return getNameVersion(pkgPath.splitPath.head)

  result.name = ""
  result.version = ""
  let tail = pkgpath.splitPath.tail
  if '-' notin tail:
    result.name = tail
    return

  for i in countdown(tail.len-1, 0):
    if tail[i] == '-':
      result.name = tail[0 .. i-1]
      result.version = tail[i+1 .. tail.len-1]
      break

proc readPackageInfo*(nf: NimbleFile; onlyMinimalInfo=false): PackageInfo =
  ## Reads package info from the specified Nimble file.
  ##
  ## Attempts to read it using the "old" Nimble ini format first, if that
  ## fails attempts to evaluate it as a nimscript file.
  ##
  ## If both fail then returns an error.
  ##
  ## When ``onlyMinimalInfo`` is true, only the `name` and `version` fields are
  ## populated. The isNimScript field can also be relied on.
  result = initPackageInfo(nf)

  validatePackageName(nf.splitFile.name)

  var success = false
  var iniError: ref NimbleError
  # Attempt ini-format first.
  try:
    readPackageInfoFromNimble(nf, result)
    success = true
    result.isNimScript = false
  except NimbleError:
    iniError = (ref NimbleError)(getCurrentException())

  if not success:
    if onlyMinimalInfo:
      let tmp = getNameVersion(nf)
      result.name = tmp.name
      result.version = tmp.version
      result.isNimScript = true
      result.isMinimal = true
    else:
      try:
        readPackageInfoFromNims(nf, result)
        result.isNimScript = true
      except NimbleError:
        let msg = "Could not read package info file in " & nf & ";\n" &
                  "  Reading as ini file failed with: \n" &
                  "    " & iniError.msg & ".\n" &
                  "  Evaluating as NimScript file failed with: \n" &
                  "    " & getCurrentExceptionMsg() & "."
        raise newException(NimbleError, msg)

  validatePackageInfo(result, nf)

proc optionalField(obj: JsonNode, name: string, default = ""): string =
  ## Queries ``obj`` for the optional ``name`` string.
  ##
  ## Returns the value of ``name`` if it is a valid string, or aborts execution
  ## if the field exists but is not of string type. If ``name`` is not present,
  ## returns ``default``.
  if hasKey(obj, name):
    if obj[name].kind == JString:
      return obj[name].str
    else:
      raise newException(NimbleError, "Corrupted packages.json file. " & name &
          " field is of unexpected type.")
  else: return default

proc requiredField(obj: JsonNode, name: string): string =
  ## Queries ``obj`` for the required ``name`` string.
  ##
  ## Aborts execution if the field does not exist or is of invalid json type.
  result = optionalField(obj, name, nil)
  if result == nil:
    raise newException(NimbleError,
        "Package in packages.json file does not contain a " & name & " field.")

proc fromJson(obj: JSonNode): Package =
  ## Constructs a Package object from a JSON node.
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

proc readMetaData*(path: string): MetaData =
  ## Reads the metadata present in ``~/.nimble/pkgs/pkg-0.1/nimblemeta.json``
  var bmeta = path / "nimblemeta.json"
  if not existsFile(bmeta):
    bmeta = path / "babelmeta.json"
    if existsFile(bmeta):
      echo("WARNING: using deprecated babelmeta.json file in " & path)
  if not existsFile(bmeta):
    result.url = ""
    echo("WARNING: No nimblemeta.json file found in " & path)
    return
    # TODO: Make this an error.
  let cont = readFile(bmeta)
  let jsonmeta = parseJson(cont)
  result.url = jsonmeta["url"].str

proc getPackage*(pkg: string, packagesPath: string, resPkg: var Package): bool =
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

proc getPackageList*(packagesPath: string): seq[Package] =
  ## Returns the list of packages found at the specified path.
  result = @[]
  let packages = parseFile(packagesPath)
  for p in packages:
    let pkg: Package = p.fromJson()
    result.add(pkg)

proc findNimbleFile*(dir: string; error: bool): NimbleFile =
  result = ""
  var hits = 0
  for kind, path in walkDir(dir):
    if kind == pcFile:
      let ext = path.splitFile.ext
      case ext
      of ".babel", ".nimble":
        result = path
        inc hits
      else: discard
  if hits >= 2:
    raise newException(NimbleError,
        "Only one .nimble file should be present in " & dir)
  elif hits == 0:
    if error:
      raise newException(NimbleError,
          "Specified directory does not contain a .nimble file.")
    else:
      # TODO: Abstract logging.
      echo("WARNING: No .nimble file found for ", dir)

proc getPkgInfo*(dir: string): PackageInfo =
  ## Find the .nimble file in ``dir`` and parses it, returning a PackageInfo.
  let nimbleFile = findNimbleFile(dir, true)
  result = readPackageInfo(nimbleFile)

proc getInstalledPkgs*(libsDir: string):
        seq[tuple[pkginfo: PackageInfo, meta: MetaData]] =
  ## Gets a list of installed packages.
  ##
  ## ``libsDir`` is in most cases: ~/.nimble/pkgs/
  result = @[]
  for kind, path in walkDir(libsDir):
    if kind == pcDir:
      let nimbleFile = findNimbleFile(path, false)
      if nimbleFile != "":
        let meta = readMetaData(path)
        try:
          result.add((readPackageInfo(nimbleFile, true), meta))
        except ValidationError:
          let exc = (ref ValidationError)(getCurrentException())
          if exc.warnInstalled:
            echo("WARNING: Unable to read package info for " & path & "\n" &
                "  Package did not pass validation: " & exc.msg)
          else:
            exc.msg = "Unable to read package info for " & path & "\n" &
                "  Package did not pass validation: " & exc.msg
            raise exc
        except:
          let exc = getCurrentException()
          exc.msg = "Unable to read package info for " & path & "\n" &
              "  Error: " & exc.msg
          raise exc


proc findPkg*(pkglist: seq[tuple[pkginfo: PackageInfo, meta: MetaData]],
             dep: PkgTuple,
             r: var PackageInfo): bool =
  ## Searches ``pkglist`` for a package of which version is within the range
  ## of ``dep.ver``. ``True`` is returned if a package is found. If multiple
  ## packages are found the newest one is returned (the one with the highest
  ## version number)
  ##
  ## **Note**: dep.name here could be a URL, hence the need for pkglist.meta.
  for pkg in pkglist:
    if cmpIgnoreStyle(pkg.pkginfo.name, dep.name) != 0 and
       cmpIgnoreStyle(pkg.meta.url, dep.name) != 0: continue
    if withinRange(newVersion(pkg.pkginfo.version), dep.ver):
      if not result or newVersion(r.version) < newVersion(pkg.pkginfo.version):
        r = pkg.pkginfo
        result = true

proc findAllPkgs*(pkglist: seq[tuple[pkginfo: PackageInfo, meta: MetaData]],
                  dep: PkgTuple): seq[PackageInfo] =
  ## Searches ``pkglist`` for packages of which version is within the range
  ## of ``dep.ver``. This is similar to ``findPkg`` but returns multiple
  ## packages if multiple are found.
  result = @[]
  for pkg in pkglist:
    if cmpIgnoreStyle(pkg.pkginfo.name, dep.name) != 0 and
       cmpIgnoreStyle(pkg.meta.url, dep.name) != 0: continue
    if withinRange(newVersion(pkg.pkginfo.version), dep.ver):
      result.add pkg.pkginfo

proc getRealDir*(pkgInfo: PackageInfo): string =
  ## Returns the ``pkgInfo.srcDir`` or the .mypath directory if package does
  ## not specify the src dir.
  if pkgInfo.srcDir != "":
    result = pkgInfo.mypath.splitFile.dir / pkgInfo.srcDir
  else:
    result = pkgInfo.mypath.splitFile.dir

proc getOutputDir*(pkgInfo: PackageInfo, bin: string): string =
  ## Returns a binary output dir for the package.
  if pkgInfo.binDir != "":
    result = pkgInfo.mypath.splitFile.dir / pkgInfo.binDir / bin
  else:
    result = pkgInfo.mypath.splitFile.dir / bin

proc echoPackage*(pkg: Package) =
  echo(pkg.name & ":")
  echo("  url:         " & pkg.url & " (" & pkg.downloadMethod & ")")
  echo("  tags:        " & pkg.tags.join(", "))
  echo("  description: " & pkg.description)
  echo("  license:     " & pkg.license)
  if pkg.web.len > 0:
    echo("  website:     " & pkg.web)

proc getDownloadDirName*(pkg: Package, verRange: VersionRange): string =
  result = pkg.name
  let verSimple = getSimpleString(verRange)
  if verSimple != "":
    result.add "_"
    result.add verSimple

proc isNimScript*(nf: NimbleFile): bool =
  readPackageInfo(nf).isNimScript

when isMainModule:
  doAssert getNameVersion("/home/user/.nimble/libs/packagea-0.1") ==
      ("packagea", "0.1")
  doAssert getNameVersion("/home/user/.nimble/libs/package-a-0.1") ==
      ("package-a", "0.1")
  doAssert getNameVersion("/home/user/.nimble/libs/package-a-0.1/package.nimble") ==
      ("package-a", "0.1")

  validatePackageName("foo_bar")
  validatePackageName("f_oo_b_a_r")
  try:
    validatePackageName("foo__bar")
    assert false
  except NimbleError:
    assert true

  doAssert toValidPackageName("foo__bar") == "foo_bar"
  doAssert toValidPackageName("jhbasdh!£$@%#^_&*_()qwe") == "jhbasdh_qwe"

  echo("All tests passed!")