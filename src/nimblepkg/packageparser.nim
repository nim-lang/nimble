# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
import parsecfg, sets, streams, strutils, os, tables, sugar, strformat
from sequtils import apply, map, toSeq

import common, version, tools, nimscriptwrapper, options, cli, sha1hashes,
       packagemetadatafile, packageinfo, packageinfotypes, checksums, vcstools,
       paths

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

proc validationError(msg: string, warnInstalled: bool, hint = "",
                     warnAll = false): ref ValidationError =
  result = newNimbleError[ValidationError](msg, hint)
  result.warnInstalled = warnInstalled
  result.warnAll = warnAll

proc validatePackageName*(name: string) =
  ## Raises an error if specified package name contains invalid characters.
  ##
  ## A valid package name is one which is a valid nim module name. So only
  ## underscores, letters and numbers allowed.
  if name.len == 0: return

  if name[0] in {'0'..'9'}:
    raise validationError(name &
        "\"$1\" is an invalid package name: cannot begin with $2" %
        [name, $name[0]], true)

  var prevWasUnderscore = false
  for c in name:
    case c
    of '_':
      if prevWasUnderscore:
        raise validationError(
            "$1 is an invalid package name: cannot contain \"__\"" % name, true)
      prevWasUnderscore = true
    of AllChars - IdentChars:
      raise validationError(
          "$1 is an invalid package name: cannot contain '$2'" % [name, $c],
          true)
    else:
      prevWasUnderscore = false

  if name.endsWith("pkg"):
    raise validationError("\"$1\" is an invalid package name: cannot end" &
                          " with \"pkg\"" % name, false)
  if name.toUpperAscii() in reservedNames:
    raise validationError(
      "\"$1\" is an invalid package name: reserved name" % name, false)

proc validateVersion*(ver: string) =
  for c in ver:
    if c notin ({'.'} + Digits):
      raise validationError(
          "Version may only consist of numbers and the '.' character " &
          "but found '" & c & "'.", false)

proc validatePackageInfo(pkgInfo: PackageInfo, options: Options) =
  let path = pkgInfo.myPath
  if pkgInfo.basicInfo.name == "":
    raise validationError("Incorrect .nimble file: " & path &
                          " does not contain a name field.", false)

  if pkgInfo.basicInfo.name.normalize != path.splitFile.name.normalize:
    raise validationError(
        "The .nimble file name must match name specified inside " & path, true)

  if pkgInfo.basicInfo.version == notSetVersion:
    raise validationError("Incorrect .nimble file: " & path &
        " does not contain a version field.", false)

  if not pkgInfo.isMinimal:
    if pkgInfo.author == "":
      raise validationError("Incorrect .nimble file: " & path &
          " does not contain an author field.", false)
    if pkgInfo.description == "":
      raise validationError("Incorrect .nimble file: " & path &
          " does not contain a description field.", false)
    if pkgInfo.license == "":
      raise validationError("Incorrect .nimble file: " & path &
          " does not contain a license field.", false)
    if pkgInfo.backend notin ["c", "cc", "objc", "cpp", "js"]:
      raise validationError("'" & pkgInfo.backend &
          "' is an invalid backend.", false)

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
          of "name": result.basicInfo.name = ev.value
          of "version": result.basicInfo.version = newVersion(ev.value)
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
                raise nimbleError("`bin` entry should not be a source file: " & src)
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
          of "paths":
            result.paths.add(ev.value.multiSplit)
          of "entrypoints":
            result.entryPoints.add(ev.value.multiSplit)
          else:
            raise nimbleError("Invalid field: " & ev.key)
        of "deps", "dependencies":
          let normalizedKey = ev.key.normalize
          case normalizedKey
          of "requires":
            for v in ev.value.multiSplit:
              result.requires.add(parseRequires(v.strip))
          else:
            if normalizedKey.endsWith("requires"):
              let task = normalizedKey.dup(removeSuffix("requires"))
              # Tasks have already been parsed, so we can safely check
              # if the task is valid or not
              if task notin result.nimbleTasks and task != "test":
                raise nimbleError(fmt"Task {task} doesn't exist for requirement {ev.value}")

              if task notin result.taskRequires:
                result.taskRequires[task] = @[]
              # Add all requirements for the task
              for v in ev.value.multiSplit:
                result.taskRequires[task].add(parseRequires(v.strip))
            else:
              raise nimbleError("Invalid field: " & ev.key)
        else:
          raise nimbleError(
              "Invalid section: " & currentSection)
      of cfgOption: raise nimbleError(
            "Invalid package info, should not contain --" & ev.value)
      of cfgError:
        raise nimbleError("Error parsing .nimble file: " & ev.msg)
  else:
    raise nimbleError("Cannot open package info: " & path)

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
  if installInstructions == 0 and pkgInfo.bin.len > 0 and pkgInfo.basicInfo.name != "nim":
    pkgInfo.skipExt.add("nim")

  # When a package doesn't specify a `srcDir` it's fair to assume that
  # the .nim files are in the root of the package. So we can explicitly select
  # them and prevent the installation of anything else. The user can always
  # override this with `installFiles`.
  if pkgInfo.srcDir == "":
    if dirExists(pkgInfo.getRealDir() / pkgInfo.basicInfo.name):
      pkgInfo.installDirs.add(pkgInfo.basicInfo.name)
    if fileExists(pkgInfo.getRealDir() / pkgInfo.basicInfo.name.addFileExt("nim")):
      pkgInfo.installFiles.add(pkgInfo.basicInfo.name.addFileExt("nim"))

proc readPackageInfo(pkgInfo: var PackageInfo, nf: NimbleFile, options: Options, onlyMinimalInfo=false, useCache=true) =
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
  if useCache and options.pkgInfoCache.hasKey(nf):
    pkgInfo = options.pkgInfoCache[nf]
    return
  pkgInfo = initPackageInfo(options, nf)
  pkgInfo.isLink = not nf.startsWith(options.getPkgsDir)

  validatePackageName(nf.splitFile.name)

  var success = false
  var iniError: ref NimbleError
  # Attempt ini-format first.
  try:
    readPackageInfoFromNimble(nf, pkgInfo)
    success = true
    pkgInfo.isNimScript = false
  except NimbleError:
    iniError = (ref NimbleError)(getCurrentException())

  if not success:
    if onlyMinimalInfo:
      pkgInfo.isNimScript = true
      pkgInfo.isMinimal = true
    else:
      try:
        readPackageInfoFromNims(nf, options, pkgInfo)
        pkgInfo.isNimScript = true
      except NimbleError as exc:
        if exc.hint.len > 0:
          raise
        let msg = "Could not read package info file in " & nf & ";\n" &
                  "  Reading as ini file failed with: \n" &
                  "    " & iniError.msg & ".\n" &
                  "  Evaluating as NimScript file failed with: \n" &
                  "    " & exc.msg & "."
        raise nimbleError(msg)

  let fileDir = nf.splitFile().dir
  if not fileDir.startsWith(options.getPkgsDir()):
    # If the `.nimble` file is not in the installation directory we have to get
    # some of the package meta data from its directory.
    pkgInfo.basicInfo.checksum = calculateDirSha1Checksum(fileDir)
    # By default specialVersion is the same as version.
    pkgInfo.metaData.specialVersions.incl pkgInfo.basicInfo.version
    # If the `fileDir` is a VCS repository we can get some of the package meta
    # data from it.
    try:
      pkgInfo.metaData.vcsRevision = getVcsRevision(fileDir)
    except CatchableError:
      raise nimbleError(
        msg = "Failed to get VCS revision of your project!",
        hint = "Try making a commit to your project if you haven't made one yet."
      )

    case getVcsType(fileDir)
      of vcsTypeGit: pkgInfo.metaData.downloadMethod = DownloadMethod.git
      of vcsTypeHg: pkgInfo.metaData.downloadMethod = DownloadMethod.hg
      of vcsTypeNone: discard

    try:
      pkgInfo.metaData.url = getRemoteFetchUrl(fileDir,
        getCorrespondingRemoteAndBranch(fileDir).remote)
    except NimbleError:
      discard
  else:
    # Otherwise we have to get its name, special version and checksum from the
    # package directory.
    setNameVersionChecksum(pkgInfo, fileDir)

  # Apply rules to infer which files should/shouldn't be installed. See #469.
  inferInstallRules(pkgInfo, options)

  if not pkgInfo.isMinimal:
    options.pkgInfoCache[nf] = pkgInfo

  # Validate the rest of the package info last.
  if not options.disableValidation:
    validateVersion($pkgInfo.basicInfo.version)
    validatePackageInfo(pkgInfo, options)

proc getPkgInfoFromFile*(file: NimbleFile, options: Options,
                         forValidation = false, useCache = true): PackageInfo =
  ## Reads the specified .nimble file and returns its data as a PackageInfo
  ## object. Any validation errors are handled and displayed as warnings.
  result = initPackageInfo()
  try:
    readPackageInfo(result, file, options, useCache= useCache)
  except ValidationError:
    let exc = (ref ValidationError)(getCurrentException())
    if exc.warnAll and not forValidation:
      display("Warning:", exc.msg, Warning, HighPriority)
      display("Hint:", exc.hint, Warning, HighPriority)
    else:
      raise

proc getPkgInfo*(dir: string, options: Options, forValidation = false):
    PackageInfo =
  ## Find the .nimble file in ``dir`` and parses it, returning a PackageInfo.
  let nimbleFile = findNimbleFile(dir, true, options)
  result = getPkgInfoFromFile(nimbleFile, options, forValidation)

proc getInstalledPkgs*(libsDir: string, options: Options): seq[PackageInfo] =
  ## Gets a list of installed packages.
  ##
  ## ``libsDir`` is in most cases: ~/.nimble/pkgs/
  const
    readErrorMsg = "Installed packaged '$1@$2' is outdated or corrupt."
    validationErrorMsg = readErrorMsg & "\nPackage did not pass validation: $3"
    hintMsg = "The corrupted package will need to be removed manually. To fix" &
              " this error message, remove $1."

  proc createErrorMsg(tmplt, path, msg: string): string =
    let (name, version, checksum) = getNameVersionChecksum(path)
    let fullVersion =
      if checksum != notSetSha1Hash:
        $version & "@c." & $checksum
      else:
        $version
    return tmplt % [name, fullVersion, msg]

  display("Loading", "list of installed packages", priority = MediumPriority)

  result = @[]
  for kind, path in walkDir(libsDir):
    if kind == pcDir:
      let nimbleFile = findNimbleFile(path, false, options)
      if nimbleFile != "":
        var pkg = initPackageInfo()
        try:
          readPackageInfo(pkg, nimbleFile, options, onlyMinimalInfo=false)
          fillMetaData(pkg, path, false, options)
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
          var exc = nimbleError(msg)
          exc.hint = hintMsg % path
          raise exc

        pkg.isInstalled = true
        result.add pkg

proc isNimScript*(nf: string, options: Options): bool =
  var pkg = initPackageInfo()
  readPackageInfo(pkg, nf, options)
  result = pkg.isNimScript

proc toFullInfo*(pkg: PackageInfo, options: Options): PackageInfo =
  if pkg.isMinimal:
    result = getPkgInfoFromFile(pkg.mypath, options)
    result.isInstalled = pkg.isInstalled
    # The `isLink` data from the meta data file is with priority because of the
    # old format develop packages.
    result.isLink = pkg.isLink
    result.metaData.specialVersions.incl pkg.metaData.specialVersions

    assert not (pkg.isInstalled and pkg.isLink),
           "A package must not be simultaneously installed and linked."

    if result.isInstalled:
      assert result.metaData.vcsRevision == notSetSha1Hash,
            "Should not have a VCS revision read from package directory for " &
            "installed packages."

      # For installed packages use already read meta data.
      result.metaData = pkg.metaData
  else:
    return pkg

proc getConcreteVersion*(pkgInfo: PackageInfo, options: Options): Version =
  ## Returns a non-special version from the specified ``pkgInfo``. If the
  ## ``pkgInfo`` is minimal it looks it up and retrieves the concrete version.
  result = pkgInfo.basicInfo.version
  if pkgInfo.isMinimal:
    let pkgInfo = pkgInfo.toFullInfo(options)
    result = pkgInfo.basicInfo.version
  assert not result.isSpecial

when isMainModule:
  import unittest

  test "validatePackageName":
    validatePackageName("foo_bar")
    validatePackageName("f_oo_b_a_r")
    expect NimbleError, validatePackageName("foo__bar")
