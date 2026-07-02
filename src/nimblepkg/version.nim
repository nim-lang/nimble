# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

## Module for handling versions and version ranges such as ``>= 1.0 & <= 1.5``
import sets
import common, strutils, tables, hashes, parseutils, forge_aliases, urls
import std/[strscans, options]
import compat/json
type
  Version* = object
    version*: string
    speSemanticVersion*: Option[string]  # For special versions, stores the real semantic version so we can compare.

  VersionRangeEnum* = enum
    verLater, # > V
    verEarlier, # < V
    verEqLater, # >= V -- Equal or later
    verEqEarlier, # <= V -- Equal or earlier
    verIntersect, # > V & < V
    verTilde, # ~= V
    verCaret, # ^= V
    verEq, # V
    verAny, # *
    verSpecial # #head

  VersionRange* = ref VersionRangeObj
  VersionRangeObj = object
    case kind*: VersionRangeEnum
    of verLater, verEarlier, verEqLater, verEqEarlier, verEq:
      ver*: Version
    of verSpecial:
      spe*: Version      
    of verIntersect, verTilde, verCaret:
      verILeft*, verIRight*: VersionRange
    of verAny:
      nil

  ## Tuple containing package name and version range.
  PkgTuple* = tuple[name: string, ver: VersionRange]

  ParseVersionError* = object of NimbleError

const
  notSetVersion* = Version(version: "-1")

proc parseVersionError*(msg: string): ref ParseVersionError =
  result = newNimbleError[ParseVersionError](msg)

template `$`*(ver: Version): string = ver.version
template hash*(ver: Version): Hash = ver.version.hash
template `%`*(ver: Version): JsonNode = %ver.version

proc toDirectoryName*(ver: Version): string =
  #strips '#' which causes issues with autoconf/shell
  ver.version.strip(chars = {'#'})

proc newVersion*(ver: string): Version =
  if ver.len != 0 and ver[0] notin {'#', '\0'} + Digits:
    raise parseVersionError("Wrong version: " & ver)
  return Version(version: ver)

proc initFromJson*(dst: var Version, jsonNode: JsonNode, jsonPath: var string) =
  case jsonNode.kind
  of JNull: dst = notSetVersion
  of JObject: dst = newVersion(jsonNode["version"].str)
  of JString: dst = newVersion(jsonNode.str)
  else:
    assert false,
      "The `jsonNode` must have one of {JNull, JObject, JString} kinds."

proc isSpecial*(ver: Version): bool =
  return ($ver).len > 0 and ($ver)[0] == '#'

proc isSpecial*(verRange: VersionRange): bool =
  return verRange.kind == verSpecial

type
  PrereleaseIdent = object
    isNum: bool
    num: int      ## used when `isNum`
    str: string   ## used when not `isNum`

  SemVerParts = object
    release: seq[int]                 ## [major, minor, patch, ...]; missing fields == 0
    prerelease: seq[PrereleaseIdent]  ## empty == a *final* release (outranks any pre-release)

proc parseSemVer(s: string): SemVerParts =
  ## Split a normal version string into its release fields and pre-release
  ## identifiers (semver §9). The pre-release begins at the first '-'; build
  ## metadata ('+...') is dropped as it does not affect precedence (semver §10).
  var core = s
  let plus = core.find('+')
  if plus >= 0: core = core[0 ..< plus]
  let dash = core.find('-')
  let releaseStr = if dash >= 0: core[0 ..< dash] else: core
  let preStr = if dash >= 0: core[dash + 1 .. ^1] else: ""

  for part in releaseStr.split('.'):
    var n = 0
    discard parseInt(part, n)  # lenient leading-digit parse, as before
    result.release.add n

  if preStr.len > 0:
    for ident in preStr.split('.'):
      var n: int
      if ident.len > 0 and parseSaturatedNatural(ident, n) == ident.len:
        result.prerelease.add PrereleaseIdent(isNum: true, num: n)
      else:
        result.prerelease.add PrereleaseIdent(isNum: false, str: ident)

proc cmpIdent(a, b: PrereleaseIdent): int =
  ## Numeric identifiers rank below alphanumeric ones; numerics compare
  ## numerically, alphanumerics lexically (semver §11).
  if a.isNum and b.isNum: cmp(a.num, b.num)
  elif a.isNum: -1
  elif b.isNum: 1
  else: cmp(a.str, b.str)

proc cmpSemVer(a, b: SemVerParts): int =
  for i in 0 ..< max(a.release.len, b.release.len):
    let ai = if i < a.release.len: a.release[i] else: 0
    let bi = if i < b.release.len: b.release[i] else: 0
    if ai != bi: return cmp(ai, bi)
  # Release fields are equal → a final release outranks any of its pre-releases.
  if a.prerelease.len == 0 and b.prerelease.len == 0: return 0
  if a.prerelease.len == 0: return 1
  if b.prerelease.len == 0: return -1
  for i in 0 ..< min(a.prerelease.len, b.prerelease.len):
    let c = cmpIdent(a.prerelease[i], b.prerelease[i])
    if c != 0: return c
  # A longer set of pre-release fields wins when the shorter is a prefix.
  return cmp(a.prerelease.len, b.prerelease.len)

proc `<`*(ver: Version, ver2: Version): bool =
  # Handling for special versions such as "#head" or "#branch".
  if ver.isSpecial or ver2.isSpecial:
    # TODO: This may need to be reverted. See #311.
    if ver2.isSpecial and ($ver2).normalize == "#head":
      return ($ver).normalize != "#head"

    if not ver2.isSpecial:
      # `#aa111 < 1.1`
      return ($ver).normalize != "#head"

  # Handling for normal versions such as "0.1.0", "1.0" or "1.0.0-rc1".
  return cmpSemVer(parseSemVer(ver.version), parseSemVer(ver2.version)) < 0

proc `==`*(ver: Version, ver2: Version): bool =
  if ver.isSpecial or ver2.isSpecial:
    return ($ver).toLowerAscii() == ($ver2).toLowerAscii()
  return cmpSemVer(parseSemVer(ver.version), parseSemVer(ver2.version)) == 0

proc cmp*(a, b: Version): int =
  if a < b: -1
  elif a > b: 1
  else: 0

proc `<=`*(ver: Version, ver2: Version): bool =
  return (ver == ver2) or (ver < ver2)

proc `==`*(range1: VersionRange, range2: VersionRange): bool =
  if range1.kind != range2.kind : return false
  result = case range1.kind
  of verLater, verEarlier, verEqLater, verEqEarlier, verEq:
    range1.ver == range2.ver
  of verSpecial:
    range1.spe == range2.spe
  of verIntersect, verTilde, verCaret:
    range1.verILeft == range2.verILeft and range1.verIRight == range2.verIRight
  of verAny: true

proc withinRange*(ver: Version, ran: VersionRange): bool =
  # For special versions with speSemanticVersion, use that for comparison
  if ver.isSpecial and ver.speSemanticVersion.isSome:
    let semanticVer = newVersion(ver.speSemanticVersion.get)
    case ran.kind
    of verSpecial:
      return ver == ran.spe  # Must match exactly for special ranges
    else:
      return withinRange(semanticVer, ran)  # Use semantic version for comparisons
  
  # For special versions without speSemanticVersion (like #head), fall through
  # to use the normal comparison operators which already handle #head specially
  
  case ran.kind
  of verLater:
    return ver > ran.ver
  of verEarlier:
    return ver < ran.ver
  of verEqLater:
    return ver >= ran.ver
  of verEqEarlier:
    return ver <= ran.ver
  of verEq:
    return ver == ran.ver
  of verSpecial:
    # If the downloaded package has a normal version (e.g., 1.0.2), it satisfies
    # a special version range (e.g., #branch) because the branch was downloaded
    # and its nimble file contains that version.
    # For SAT constraint building, use satisfiesConstraint instead.
    return ver.isSpecial and ver == ran.spe or not ver.isSpecial
  of verIntersect, verTilde, verCaret:
    return withinRange(ver, ran.verILeft) and withinRange(ver, ran.verIRight)
  of verAny:
    return true

proc satisfiesConstraint*(ver: Version, ran: VersionRange): bool =
  ## Stricter version matching for SAT solver constraint building.
  ## Unlike withinRange, this requires exact matches for special version requirements.
  ## Use this when building SAT constraints; use withinRange for post-download validation.

  # For special versions with speSemanticVersion, use that for comparison
  if ver.isSpecial and ver.speSemanticVersion.isSome:
    let semanticVer = newVersion(ver.speSemanticVersion.get)
    case ran.kind
    of verSpecial:
      return ver == ran.spe  # Must match exactly for special ranges
    else:
      return withinRange(semanticVer, ran)  # Use semantic version for comparisons

  case ran.kind
  of verSpecial:
    # For SAT constraints: special version requirements require exact special version match.
    # Normal versions do NOT satisfy special requirements.
    return ver.isSpecial and ver == ran.spe
  of verAny:
    # Any version satisfies verAny, including special versions
    return true
  else:
    # For non-special requirements: special versions without speSemanticVersion
    # cannot satisfy normal version constraints. Only tagged versions or special
    # versions with known semantic version can satisfy >= X.Y.Z requirements.
    if ver.isSpecial:
      return false  # #head without semantic version cannot satisfy >= 0.2.4
    return withinRange(ver, ran)

proc withinRange*(versions: HashSet[Version], range: VersionRange): bool =
  ## Checks whether any of the versions from the set `versions` are in the range
  ## `range`.

  for version in versions:
    if withinRange(version, range):
      return true

proc contains*(ran: VersionRange, ver: Version): bool =
  return withinRange(ver, ran)

proc getNextIncompatibleVersion(version: Version, semver: bool): Version = 
  ## try to get next higher version to exclude according to semver semantic
  var numbers = version.version.split('.')
  let originalNumberLen = numbers.len
  while numbers.len < 3:
    numbers.add("0")
  var zeros = 0
  for n in 0 ..< 2:
    if numbers[n] == "0":
      inc(zeros)
    else: break
  var increasePosition = 0
  if (semver):
    if originalNumberLen > 1:
      case zeros
      of 0:
        increasePosition = 0
      of 1:
        increasePosition = 1
      else:
        increasePosition = 2
  else:
    increasePosition = max(0, originalNumberLen - 2)

  numbers[increasePosition] = $(numbers[increasePosition].parseInt() + 1)
  var zeroPosition = increasePosition + 1
  while zeroPosition < numbers.len:
    numbers[zeroPosition] = "0"
    inc(zeroPosition)
  result = newVersion(numbers.join("."))

proc makeRange*(version: Version, op: string): VersionRange =
  if version == notSetVersion:
    raise parseVersionError("A version needs to accompany the operator.")
  
  case op
  of ">":
    result = VersionRange(kind: verLater, ver: version)
  of "<":
    result = VersionRange(kind: verEarlier, ver: version)
  of ">=":
    result = VersionRange(kind: verEqLater, ver: version)
  of "<=":
    result = VersionRange(kind: verEqEarlier, ver: version)
  of "", "==":
    result = VersionRange(kind: verEq, ver: version)
  of "^=", "~=":
    let
      excludedVersion = getNextIncompatibleVersion(
        version, semver = (op == "^="))
      left = makeRange(version, ">=")
      right = makeRange(excludedVersion, "<")

    result =
      if op == "^=":
        VersionRange(kind: verCaret, verILeft: left, verIRight: right)
      else:
        VersionRange(kind: verTilde, verILeft: left, verIRight: right)
  else:
    raise parseVersionError("Invalid operator: " & op)

proc parseVersionRange*(s: string): VersionRange =
  # >= 1.5 & <= 1.8
  if s.len == 0:
    result = VersionRange(kind: verAny)
    return

  if s[0] == '#':
    result = VersionRange(kind: verSpecial, spe: newVersion(s))
    return

  var i = 0
  var op = ""
  var version = ""
  while i < s.len:
    case s[i]
    of '>', '<', '=', '~', '^':
      op.add(s[i])
    of '&':
      result = VersionRange(kind: verIntersect)
      result.verILeft = makeRange(newVersion(version), op)

      # Parse everything after &
      # Recursion <3
      result.verIRight = parseVersionRange(substr(s, i + 1))

      # Disallow more than one verIntersect. It's pointless and could lead to
      # major unpredictable mistakes.
      if result.verIRight.kind == verIntersect:
        raise parseVersionError(
          "Having more than one `&` in a version range is pointless")
      return
    of '0'..'9', '.', '-', '+', 'a'..'z', 'A'..'Z':
      # Digits and '.' form the release; '-'/alphanumerics form a pre-release
      # identifier and '+...' build metadata (semver §9-10), e.g. `1.0.0-rc1`.
      version.add(s[i])

    of ' ':
      # Make sure '0.9 8.03' is not allowed.
      if version != "" and i < s.len - 1:
        if s[i+1] in {'0'..'9', '.', '-', '+'} + Letters:
          raise parseVersionError(
            "Whitespace is not allowed in a version literal.")
    else:
      raise parseVersionError(
        "Unexpected char in version range '" & s & "': " & s[i])
    inc(i)
  result = makeRange(newVersion(version), op)

proc parseVersionRange*(version: Version): VersionRange =
  result = version.version.parseVersionRange

proc toVersionRange*(ver: Version): VersionRange =
  ## Converts a version to either a verEq or verSpecial VersionRange.
  result = 
    if ver.isSpecial:
      VersionRange(kind: verSpecial, spe: ver)
    else:
      VersionRange(kind: verEq, ver: ver)

proc discardFeatures*(req: string): string =
  #Remove the features from the string
  result = ""
  var ignore = ""
  discard scanf(req, "$*[$*]", result, ignore)

proc parseRequires*(req: string): PkgTuple =
  var req = discardFeatures(req)
  try:
    # For file:// URLs, treat the entire string as the name (no version parsing)
    if req.strip.isFileUrl:
      result.name = req.strip
      result.ver = VersionRange(kind: verAny)
    elif ' ' in req:
      var i = skipUntil(req, Whitespace)
      result.name = req[0 .. i].strip
      result.ver = parseVersionRange(req[i .. req.len-1])
    elif '#' in req:
      var i = skipUntil(req, {'#'})
      result.name = req[0 .. i-1]
      result.ver = parseVersionRange(req[i .. req.len-1])
    else:
      result.name = req.strip
      result.ver = VersionRange(kind: verAny)
  except ParseVersionError:
    raise nimbleError(
        "Unable to parse dependency version range: " & getCurrentExceptionMsg())

  # Expand forge aliases here
  if result.name.isForgeAlias:
    result.name = newForge(result.name).expand()

proc `$`*(verRange: VersionRange): string =
  case verRange.kind
  of verLater:
    result = "> "
  of verEarlier:
    result = "< "
  of verEqLater:
    result = ">= "
  of verEqEarlier:
    result = "<= "
  of verEq:
    result = ""
  of verSpecial:
    return $verRange.spe
  of verIntersect:
    return $verRange.verILeft & " & " & $verRange.verIRight
  of verTilde:
    return "~= " & $verRange.verILeft.ver
  of verCaret:
    return "^= " & $verRange.verILeft.ver
  of verAny:
    return "any version"

  result.add($verRange.ver)

proc initFromJson*(dst: var PkgTuple, jsonNode: JsonNode, jsonPath: var string) =
  dst = parseRequires(jsonNode.str)

proc toJsonHook*(src: PkgTuple): JsonNode =
  let ver = if src.ver.kind == verAny: "" else: $src.ver
  case src.ver.kind
  of verAny: newJString(src.name)
  of verSpecial: newJString(src.name & ver)
  else:
    newJString(src.name & " " & ver)

proc getSimpleString*(verRange: VersionRange): string =
  ## Gets a string with no special symbols and spaces. Used for dir name
  ## creation in tools.nim
  case verRange.kind
  of verSpecial:
    # Strip '#' for directory names - '#' causes issues with autoconf and shell scripts
    result = ($verRange.spe).strip(chars = {'#'})
  of verLater, verEarlier, verEqLater, verEqEarlier, verEq:
    result = $verRange.ver
  of verIntersect, verTilde, verCaret:
    result = getSimpleString(verRange.verILeft) & "_" &
        getSimpleString(verRange.verIRight)
  of verAny:
    result = ""

proc newVRAny*(): VersionRange =
  result = VersionRange(kind: verAny)

proc newVREarlier*(ver: Version): VersionRange =
  result = VersionRange(kind: verEarlier, ver: ver)

proc newVREq*(ver: Version): VersionRange =
  result = VersionRange(kind: verEq, ver: ver)

proc findLatest*(verRange: VersionRange,
        versions: OrderedTable[Version, string]): tuple[ver: Version, tag: string] =
  result = (newVersion(""), "")
  for ver, tag in versions:
    if not withinRange(ver, verRange): continue
    if ver > result.ver:
      result = (ver, tag)

proc `$`*(dep: PkgTuple): string =
  return dep.name & "@" & $dep.ver

proc hash*(pv: PkgTuple): Hash = hash($pv)
