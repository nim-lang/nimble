# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

## Module for handling versions and version ranges such as ``>= 1.0 & <= 1.5``
import strutils, tables, hashes, parseutils
type
  Version* = distinct string

  VersionRangeEnum* = enum
    verLater, # > V
    verEarlier, # < V
    verEqLater, # >= V -- Equal or later
    verEqEarlier, # <= V -- Equal or earlier
    verIntersect, # > V & < V
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
    of verIntersect:
      verILeft, verIRight: VersionRange
    of verAny:
      nil

  ## Tuple containing package name and version range.
  PkgTuple* = tuple[name: string, ver: VersionRange]

  ParseVersionError* = object of ValueError
  NimbleError* = object of CatchableError
    hint*: string

proc `$`*(ver: Version): string {.borrow.}

proc hash*(ver: Version): Hash {.borrow.}

proc newVersion*(ver: string): Version =
  doAssert(ver.len == 0 or ver[0] in {'#', '\0'} + Digits,
           "Wrong version: " & ver)
  return Version(ver)

proc isSpecial*(ver: Version): bool =
  return ($ver).len > 0 and ($ver)[0] == '#'

proc `<`*(ver: Version, ver2: Version): bool =
  # Handling for special versions such as "#head" or "#branch".
  if ver.isSpecial or ver2.isSpecial:
    # TODO: This may need to be reverted. See #311.
    if ver2.isSpecial and ($ver2).normalize == "#head":
      return ($ver).normalize != "#head"

    if not ver2.isSpecial:
      # `#aa111 < 1.1`
      return ($ver).normalize != "#head"

  # Handling for normal versions such as "0.1.0" or "1.0".
  var sVer = string(ver).split('.')
  var sVer2 = string(ver2).split('.')
  for i in 0..max(sVer.len, sVer2.len)-1:
    var sVerI = 0
    if i < sVer.len:
      discard parseInt(sVer[i], sVerI)
    var sVerI2 = 0
    if i < sVer2.len:
      discard parseInt(sVer2[i], sVerI2)
    if sVerI < sVerI2:
      return true
    elif sVerI == sVerI2:
      discard
    else:
      return false

proc `==`*(ver: Version, ver2: Version): bool =
  if ver.isSpecial or ver2.isSpecial:
    return ($ver).toLowerAscii() == ($ver2).toLowerAscii()

  var sVer = string(ver).split('.')
  var sVer2 = string(ver2).split('.')
  for i in 0..max(sVer.len, sVer2.len)-1:
    var sVerI = 0
    if i < sVer.len:
      discard parseInt(sVer[i], sVerI)
    var sVerI2 = 0
    if i < sVer2.len:
      discard parseInt(sVer2[i], sVerI2)
    if sVerI == sVerI2:
      result = true
    else:
      return false

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
  of verIntersect:
    range1.verILeft == range2.verILeft and range1.verIRight == range2.verIRight
  of verAny: true

proc withinRange*(ver: Version, ran: VersionRange): bool =
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
    return ver == ran.spe
  of verIntersect:
    return withinRange(ver, ran.verILeft) and withinRange(ver, ran.verIRight)
  of verAny:
    return true

proc contains*(ran: VersionRange, ver: Version): bool =
  return withinRange(ver, ran)

proc makeRange*(version: string, op: string): VersionRange =
  if version == "":
    raise newException(ParseVersionError,
        "A version needs to accompany the operator.")
  case op
  of ">":
    result = VersionRange(kind: verLater)
  of "<":
    result = VersionRange(kind: verEarlier)
  of ">=":
    result = VersionRange(kind: verEqLater)
  of "<=":
    result = VersionRange(kind: verEqEarlier)
  of "", "==":
    result = VersionRange(kind: verEq)
  else:
    raise newException(ParseVersionError, "Invalid operator: " & op)
  result.ver = Version(version)

proc parseVersionRange*(s: string): VersionRange =
  # >= 1.5 & <= 1.8
  if s.len == 0:
    result = VersionRange(kind: verAny)
    return

  if s[0] == '#':
    result = VersionRange(kind: verSpecial)
    result.spe = s.Version
    return

  var i = 0
  var op = ""
  var version = ""
  while i < s.len:
    case s[i]
    of '>', '<', '=':
      op.add(s[i])
    of '&':
      result = VersionRange(kind: verIntersect)
      result.verILeft = makeRange(version, op)

      # Parse everything after &
      # Recursion <3
      result.verIRight = parseVersionRange(substr(s, i + 1))

      # Disallow more than one verIntersect. It's pointless and could lead to
      # major unpredictable mistakes.
      if result.verIRight.kind == verIntersect:
        raise newException(ParseVersionError,
            "Having more than one `&` in a version range is pointless")

      return

    of '0'..'9', '.':
      version.add(s[i])

    of ' ':
      # Make sure '0.9 8.03' is not allowed.
      if version != "" and i < s.len - 1:
        if s[i+1] in {'0'..'9', '.'}:
          raise newException(ParseVersionError,
              "Whitespace is not allowed in a version literal.")

    else:
      raise newException(ParseVersionError,
          "Unexpected char in version range '" & s & "': " & s[i])
    inc(i)
  result = makeRange(version, op)

proc toVersionRange*(ver: Version): VersionRange =
  ## Converts a version to either a verEq or verSpecial VersionRange.
  new(result)
  if ver.isSpecial:
    result = VersionRange(kind: verSpecial)
    result.spe = ver
  else:
    result = VersionRange(kind: verEq)
    result.ver = ver

proc parseRequires*(req: string): PkgTuple =
  try:
    if ' ' in req:
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
    raise newException(NimbleError,
        "Unable to parse dependency version range: " & getCurrentExceptionMsg())

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
  of verAny:
    return "any version"

  result.add(string(verRange.ver))

proc getSimpleString*(verRange: VersionRange): string =
  ## Gets a string with no special symbols and spaces. Used for dir name
  ## creation in tools.nim
  case verRange.kind
  of verSpecial:
    result = $verRange.spe
  of verLater, verEarlier, verEqLater, verEqEarlier, verEq:
    result = $verRange.ver
  of verIntersect:
    result = getSimpleString(verRange.verILeft) & "_" &
        getSimpleString(verRange.verIRight)
  of verAny:
    result = ""

proc newVRAny*(): VersionRange =
  result = VersionRange(kind: verAny)

proc newVREarlier*(ver: string): VersionRange =
  result = VersionRange(kind: verEarlier)
  result.ver = newVersion(ver)

proc newVREq*(ver: string): VersionRange =
  result = VersionRange(kind: verEq)
  result.ver = newVersion(ver)

proc findLatest*(verRange: VersionRange,
        versions: OrderedTable[Version, string]): tuple[ver: Version, tag: string] =
  result = (newVersion(""), "")
  for ver, tag in versions:
    if not withinRange(ver, verRange): continue
    if ver > result.ver:
      result = (ver, tag)

proc `$`*(dep: PkgTuple): string =
  return dep.name & "@" & $dep.ver

when isMainModule:
  doAssert(newVersion("1.0") < newVersion("1.4"))
  doAssert(newVersion("1.0.1") > newVersion("1.0"))
  doAssert(newVersion("1.0.6") <= newVersion("1.0.6"))
  doAssert(not withinRange(newVersion("0.1.0"), parseVersionRange("> 0.1")))
  doAssert(not (newVersion("0.1.0") < newVersion("0.1")))
  doAssert(not (newVersion("0.1.0") > newVersion("0.1")))
  doAssert(newVersion("0.1.0") < newVersion("0.1.0.0.1"))
  doAssert(newVersion("0.1.0") <= newVersion("0.1"))

  var inter1 = parseVersionRange(">= 1.0 & <= 1.5")
  doAssert(inter1.kind == verIntersect)
  var inter2 = parseVersionRange("1.0")
  doAssert(inter2.kind == verEq)
  doAssert(parseVersionRange("== 3.4.2") == parseVersionRange("3.4.2"))

  doAssert(not withinRange(newVersion("1.5.1"), inter1))
  doAssert(withinRange(newVersion("1.0.2.3.4.5.6.7.8.9.10.11.12"), inter1))

  doAssert(newVersion("1") == newVersion("1"))
  doAssert(newVersion("1.0.2.4.6.1.2.123") == newVersion("1.0.2.4.6.1.2.123"))
  doAssert(newVersion("1.0.2") != newVersion("1.0.2.4.6.1.2.123"))
  doAssert(newVersion("1.0.3") != newVersion("1.0.2"))

  doAssert(not (newVersion("") < newVersion("0.0.0")))
  doAssert(newVersion("") < newVersion("1.0.0"))
  doAssert(newVersion("") < newVersion("0.1.0"))

  var versions = toOrderedTable[Version, string]({
    newVersion("0.1.1"): "v0.1.1",
    newVersion("0.2.3"): "v0.2.3",
    newVersion("0.5"): "v0.5"
  })
  doAssert findLatest(parseVersionRange(">= 0.1 & <= 0.4"), versions) ==
      (newVersion("0.2.3"), "v0.2.3")

  # TODO: Allow these in later versions?
  #doAssert newVersion("0.1-rc1") < newVersion("0.2")
  #doAssert newVersion("0.1-rc1") < newVersion("0.1")

  # Special tests
  doAssert newVersion("#ab26sgdt362") != newVersion("#qwersaggdt362")
  doAssert newVersion("#ab26saggdt362") == newVersion("#ab26saggdt362")
  doAssert newVersion("#head") == newVersion("#HEAD")
  doAssert newVersion("#head") == newVersion("#head")

  var sp = parseVersionRange("#ab26sgdt362")
  doAssert newVersion("#ab26sgdt362") in sp
  doAssert newVersion("#ab26saggdt362") notin sp

  doAssert newVersion("#head") in parseVersionRange("#head")

  # We assume that #head > 0.1.0, in practice this shouldn't be a problem.
  doAssert(newVersion("#head") > newVersion("0.1.0"))
  doAssert(not(newVersion("#head") > newVersion("#head")))
  doAssert(withinRange(newVersion("#head"), parseVersionRange(">= 0.5.0")))
  doAssert newVersion("#a111") < newVersion("#head")
  # We assume that all other special versions are not higher than a normal
  # version.
  doAssert newVersion("#a111") < newVersion("1.1")

  # An empty version range should give verAny
  doAssert parseVersionRange("").kind == verAny

  # toVersionRange tests
  doAssert toVersionRange(newVersion("#head")).kind == verSpecial
  doAssert toVersionRange(newVersion("0.2.0")).kind == verEq

  # Something raised on IRC
  doAssert newVersion("1") == newVersion("1.0")

  echo("Everything works!")
