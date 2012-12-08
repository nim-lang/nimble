## Module for handling versions and version ranges such as ``>= 1.0 & <= 1.5``
import strutils
type
  TVersion* = distinct string

  TVersionRangeEnum* = enum
    verLater, # > V
    verEarlier, # < V
    verEqLater, # >= V -- Equal or later
    verEqEarlier, # <= V -- Equal or earlier
    verIntersect, # > V & < V
    verEq, # V
    verAny # *

  PVersionRange* = ref TVersionRange
  TVersionRange* = object
    case kind*: TVersionRangeEnum
    of verLater, verEarlier, verEqLater, verEqEarlier, verEq:
      ver*: TVersion
    of verIntersect:
      verILeft, verIRight: PVersionRange
    of verAny:
      nil

  EParseVersion* = object of EInvalidValue

proc newVersion*(ver: string): TVersion = return TVersion(ver)

proc `$`*(ver: TVersion): String {.borrow.}

proc `<`*(ver: TVersion, ver2: TVersion): Bool =
  var sVer = string(ver).split('.')
  var sVer2 = string(ver2).split('.')
  for i in 0..max(sVer.len, sVer2.len)-1:
    if i > sVer.len-1:
      return True
    elif i > sVer2.len-1:
      return False

    var sVerI = parseInt(sVer[i])
    var sVerI2 = parseInt(sVer2[i])
    if sVerI < sVerI2:
      return True
    elif sVerI == sVerI2:
      nil
    else:
      return False

proc `==`*(ver: TVersion, ver2: TVersion): Bool {.borrow.}

proc `<=`*(ver: TVersion, ver2: TVersion): Bool =
  return (ver == ver2) or (ver < ver2)

proc withinRange*(ver: TVersion, ran: PVersionRange): Bool =
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
  of verIntersect:
    return withinRange(ver, ran.verILeft) and withinRange(ver, ran.verIRight)
  of verAny:
    return True

proc makeRange*(version: string, op: string): PVersionRange =
  new(result)
  if version == "":
    raise newException(EParseVersion, "A version needs to accompany the operator.")
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
    raise newException(EParseVersion, "Invalid operator: " & op)
  result.ver = TVersion(version)

proc parseVersionRange*(s: string): PVersionRange =
  # >= 1.5 & <= 1.8
  new(result)

  var i = 0
  var op = ""
  var version = ""
  while True:
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
      # major unknown mistakes.
      if result.verIRight.kind == verIntersect:
        raise newException(EParseVersion,
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
          raise newException(EParseVersion, "Whitespace is not allowed in a version literal.")

    else:
      raise newException(EParseVersion, "Unexpected char in version range: " & s[i])
    inc(i)

proc `$`*(verRange: PVersionRange): String =
  echo(verRange.repr())
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
  of verIntersect:
    return $verRange.verILeft & " & " & $verRange.verIRight
  of verAny:
    return "Any"

  result.add(string(verRange.ver))

proc newVRAny*(): PVersionRange =
  new(result)
  result.kind = verAny

proc newVREarlier*(ver: String): PVersionRange =
  new(result)
  result.kind = verEarlier
  result.ver = newVersion(ver)

proc newVREq*(ver: string): PVersionRange =
  new(result)
  result.kind = verEq
  result.ver = newVersion(ver)

when isMainModule:
  doAssert(newVersion("1.0") < newVersion("1.4"))
  doAssert(newVersion("1.0.1") > newVersion("1.0"))
  doAssert(newVersion("1.0.6") <= newVersion("1.0.6"))

  var inter1 = parseVersionRange(">= 1.0 & <= 1.5")
  var inter2 = parseVersionRange("1.0")
  doAssert(inter2.kind == verEq)
  #echo(parseVersionRange(">= 0.8 0.9"))

  doAssert(not withinRange(newVersion("1.5.1"), inter1))
  doAssert(withinRange(newVersion("1.0.2.3.4.5.6.7.8.9.10.11.12"), inter1))

  doAssert(newVersion("1") == newVersion("1"))

  echo("Everything works!")