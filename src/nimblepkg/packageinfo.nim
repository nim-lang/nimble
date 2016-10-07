# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
import parsecfg, json, streams, strutils, parseutils, os, sets, tables
import version, tools, nimbletypes, options, sequtils

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

proc initPackageInfo*(path: string): PackageInfo =
  result.mypath = path
  result.preHooks.init()
  result.postHooks.init()
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

proc toValidPackageName*(name: string): string =
  result = ""
  for c in name:
    case c
    of '_', '-':
      if result[^1] != '_': result.add('_')
    of AllChars - IdentChars - {'-'}: discard
    else: result.add(c)

proc getNameVersion*(pkgpath: string): tuple[name, version: string] =
  ## Splits ``pkgpath`` in the format ``/home/user/.nimble/pkgs/package-0.1``
  ## into ``(packagea, 0.1)``
  ##
  ## Also works for file paths like:
  ##   ``/home/user/.nimble/pkgs/package-0.1/package.nimble``

  if pkgPath.splitFile.ext == ".nimble" or pkgPath.splitFile.ext == ".babel":
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

proc getPackage*(pkg: string, options: Options,
    resPkg: var Package): bool =
  ## Searches any packages.json files defined in ``options.config.packageLists``
  ## Saves the found package into ``resPkg``.
  ##
  ## Pass in ``pkg`` the name of the package you are searching for. As
  ## convenience the proc returns a boolean specifying if the ``resPkg`` was
  ## successfully filled with good data.
  for name, list in options.config.packageLists:
    echo("Searching in \"", name, "\" package list...")
    let packages = parseFile(options.getNimbleDir() /
        "packages_" & name.toLower() & ".json")
    for p in packages:
      if normalize(p["name"].str) == normalize(pkg):
        resPkg = p.fromJson()
        return true

proc getPackageList*(options: Options): seq[Package] =
  ## Returns the list of packages found in the downloaded packages.json files.
  result = @[]
  var namesAdded = initSet[string]()
  for name, list in options.config.packageLists:
    let packages = parseFile(options.getNimbleDir() /
        "packages_" & name.toLower() & ".json")
    for p in packages:
      let pkg: Package = p.fromJson()
      if pkg.name notin namesAdded:
        result.add(pkg)
        namesAdded.incl(pkg.name)

proc findNimbleFile*(dir: string; error: bool): string =
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

proc getInstalledPkgsMin*(libsDir: string, options: Options):
        seq[tuple[pkginfo: PackageInfo, meta: MetaData]] =
  ## Gets a list of installed packages. The resulting package info is
  ## minimal. This has the advantage that it does not depend on the
  ## ``packageparser`` module, and so can be used by ``nimscriptsupport``.
  ##
  ## ``libsDir`` is in most cases: ~/.nimble/pkgs/
  result = @[]
  for kind, path in walkDir(libsDir):
    if kind == pcDir:
      let nimbleFile = findNimbleFile(path, false)
      if nimbleFile != "":
        let meta = readMetaData(path)
        let (name, version) = getNameVersion(nimbleFile)
        var pkg = initPackageInfo(nimbleFile)
        pkg.name = name
        pkg.version = version
        pkg.isMinimal = true
        pkg.isInstalled = true
        result.add((pkg, meta))

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
  if pkgInfo.srcDir != "" and not pkgInfo.isInstalled:
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

proc needsRefresh*(options: Options): bool =
  ## Determines whether a ``nimble refresh`` is needed.
  ##
  ## In the future this will check a stored time stamp to determine how long
  ## ago the package list was refreshed.
  result = true
  for name, list in options.config.packageLists:
    if fileExists(options.getNimbleDir() / "packages_" & name & ".json"):
      result = false

proc validatePackagesList*(path: string): bool =
  ## Determines whether package list at ``path`` is valid.
  try:
    let pkgList = parseFile(path)
    if pkgList.kind == JArray:
      if pkgList.len == 0:
        echo("WARNING: ", path, " contains no packages.")
      return true
  except ValueError, JsonParsingError:
    return false

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
