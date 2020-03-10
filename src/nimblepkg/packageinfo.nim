# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

# Stdlib imports
import system except TResult
import hashes, json, strutils, os, sets, tables, httpclient
from net import SslError

from compiler/nimblecmd import getPathVersionChecksum

# Local imports
import version, tools, common, options, cli, config, checksum,
       packageinfotypes, lockfile

proc getNameVersionChecksum*(pkgpath: string): PackageBasicInfo =
  ## Splits ``pkgpath`` in the format
  ## ``/home/user/.nimble/pkgs/package-0.1-febadeaea2345e777f0f6f8433f7f0a52edd5d1b``
  ## into ``("packagea", "0.1", "febadeaea2345e777f0f6f8433f7f0a52edd5d1b")``
  ##
  ## Also works for file paths like:
  ## ``/home/user/.nimble/pkgs/package-0.1-febadeaea2345e777f0f6f8433f7f0a52edd5d1b/package.nimble``
  if pkgPath.splitFile.ext in [".nimble", ".nimble-link", ".babel"]:
    return getNameVersionChecksum(pkgPath.splitPath.head)
  getPathVersionChecksum(pkgpath.splitPath.tail)

proc readMetaData*(path: string, silent = false): MetaData =
  ## Reads the metadata present in ``~/.nimble/pkgs/pkg-0.1/nimblemeta.json``
  var bmeta = path / packageMetaDataFileName
  if not fileExists(bmeta) and not silent:
    result.url = ""
    display("Warning:", "No nimblemeta.json file found in " & path,
            Warning, HighPriority)
    return
    # TODO: Make this an error.
  let cont = readFile(bmeta)
  let jsonmeta = parseJson(cont)
  result.url = jsonmeta[$pmdjkUrl].str
  result.vcsRevision = jsonmeta[$pmdjkVcsRevision].str

proc getVcsRevision(dir: string): string =
  # If the directory is under version control get the revision from it.
  result = getVcsRevisionFromDir(dir)
  if result.len > 0: return
  # Otherwise this probably is directory in the local cache and we try to get it
  # from the nimble package meta data json file.
  result = readMetaData(dir, true).vcsRevision

proc initPackageInfo*(filePath: string): PackageInfo =
  let (fileDir, fileName, _) = filePath.splitFile
  let (_, pkgVersion, pkgChecksum) = filePath.getNameVersionChecksum

  result.myPath = filePath
  result.specialVersion = ""
  result.nimbleTasks.init()
  result.preHooks.init()
  result.postHooks.init()
  # reasonable default:
  result.name = fileName
  result.version = pkgVersion
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
  result.foreignDeps = @[]
  result.bin = initTable[string, string]()
  result.srcDir = ""
  result.binDir = ""
  result.backend = "c"
  result.lockedDependencies = getLockedDependencies(fileDir)
  result.checksum =
    if pkgChecksum.len > 0: pkgChecksum
    else: calculatePackageSha1Checksum(fileDir)
  result.vcsRevision = getVcsRevision(fileDir)

proc toValidPackageName*(name: string): string =
  result = ""
  for c in name:
    case c
    of '_', '-':
      if result[^1] != '_': result.add('_')
    of AllChars - IdentChars - {'-'}: discard
    else: result.add(c)

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
  result = optionalField(obj, name)
  if result.len == 0:
    raise newException(NimbleError,
        "Package in packages.json file does not contain a " & name & " field.")

proc fromJson(obj: JSonNode): Package =
  ## Constructs a Package object from a JSON node.
  ##
  ## Aborts execution if the JSON node doesn't contain the required fields.
  result.name = obj.requiredField("name")
  if obj.hasKey("alias"):
    result.alias = obj.requiredField("alias")
  else:
    result.alias = ""
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

proc readNimbleLink*(nimbleLinkPath: string): NimbleLink =
  let s = readFile(nimbleLinkPath).splitLines()
  result.nimbleFilePath = s[0]
  result.packageDir = s[1]

proc writeNimbleLink*(nimbleLinkPath: string, contents: NimbleLink) =
  let c = contents.nimbleFilePath & "\n" & contents.packageDir
  writeFile(nimbleLinkPath, c)

proc needsRefresh*(options: Options): bool =
  ## Determines whether a ``nimble refresh`` is needed.
  ##
  ## In the future this will check a stored time stamp to determine how long
  ## ago the package list was refreshed.
  result = true
  for name, list in options.config.packageLists:
    if fileExists(options.getNimbleDir() / "packages_" & name & ".json"):
      result = false

proc validatePackagesList(path: string): bool =
  ## Determines whether package list at ``path`` is valid.
  try:
    let pkgList = parseFile(path)
    if pkgList.kind == JArray:
      if pkgList.len == 0:
        display("Warning:", path & " contains no packages.", Warning,
                HighPriority)
      return true
  except ValueError, JsonParsingError:
    return false

proc fetchList*(list: PackageList, options: Options) =
  ## Downloads or copies the specified package list and saves it in $nimbleDir.
  let verb = if list.urls.len > 0: "Downloading" else: "Copying"
  display(verb, list.name & " package list", priority = HighPriority)

  var
    lastError = ""
    copyFromPath = ""
  if list.urls.len > 0:
    for i in 0 ..< list.urls.len:
      let url = list.urls[i]
      display("Trying", url)
      let tempPath = options.getNimbleDir() / "packages_temp.json"

      # Grab the proxy
      let proxy = getProxy(options)
      if not proxy.isNil:
        var maskedUrl = proxy.url
        if maskedUrl.password.len > 0: maskedUrl.password = "***"
        display("Connecting", "to proxy at " & $maskedUrl,
                priority = LowPriority)

      try:
        let ctx = newSSLContext(options.disableSslCertCheck)
        let client = newHttpClient(proxy = proxy, sslContext = ctx)
        client.downloadFile(url, tempPath)
      except SslError:
        let message = "Failed to verify the SSL certificate for " & url
        raiseNimbleError(message, "Use --noSSLCheck to ignore this error.")

      except:
        let message = "Could not download: " & getCurrentExceptionMsg()
        display("Warning:", message, Warning)
        lastError = message
        continue

      if not validatePackagesList(tempPath):
        lastError = "Downloaded packages.json file is invalid"
        display("Warning:", lastError & ", discarding.", Warning)
        continue

      copyFromPath = tempPath
      display("Success", "Package list downloaded.", Success, HighPriority)
      lastError = ""
      break

  elif list.path != "":
    if not validatePackagesList(list.path):
      lastError = "Copied packages.json file is invalid"
      display("Warning:", lastError & ", discarding.", Warning)
    else:
      copyFromPath = list.path
      display("Success", "Package list copied.", Success, HighPriority)

  if lastError.len != 0:
    raise newException(NimbleError, "Refresh failed\n" & lastError)

  if copyFromPath.len > 0:
    copyFile(copyFromPath,
        options.getNimbleDir() / "packages_$1.json" % list.name.toLowerAscii())

# Cache after first call
var
  gPackageJson: Table[string, JsonNode]
proc readPackageList(name: string, options: Options): JsonNode =
  # If packages.json is not present ask the user if they want to download it.
  if gPackageJson.hasKey(name):
    return gPackageJson[name]

  if needsRefresh(options):
    if options.prompt("No local packages.json found, download it from " &
            "internet?"):
      for name, list in options.config.packageLists:
        fetchList(list, options)
    else:
      # The user might not need a package list for now. So let's try
      # going further.
      gPackageJson[name] = newJArray()
      return gPackageJson[name]
  gPackageJson[name] = parseFile(options.getNimbleDir() / "packages_" &
                                 name.toLowerAscii() & ".json")
  return gPackageJson[name]

proc getPackage*(pkg: string, options: Options, resPkg: var Package): bool
proc resolveAlias(pkg: Package, options: Options): Package =
  result = pkg
  # Resolve alias.
  if pkg.alias.len > 0:
    display("Warning:", "The $1 package has been renamed to $2" %
            [pkg.name, pkg.alias], Warning, HighPriority)
    if not getPackage(pkg.alias, options, result):
      raise newException(NimbleError, "Alias for package not found: " &
                         pkg.alias)

proc getPackage*(pkg: string, options: Options, resPkg: var Package): bool =
  ## Searches any packages.json files defined in ``options.config.packageLists``
  ## Saves the found package into ``resPkg``.
  ##
  ## Pass in ``pkg`` the name of the package you are searching for. As
  ## convenience the proc returns a boolean specifying if the ``resPkg`` was
  ## successfully filled with good data.
  ##
  ## Aliases are handled and resolved.
  for name, list in options.config.packageLists:
    display("Reading", "$1 package list" % name, priority = LowPriority)
    let packages = readPackageList(name, options)
    for p in packages:
      if normalize(p["name"].str) == normalize(pkg):
        resPkg = p.fromJson()
        resPkg = resolveAlias(resPkg, options)
        return true

proc getPackage*(name: string, options: Options): Package =
  let success = getPackage(name, options, result)
  if not success:
    raise newException(NimbleError,
      "Cannot find package with name '" & name & "'.")

proc getPackageList*(options: Options): seq[Package] =
  ## Returns the list of packages found in the downloaded packages.json files.
  result = @[]
  var namesAdded = initHashSet[string]()
  for name, list in options.config.packageLists:
    let packages = readPackageList(name, options)
    for p in packages:
      let pkg: Package = p.fromJson()
      if pkg.name notin namesAdded:
        result.add(pkg)
        namesAdded.incl(pkg.name)

proc findNimbleFile*(dir: string; error: bool): string =
  result = ""
  var hits = 0
  for kind, path in walkDir(dir):
    if kind in {pcFile, pcLinkToFile}:
      let ext = path.splitFile.ext
      case ext
      of ".babel", ".nimble", ".nimble-link":
        result = path
        inc hits
      else: discard
  if hits >= 2:
    raise newException(NimbleError,
        "Only one .nimble file should be present in " & dir)
  elif hits == 0:
    if error:
      raise newException(NimbleError,
          "Could not find a file with a .nimble extension inside the specified directory: $1" % dir)
    else:
      display("Warning:", "No .nimble or .nimble-link file found for " &
              dir, Warning, HighPriority)

  if result.splitFile.ext == ".nimble-link":
    # Return the path of the real .nimble file.
    result = readNimbleLink(result).nimbleFilePath
    if not fileExists(result):
      let msg = "The .nimble-link file is pointing to a missing file: " & result
      let hintMsg =
        "Remove '$1' or restore the file it points to." % dir
      display("Warning:", msg, Warning, HighPriority)
      display("Hint:", hintMsg, Warning, HighPriority)

proc getInstalledPackageMin*(packageDir, nimbleFilePath: string): PackageInfo =
  let (name, version, checksum) = getNameVersionChecksum(packageDir)
  result = initPackageInfo(nimbleFilePath)
  result.name = name
  result.version = version
  result.specialVersion = version
  result.checksum = checksum
  result.isMinimal = true
  result.isInstalled = true
  let nimbleFileDir = nimbleFilePath.splitFile().dir
  result.isLinked = cmpPaths(nimbleFileDir, packageDir) != 0

  # Read the package's 'srcDir' (this is stored in the .nimble-link so
  # we can easily grab it)
  if result.isLinked:
    let nimbleLinkPath = packageDir / name.addFileExt("nimble-link")
    let realSrcPath = readNimbleLink(nimbleLinkPath).packageDir
    assert realSrcPath.startsWith(nimbleFileDir)
    result.srcDir = realSrcPath.replace(nimbleFileDir)
    result.srcDir.removePrefix(DirSep)

proc getInstalledPkgsMin*(libsDir: string, options: Options):
        seq[PackageInfoAndMetaData] =
  ## Gets a list of installed packages. The resulting package info is
  ## minimal. This has the advantage that it does not depend on the
  ## ``packageparser`` module, and so can be used by ``nimscriptwrapper``.
  ##
  ## ``libsDir`` is in most cases: ~/.nimble/pkgs/ (options.getPkgsDir)
  result = @[]
  for kind, path in walkDir(libsDir):
    if kind == pcDir:
      let nimbleFile = findNimbleFile(path, false)
      if nimbleFile != "":
        let meta = readMetaData(path)
        let pkg = getInstalledPackageMin(path, nimbleFile)
        result.add((pkg, meta))

proc withinRange*(pkgInfo: PackageInfo, verRange: VersionRange): bool =
  ## Determines whether the specified package's version is within the
  ## specified range. The check works with ordinary versions as well as
  ## special ones.
  return withinRange(newVersion(pkgInfo.version), verRange) or
         withinRange(newVersion(pkgInfo.specialVersion), verRange)

proc resolveAlias*(dep: PkgTuple, options: Options): PkgTuple =
  ## Looks up the specified ``dep.name`` in the packages.json files to resolve
  ## a potential alias into the package's real name.
  result = dep
  var pkg: Package
  # TODO: This needs better caching.
  if getPackage(dep.name, options, pkg):
    # The resulting ``pkg`` will contain the resolved name or the original if
    # no alias is present.
    result.name = pkg.name

proc findPkg*(pkglist: seq[PackageInfoAndMetaData],
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
    if withinRange(pkg.pkgInfo, dep.ver):
      let isNewer = newVersion(r.version) < newVersion(pkg.pkginfo.version)
      if not result or isNewer:
        r = pkg.pkginfo
        result = true

proc findAllPkgs*(pkglist: seq[PackageInfoAndMetaData],
                  dep: PkgTuple): seq[PackageInfo] =
  ## Searches ``pkglist`` for packages of which version is within the range
  ## of ``dep.ver``. This is similar to ``findPkg`` but returns multiple
  ## packages if multiple are found.
  result = @[]
  for pkg in pkglist:
    if cmpIgnoreStyle(pkg.pkgInfo.name, dep.name) != 0 and
       cmpIgnoreStyle(pkg.meta.url, dep.name) != 0: continue
    if withinRange(pkg.pkgInfo, dep.ver):
      result.add pkg.pkginfo

proc getRealDir*(pkgInfo: PackageInfo): string =
  ## Returns the directory containing the package source files.
  if pkgInfo.srcDir != "" and (not pkgInfo.isInstalled or pkgInfo.isLinked):
    result = pkgInfo.mypath.splitFile.dir / pkgInfo.srcDir
  else:
    result = pkgInfo.mypath.splitFile.dir

proc getOutputDir*(pkgInfo: PackageInfo, bin: string): string =
  ## Returns a binary output dir for the package.
  if pkgInfo.binDir != "":
    result = pkgInfo.mypath.splitFile.dir / pkgInfo.binDir / bin
  else:
    result = pkgInfo.mypath.splitFile.dir / bin
  if bin.len != 0 and dirExists(result):
    result &= ".out"

proc echoPackage*(pkg: Package) =
  echo(pkg.name & ":")
  if pkg.alias.len > 0:
    echo("  Alias for ", pkg.alias)
  else:
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

proc checkInstallFile(pkgInfo: PackageInfo,
                      origDir, file: string): bool =
  ## Checks whether ``file`` should be installed.
  ## ``True`` means file should be skipped.

  for ignoreFile in pkgInfo.skipFiles:
    if ignoreFile.endswith("nimble"):
      raise newException(NimbleError, ignoreFile & " must be installed.")
    if samePaths(file, origDir / ignoreFile):
      result = true
      break

  for ignoreExt in pkgInfo.skipExt:
    if file.splitFile.ext == ('.' & ignoreExt):
      result = true
      break

  if file.splitFile().name[0] == '.': result = true

proc checkInstallDir(pkgInfo: PackageInfo,
                     origDir, dir: string): bool =
  ## Determines whether ``dir`` should be installed.
  ## ``True`` means dir should be skipped.
  for ignoreDir in pkgInfo.skipDirs:
    if samePaths(dir, origDir / ignoreDir):
      result = true
      break

  let thisDir = splitPath(dir).tail
  assert thisDir != ""
  if thisDir[0] == '.': result = true
  if thisDir == "nimcache": result = true

proc iterFilesWithExt(dir: string, pkgInfo: PackageInfo,
                      action: proc (f: string)) =
  ## Runs `action` for each filename of the files that have a whitelisted
  ## file extension.
  for kind, path in walkDir(dir):
    if kind == pcDir:
      iterFilesWithExt(path, pkgInfo, action)
    else:
      if path.splitFile.ext.substr(1) in pkgInfo.installExt:
        action(path)

proc iterFilesInDir(dir: string, action: proc (f: string)) =
  ## Runs `action` for each file in ``dir`` and any
  ## subdirectories that are in it.
  for kind, path in walkDir(dir):
    if kind == pcDir:
      iterFilesInDir(path, action)
    else:
      action(path)

proc iterInstallFiles*(realDir: string, pkgInfo: PackageInfo,
                       options: Options, action: proc (f: string)) =
  ## Runs `action` for each file within the ``realDir`` that should be
  ## installed.
  let whitelistMode =
          pkgInfo.installDirs.len != 0 or
          pkgInfo.installFiles.len != 0 or
          pkgInfo.installExt.len != 0
  if whitelistMode:
    for file in pkgInfo.installFiles:
      let src = realDir / file
      if not src.fileExists():
        if options.prompt("Missing file " & src & ". Continue?"):
          continue
        else:
          raise NimbleQuit(msg: "")

      action(src)

    for dir in pkgInfo.installDirs:
      # TODO: Allow skipping files inside dirs?
      let src = realDir / dir
      if not src.dirExists():
        if options.prompt("Missing directory " & src & ". Continue?"):
          continue
        else:
          raise NimbleQuit(msg: "")

      iterFilesInDir(src, action)

    iterFilesWithExt(realDir, pkgInfo, action)
  else:
    for kind, file in walkDir(realDir):
      if kind == pcDir:
        let skip = pkgInfo.checkInstallDir(realDir, file)
        if skip: continue
        # we also have to stop recursing if we reach an in-place nimbleDir
        if file == options.getNimbleDir().expandFilename(): continue

        iterInstallFiles(file, pkgInfo, options, action)
      else:
        let skip = pkgInfo.checkInstallFile(realDir, file)
        if skip: continue

        action(file)

proc getPkgDest*(pkgInfo: PackageInfo, options: Options): string =
  let versionStr = '-' & pkgInfo.specialVersion & '-' & pkgInfo.checksum
  let pkgDestDir = options.getPkgsDir() / (pkgInfo.name & versionStr)
  return pkgDestDir

proc `==`*(pkg1: PackageInfo, pkg2: PackageInfo): bool =
  if pkg1.name == pkg2.name and pkg1.myPath == pkg2.myPath:
    return true

proc hash*(x: PackageInfo): Hash =
  var h: Hash = 0
  h = h !& hash(x.myPath)
  result = !$h

when isMainModule:
  import unittest 

  check getNameVersionChecksum(
    "/home/user/.nimble/libs/packagea-0.1") ==
    ("packagea", "0.1", "")

  check getNameVersionChecksum(
    "/home/user/.nimble/libs/package-a-0.1") ==
    ("package-a", "0.1", "")

  check getNameVersionChecksum(
    "/home/user/.nimble/libs/package-a-0.1/package.nimble") ==
    ("package-a", "0.1", "")

  check getNameVersionChecksum(
    "/home/user/.nimble/libs/package-#head") ==
    ("package", "#head", "")

  check getNameVersionChecksum(
    "/home/user/.nimble/libs/package-#branch-with-dashes") ==
    ("package", "#branch-with-dashes", "")

  # readPackageInfo (and possibly more) depends on this not raising.
  check getNameVersionChecksum(
    "/home/user/.nimble/libs/package") ==
    ("package", "", "")

  # Tests with hash sums in the package directory names

  check getNameVersionChecksum(
    "/home/user/.nimble/libs/packagea-0.1-" &
    "9e6df089c5ee3d912006b2d1c016eb8fa7dcde82") ==
    ("packagea", "0.1", "9e6df089c5ee3d912006b2d1c016eb8fa7dcde82")

  check getNameVersionChecksum(
    "/home/user/.nimble/libs/package-a-0.1-" &
    "2f11b50a3d1933f9f8972bd09bc3325c38bc11d6") ==
    ("package-a", "0.1", "2f11b50a3d1933f9f8972bd09bc3325c38bc11d6")

  check getNameVersionChecksum(
    "/home/user/.nimble/libs/package-a-0.1-" &
    "43e3b1138312656310e93ffcfdd866b2dcce3b35/package.nimble") ==
    ("package-a", "0.1", "43e3b1138312656310e93ffcfdd866b2dcce3b35")

  check getNameVersionChecksum(
    "/home/user/.nimble/libs/package-#head-" &
    "efba335dccf2631d7ac2740109142b92beb3b465") ==
    ("package", "#head", "efba335dccf2631d7ac2740109142b92beb3b465")

  check getNameVersionChecksum(
    "/home/user/.nimble/libs/package-#branch-with-dashes-" &
    "8f995e59d6fc1012b3c1509fcb0ef0a75cb3610c") ==
    ("package", "#branch-with-dashes", "8f995e59d6fc1012b3c1509fcb0ef0a75cb3610c")

  check getNameVersionChecksum(
    "/home/user/.nimble/libs/package-" &
    "b12e18db49fc60df117e5d8a289c4c2050a272dd") ==
    ("package", "", "b12e18db49fc60df117e5d8a289c4c2050a272dd")

  check toValidPackageName("foo__bar") == "foo_bar"
  check toValidPackageName("jhbasdh!£$@%#^_&*_()qwe") == "jhbasdh_qwe"

  reportUnitTestSuccess()
