# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
import parsecfg, sets, streams, strutils, os, tables, sugar
from sequtils import apply, map, toSeq

import version, tools, common, nimscriptwrapper, options, packageinfo, cli

## Contains procedures for parsing .nimble files. Moved here from ``packageinfo``
## because it depends on ``nimscriptwrapper`` (``nimscriptwrapper`` also
## depends on other procedures in ``packageinfo``.

type
  NimbleFile* = string

  ValidationError* = object of NimbleError
    warnInstalled*: bool # Determines whether to show a warning for installed pkgs
    warnAll*: bool

const reservedNames = [
  "CON",
  "PRN",
  "AUX",
  "NUL",
  "COM1",
  "COM2",
  "COM3",
  "COM4",
  "COM5",
  "COM6",
  "COM7",
  "COM8",
  "COM9",
  "LPT1",
  "LPT2",
  "LPT3",
  "LPT4",
  "LPT5",
  "LPT6",
  "LPT7",
  "LPT8",
  "LPT9",
]

proc newValidationError(msg: string, warnInstalled: bool,
                        hint: string, warnAll: bool): ref ValidationError =
  result = newException(ValidationError, msg)
  result.warnInstalled = warnInstalled
  result.warnAll = warnAll
  result.hint = hint

proc raiseNewValidationError(msg: string, warnInstalled: bool,
                             hint: string = "", warnAll = false) =
  raise newValidationError(msg, warnInstalled, hint, warnAll)

proc validatePackageName*(name: string) =
  ## Raises an error if specified package name contains invalid characters.
  ##
  ## A valid package name is one which is a valid nim module name. So only
  ## underscores, letters and numbers allowed.
  if name.len == 0: return

  if name[0] in {'0'..'9'}:
    raiseNewValidationError(name &
        "\"$1\" is an invalid package name: cannot begin with $2" %
        [name, $name[0]], true)

  var prevWasUnderscore = false
  for c in name:
    case c
    of '_':
      if prevWasUnderscore:
        raiseNewValidationError(
            "$1 is an invalid package name: cannot contain \"__\"" % name, true)
      prevWasUnderscore = true
    of AllChars - IdentChars:
      raiseNewValidationError(
          "$1 is an invalid package name: cannot contain '$2'" % [name, $c],
          true)
    else:
      prevWasUnderscore = false

  if name.endsWith("pkg"):
    raiseNewValidationError("\"$1\" is an invalid package name: cannot end" &
                            " with \"pkg\"" % name, false)
  if name.toUpperAscii() in reservedNames:
    raiseNewValidationError(
      "\"$1\" is an invalid package name: reserved name" % name, false)

proc validateVersion*(ver: string) =
  for c in ver:
    if c notin ({'.'} + Digits):
      raiseNewValidationError(
          "Version may only consist of numbers and the '.' character " &
          "but found '" & c & "'.", false)

proc validatePackageStructure(pkgInfo: PackageInfo, options: Options) =
  ## This ensures that a package's source code does not leak into
  ## another package's namespace.
  ## https://github.com/nim-lang/nimble/issues/144
  let
    realDir = pkgInfo.getRealDir()
    normalizedBinNames = toSeq(pkgInfo.bin.keys).map(
      (x) => x.changeFileExt("").toLowerAscii()
    )
    correctDir =
      if pkgInfo.name.toLowerAscii() in normalizedBinNames:
        pkgInfo.name & "pkg"
      else:
        pkgInfo.name

  proc onFile(path: string) =
    # Remove the root to leave only the package subdirectories.
    # ~/package-0.1/package/utils.nim -> package/utils.nim.
    var trailPath = changeRoot(realDir, "", path)
    if trailPath.startsWith(DirSep): trailPath = trailPath[1 .. ^1]
    let (dir, file, ext) = trailPath.splitFile
    # We're only interested in nim files, because only they can pollute our
    # namespace.
    if ext != (ExtSep & "nim"):
      return

    if dir.len == 0:
      if file != pkgInfo.name:
        # A source file was found in the top level of srcDir that doesn't share
        # a name with the package.
        let
          msg = ("Package '$1' has an incorrect structure. " &
                "The top level of the package source directory " &
                "should contain at most one module, " &
                "named '$2', but a file named '$3' was found. This " &
                "will be an error in the future.") %
                [pkgInfo.name, pkgInfo.name & ext, file & ext]
          hint = ("If this is the primary source file in the package, " &
                  "rename it to '$1'. If it's a source file required by " &
                  "the main module, or if it is one of several " &
                  "modules exposed by '$4', then move it into a '$2' subdirectory. " &
                  "If it's a test file or otherwise not required " &
                  "to build the the package '$1', prevent its installation " &
                  "by adding `skipFiles = @[\"$3\"]` to the .nimble file. See " &
                  "https://github.com/nim-lang/nimble#libraries for more info.") %
                  [pkgInfo.name & ext, correctDir & DirSep, file & ext, pkgInfo.name]
        raiseNewValidationError(msg, true, hint, true)
    else:
      assert(not pkgInfo.isMinimal)
      # On Windows `pkgInfo.bin` has a .exe extension, so we need to normalize.
      if not (dir.startsWith(correctDir & DirSep) or dir == correctDir):
        let
          msg = ("Package '$2' has an incorrect structure. " &
                "It should contain a single directory hierarchy " &
                "for source files, named '$3', but file '$1' " &
                "is in a directory named '$4' instead. " &
                "This will be an error in the future.") %
              [file & ext, pkgInfo.name, correctDir, dir]
          hint = ("If '$1' contains source files for building '$2', rename it " &
                  "to '$3'. Otherwise, prevent its installation " &
                  "by adding `skipDirs = @[\"$1\"]` to the .nimble file.") %
              [dir, pkgInfo.name, correctDir]
        raiseNewValidationError(msg, true, hint, true)

  iterInstallFiles(realDir, pkgInfo, options, onFile)

proc validatePackageInfo(pkgInfo: PackageInfo, options: Options) =
  let path = pkgInfo.myPath
  if pkgInfo.name == "":
    raiseNewValidationError("Incorrect .nimble file: " & path &
        " does not contain a name field.", false)

  if pkgInfo.name.normalize != path.splitFile.name.normalize:
    raiseNewValidationError(
        "The .nimble file name must match name specified inside " & path, true)

  if pkgInfo.version == "":
    raiseNewValidationError("Incorrect .nimble file: " & path &
        " does not contain a version field.", false)

  if not pkgInfo.isMinimal:
    if pkgInfo.author == "":
      raiseNewValidationError("Incorrect .nimble file: " & path &
          " does not contain an author field.", false)
    if pkgInfo.description == "":
      raiseNewValidationError("Incorrect .nimble file: " & path &
          " does not contain a description field.", false)
    if pkgInfo.license == "":
      raiseNewValidationError("Incorrect .nimble file: " & path &
          " does not contain a license field.", false)
    if pkgInfo.backend notin ["c", "cc", "objc", "cpp", "js"]:
      raiseNewValidationError("'" & pkgInfo.backend &
          "' is an invalid backend.", false)

  validatePackageStructure(pkginfo, options)


proc nimScriptHint*(pkgInfo: PackageInfo) =
  if not pkgInfo.isNimScript:
    display("Warning:", "The .nimble file for this project could make use of " &
            "additional features, if converted into the new NimScript format." &
            "\nFor more details see:" &
            "https://github.com/nim-lang/nimble#creating-packages",
            Warning, HighPriority)

proc multiSplit(s: string): seq[string] =
  ## Returns ``s`` split by newline and comma characters.
  ##
  ## Before returning, all individual entries are stripped of whitespace and
  ## also empty entries are purged from the list. If after all the cleanups are
  ## done no entries are found in the list, the proc returns a sequence with
  ## the original string as the only entry.
  result = split(s, {char(0x0A), char(0x0D), ','})
  apply(result, proc(x: var string) = x = x.strip())
  for i in countdown(result.len()-1, 0):
    if len(result[i]) < 1:
      result.del(i)
  # Huh, nothing to return? Return given input.
  if len(result) < 1:
    if s.strip().len != 0:
      return @[s]
    else:
      return @[]

proc readPackageInfoFromNimble(path: string; result: var PackageInfo) =
  var fs = newFileStream(path, fmRead)
  if fs != nil:
    var p: CfgParser
    open(p, fs, path)
    defer: close(p)
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
              var (src, bin) = if '=' notin i: (i, i) else:
                let spl = i.split('=', 1)
                (spl[0], spl[1])
              if src.splitFile().ext == ".nim":
                raise newException(NimbleError, "`bin` entry should not be a source file: " & src)
              if result.backend == "js":
                bin = bin.addFileExt(".js")
              else:
                bin = bin.addFileExt(ExeExt)
              result.bin[bin] = src
          of "backend":
            result.backend = ev.value.toLowerAscii()
            case result.backend.normalize
            of "javascript": result.backend = "js"
            else: discard
          of "nimbletasks":
            for i in ev.value.multiSplit:
              result.nimbleTasks.incl(i.normalize)
          of "beforehooks":
            for i in ev.value.multiSplit:
              result.preHooks.incl(i.normalize)
          of "afterhooks":
            for i in ev.value.multiSplit:
              result.postHooks.incl(i.normalize)
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
  else:
    raise newException(ValueError, "Cannot open package info: " & path)

proc readPackageInfoFromNims(scriptName: string, options: Options,
    result: var PackageInfo) =
  let
    iniFile = getIniFile(scriptName, options)

  if iniFile.fileExists():
    readPackageInfoFromNimble(iniFile, result)

proc inferInstallRules(pkgInfo: var PackageInfo, options: Options) =
  # Binary packages shouldn't install .nim files by default.
  # (As long as the package info doesn't explicitly specify what should be
  # installed.)
  let installInstructions =
    pkgInfo.installDirs.len + pkgInfo.installExt.len + pkgInfo.installFiles.len
  if installInstructions == 0 and pkgInfo.bin.len > 0:
    pkgInfo.skipExt.add("nim")

  # When a package doesn't specify a `srcDir` it's fair to assume that
  # the .nim files are in the root of the package. So we can explicitly select
  # them and prevent the installation of anything else. The user can always
  # override this with `installFiles`.
  if pkgInfo.srcDir == "":
    if dirExists(pkgInfo.getRealDir() / pkgInfo.name):
      pkgInfo.installDirs.add(pkgInfo.name)
    if fileExists(pkgInfo.getRealDir() / pkgInfo.name.addFileExt("nim")):
      pkgInfo.installFiles.add(pkgInfo.name.addFileExt("nim"))

proc readPackageInfo(result: var PackageInfo, nf: NimbleFile, options: Options,
    onlyMinimalInfo=false) =
  ## Reads package info from the specified Nimble file.
  ##
  ## Attempts to read it using the "old" Nimble ini format first, if that
  ## fails attempts to evaluate it as a nimscript file.
  ##
  ## If both fail then returns an error.
  ##
  ## When ``onlyMinimalInfo`` is true, only the `name` and `version` fields are
  ## populated. The ``isNimScript`` field can also be relied on.
  ##
  ## This version uses a cache stored in ``options``, so calling it multiple
  ## times on the same ``nf`` shouldn't require re-evaluation of the Nimble
  ## file.

  assert fileExists(nf)

  # Check the cache.
  if options.pkgInfoCache.hasKey(nf):
    result = options.pkgInfoCache[nf]
    return

  result = initPackageInfo(nf)
  let minimalInfo = getNameVersion(nf)

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
      result.name = minimalInfo.name
      result.version = minimalInfo.version
      result.isNimScript = true
      result.isMinimal = true

      # It's possible this proc will receive a .nimble-link file eventually,
      # I added this assert to hopefully make this error clear for everyone.
      let msg = "No version detected. Received nimble-link?"
      assert result.version.len > 0, msg
    else:
      try:
        readPackageInfoFromNims(nf, options, result)
        result.isNimScript = true
      except NimbleError as exc:
        if exc.hint.len > 0:
          raise
        let msg = "Could not read package info file in " & nf & ";\n" &
                  "  Reading as ini file failed with: \n" &
                  "    " & iniError.msg & ".\n" &
                  "  Evaluating as NimScript file failed with: \n" &
                  "    " & exc.msg & "."
        raise newException(NimbleError, msg)

  # By default specialVersion is the same as version.
  result.specialVersion = result.version

  # Only attempt to read a special version if `nf` is inside the $nimbleDir.
  if nf.startsWith(options.getNimbleDir()):
    # The package directory name may include a "special" version
    # (example #head). If so, it is given higher priority and therefore
    # overwrites the .nimble file's version.
    let version = parseVersionRange(minimalInfo.version)
    if version.kind == verSpecial:
      result.specialVersion = minimalInfo.version

  # Apply rules to infer which files should/shouldn't be installed. See #469.
  inferInstallRules(result, options)

  if not result.isMinimal:
    options.pkgInfoCache[nf] = result

  # Validate the rest of the package info last.
  if not options.disableValidation:
    validateVersion(result.version)
    validatePackageInfo(result, options)

proc validate*(file: NimbleFile, options: Options,
               error: var ValidationError, pkgInfo: var PackageInfo): bool =
  try:
    pkgInfo.readPackageInfo(file, options)
  except ValidationError as exc:
    error = exc[]
    return false

  return true

proc getPkgInfoFromFile*(file: NimbleFile, options: Options): PackageInfo =
  ## Reads the specified .nimble file and returns its data as a PackageInfo
  ## object. Any validation errors are handled and displayed as warnings.
  var info: PackageInfo
  try:
    info.readPackageInfo(file, options)
  except ValidationError:
    let exc = (ref ValidationError)(getCurrentException())
    if exc.warnAll:
      display("Warning:", exc.msg, Warning, HighPriority)
      display("Hint:", exc.hint, Warning, HighPriority)
    else:
      raise
  finally:
    result = info

proc getPkgInfo*(dir: string, options: Options): PackageInfo =
  ## Find the .nimble file in ``dir`` and parses it, returning a PackageInfo.
  let nimbleFile = findNimbleFile(dir, true)
  return getPkgInfoFromFile(nimbleFile, options)

proc getInstalledPkgs*(libsDir: string, options: Options):
        seq[tuple[pkginfo: PackageInfo, meta: MetaData]] =
  ## Gets a list of installed packages.
  ##
  ## ``libsDir`` is in most cases: ~/.nimble/pkgs/
  const
    readErrorMsg = "Installed package '$1@$2' is outdated or corrupt."
    validationErrorMsg = readErrorMsg & "\nPackage did not pass validation: $3"
    hintMsg = "The corrupted package will need to be removed manually. To fix" &
              " this error message, remove $1."

  proc createErrorMsg(tmplt, path, msg: string): string =
    let (name, version) = getNameVersion(path)
    return tmplt % [name, version, msg]

  display("Loading", "list of installed packages", priority = MediumPriority)

  result = @[]
  for kind, path in walkDir(libsDir):
    if kind == pcDir:
      let nimbleFile = findNimbleFile(path, false)
      if nimbleFile != "":
        let meta = readMetaData(path)
        var pkg: PackageInfo
        try:
          pkg.readPackageInfo(nimbleFile, options, onlyMinimalInfo=false)
        except ValidationError:
          let exc = (ref ValidationError)(getCurrentException())
          exc.msg = createErrorMsg(validationErrorMsg, path, exc.msg)
          exc.hint = hintMsg % path
          if exc.warnInstalled or exc.warnAll:
            display("Warning:", exc.msg, Warning, HighPriority)
            # Don't show hints here because they are only useful for package
            # owners.
          else:
            raise exc
        except:
          let tmplt = readErrorMsg & "\nMore info: $3"
          let msg = createErrorMsg(tmplt, path, getCurrentException().msg)
          var exc = newException(NimbleError, msg)
          exc.hint = hintMsg % path
          raise exc

        pkg.isInstalled = true
        pkg.isLinked =
          cmpPaths(nimbleFile.splitFile().dir, path) != 0
        result.add((pkg, meta))

proc isNimScript*(nf: string, options: Options): bool =
  var p: PackageInfo
  p.readPackageInfo(nf, options)
  result = p.isNimScript

proc toFullInfo*(pkg: PackageInfo, options: Options): PackageInfo =
  if pkg.isMinimal:
    result = getPkgInfoFromFile(pkg.mypath, options)
    result.isInstalled = pkg.isInstalled
    result.isLinked = pkg.isLinked
  else:
    return pkg

proc getConcreteVersion*(pkgInfo: PackageInfo, options: Options): string =
  ## Returns a non-special version from the specified ``pkgInfo``. If the
  ## ``pkgInfo`` is minimal it looks it up and retrieves the concrete version.
  result = pkgInfo.version
  if pkgInfo.isMinimal:
    let pkgInfo = pkgInfo.toFullInfo(options)
    result = pkgInfo.version
  assert(not newVersion(result).isSpecial)

when isMainModule:
  validatePackageName("foo_bar")
  validatePackageName("f_oo_b_a_r")
  try:
    validatePackageName("foo__bar")
    assert false
  except NimbleError:
    assert true

  echo("Everything passed!")
