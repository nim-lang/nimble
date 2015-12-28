# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
import parsecfg, json, streams, strutils, parseutils, os
import version, tools, nimbletypes, nimscriptsupport, options, packageinfo

## Contains procedures for parsing .nimble files. Moved here from ``packageinfo``
## because it depends on ``nimscriptsupport`` (``nimscriptsupport`` also
## depends on other procedures in ``packageinfo``.

when not declared(system.map):
  from sequtils import map

type
  NimbleFile* = string

  ValidationError* = object of NimbleError
    warnInstalled*: bool # Determines whether to show a warning for installed pkgs

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

proc readPackageInfo*(nf: NimbleFile, options: Options,
    onlyMinimalInfo=false): PackageInfo =
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
        readPackageInfoFromNims(nf, options, result)
        result.isNimScript = true
      except NimbleError:
        let msg = "Could not read package info file in " & nf & ";\n" &
                  "  Reading as ini file failed with: \n" &
                  "    " & iniError.msg & ".\n" &
                  "  Evaluating as NimScript file failed with: \n" &
                  "    " & getCurrentExceptionMsg() & "."
        raise newException(NimbleError, msg)

  validatePackageInfo(result, nf)

proc getPkgInfo*(dir: string, options: Options): PackageInfo =
  ## Find the .nimble file in ``dir`` and parses it, returning a PackageInfo.
  let nimbleFile = findNimbleFile(dir, true)
  result = readPackageInfo(nimbleFile, options)

proc getInstalledPkgs*(libsDir: string, options: Options):
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
          var pkg = readPackageInfo(nimbleFile, options, true)
          pkg.isInstalled = true
          result.add((pkg, meta))
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

proc isNimScript*(nf: string, options: Options): bool =
  result = readPackageInfo(nf, options).isNimScript