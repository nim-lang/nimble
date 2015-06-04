# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

## Module for handling versions and version ranges such as ``>= 1.0 & <= 1.5``
import strutils, tables, hashes, parseutils
type
  Version* = distinct string
  Special* = distinct string

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
      spe*: Special
    of verIntersect:
      verILeft, verIRight: VersionRange
    of verAny:
      nil

  ParseVersionError* = object of ValueError

proc newVersion*(ver: string): Version = return Version(ver)
proc newSpecial*(spe: string): Special = return Special(spe)

proc `$`*(ver: Version): string {.borrow.}

proc hash*(ver: Version): THash {.borrow.}

proc `$`*(ver: Special): string {.borrow.}

proc hash*(ver: Special): THash {.borrow.}

proc `<`*(ver: Version, ver2: Version): bool =
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

proc `==`*(spe: Special, spe2: Special): bool =
  return ($spe).toLower() == ($spe2).toLower()

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
    return false
  of verIntersect:
    return withinRange(ver, ran.verILeft) and withinRange(ver, ran.verIRight)
  of verAny:
    return true

proc withinRange*(spe: Special, ran: VersionRange): bool =
  case ran.kind
  of verLater, verEarlier, verEqLater, verEqEarlier, verEq, verIntersect:
    return false
  of verSpecial:
    return spe == ran.spe
  of verAny:
    return true

proc contains*(ran: VersionRange, ver: Version): bool =
  return withinRange(ver, ran)

proc contains*(ran: VersionRange, spe: Special): bool =
  return withinRange(spe, ran)

proc makeRange*(version: string, op: string): VersionRange =
  new(result)
  if version == "":
    raise newException(ParseVersionError,
        "A version needs to accompany the operator.")
  case op
  of ">":
    result.kind = verLater
  of "<":
    result.kind = verEarlier
  of ">=":
    result.kind = verEqLater
  of "<=":
    result.kind = verEqEarlier
  of "":
    result.kind = verEq
  else:
    raise newException(ParseVersionError, "Invalid operator: " & op)
  result.ver = Version(version)

proc parseVersionRange*(s: string): VersionRange =
  # >= 1.5 & <= 1.8
  new(result)
  if s[0] == '#':
    result.kind = verSpecial
    result.spe = s[1 .. s.len-1].Special
    return

  var i = 0
  var op = ""
  var version = ""
  while true:
    case s[i]
    of '>', '<', '=':
      op.add(s[i])
    of '&':
      result.kind = verIntersect
      result.verILeft = makeRange(version, op)

      # Parse everything after &
      # Recursion <3
      result.verIRight = parseVersionRange(substr(s, i + 1))

      # Disallow more than one verIntersect. It's pointless and could lead to
      # major unpredictable mistakes.
      if result.verIRight.kind == verIntersect:
        raise newException(ParseVersionError,
            "Having more than one `&` in a version range is pointless")

      break

    of '0'..'9', '.':
      version.add(s[i])

    of '\0':
      result = makeRange(version, op)
      break

    of ' ':
      # Make sure '0.9 8.03' is not allowed.
      if version != "" and i < s.len:
        if s[i+1] in {'0'..'9', '.'}:
          raise newException(ParseVersionError,
              "Whitespace is not allowed in a version literal.")

    else:
      raise newException(ParseVersionError,
          "Unexpected char in version range: " & s[i])
    inc(i)

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
    return "#" & $verRange.spe
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
  new(result)
  result.kind = verAny

proc newVREarlier*(ver: string): VersionRange =
  new(result)
  result.kind = verEarlier
  result.ver = newVersion(ver)

proc newVREq*(ver: string): VersionRange =
  new(result)
  result.kind = verEq
  result.ver = newVersion(ver)

proc findLatest*(verRange: VersionRange,
        versions: Table[Version, string]): tuple[ver: Version, tag: string] =
  result = (newVersion(""), "")
  for ver, tag in versions:
    if not withinRange(ver, verRange): continue
    if ver > result.ver:
      result = (ver, tag)

when isMainModule:
  doAssert(newVersion("1.0") < newVersion("1.4"))
  doAssert(newVersion("1.0.1") > newVersion("1.0"))
  doAssert(newVersion("1.0.6") <= newVersion("1.0.6"))
  #doAssert(not withinRange(newVersion("0.1.0"), parseVersionRange("> 0.1")))
  doAssert(not (newVersion("0.1.0") < newVersion("0.1")))
  doAssert(not (newVersion("0.1.0") > newVersion("0.1")))
  doAssert(newVersion("0.1.0") < newVersion("0.1.0.0.1"))
  doAssert(newVersion("0.1.0") <= newVersion("0.1"))

  var inter1 = parseVersionRange(">= 1.0 & <= 1.5")
  var inter2 = parseVersionRange("1.0")
  doAssert(inter2.kind == verEq)
  #echo(parseVersionRange(">= 0.8 0.9"))

  doAssert(not withinRange(newVersion("1.5.1"), inter1))
  doAssert(withinRange(newVersion("1.0.2.3.4.5.6.7.8.9.10.11.12"), inter1))

  doAssert(newVersion("1") == newVersion("1"))
  doAssert(newVersion("1.0.2.4.6.1.2.123") == newVersion("1.0.2.4.6.1.2.123"))
  doAssert(newVersion("1.0.2") != newVersion("1.0.2.4.6.1.2.123"))
  doAssert(newVersion("1.0.3") != newVersion("1.0.2"))

  doAssert(not (newVersion("") < newVersion("0.0.0")))
  doAssert(newVersion("") < newVersion("1.0.0"))
  doAssert(newVersion("") < newVersion("0.1.0"))

  var versions = toTable[Version, string]({newVersion("0.1.1"): "v0.1.1",
      newVersion("0.2.3"): "v0.2.3", newVersion("0.5"): "v0.5"})
  doAssert findLatest(parseVersionRange(">= 0.1 & <= 0.4"), versions) ==
      (newVersion("0.2.3"), "v0.2.3")

  # TODO: Allow these in later versions?
  #doAssert newVersion("0.1-rc1") < newVersion("0.2")
  #doAssert newVersion("0.1-rc1") < newVersion("0.1")

  # Special tests
  doAssert newSpecial("ab26sgdt362") != newSpecial("ab26saggdt362")
  doAssert newSpecial("ab26saggdt362") == newSpecial("ab26saggdt362")
  doAssert newSpecial("head") == newSpecial("HEAD")
  doAssert newSpecial("head") == newSpecial("head")

  var sp = parseVersionRange("#ab26sgdt362")
  doAssert newSpecial("ab26sgdt362") in sp
  doAssert newSpecial("ab26saggdt362") notin sp

  echo("Everything works!")
