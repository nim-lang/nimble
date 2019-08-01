import algorithm, sequtils, strutils

type SemVer* = tuple[name: string, major: int, minor: int, patch: int]

proc parseInt*(s: string, default: int): int =
  ## Parse the integer or return the default value
  try:
    result = parseInt(s)
  except:
    result = default

proc parseIntCrazy*(s: string, default: int): int =
  ## Parse integers that may have some non-digit cruft attached to the end.
  ## Will parse the following:
  ##
  ##   54
  ##   127-foo
  ##
  if all(map(s, isDigit), proc(x: bool): bool = x):
    result = parseInt(s, default)
  else:
    # we have some non digit cruft at the end
    var digits = ""
    for c in s:
      if isDigit(c):
        digits.add c
    result = parseInt(digits, default)

proc parseVersion*(s: string): SemVer =
  if startsWith(s, "v"):
    let parts = split(s[1..^1], '.')
    if parts.len == 3:
      result = (s, parseInt(parts[0], 0), parseInt(parts[1], 0),
                parseIntCrazy(parts[2], 0))
    elif parts.len == 2:
      result = (s, parseInt(parts[0], 0), parseIntCrazy(parts[1], 0), 0)
    elif parts.len == 1:
      result = (s, parseIntCrazy(parts[0], 0), 0, 0)
  else:
    result = (s, 0, 0, 0)

proc cmp*(a, b: SemVer): int =
  result = cmp(a.major, b.major)
  if result == 0:
    result = cmp(a.minor, b.minor)
    if result == 0:
      result = cmp(a.patch, b.patch)
      if result == 0:
        result = cmp(a.name, b.name)

proc cmpDesc*(a, b: SemVer): int =
  cmp(b, a)

proc sortVersionDesc*(vers: seq[string]): seq[string] =
  var res = map(vers, parseVersion)
  sort(res, cmpDesc)
  result = map(res, proc(x: SemVer): string =
                      x.name)

when isMainModule:
  let cases: seq[string] = @["1.2.3", "1.2", "1.2.3-fiona",
                             "v2.3.4", "v2.3", "v2.3.4-wen",
                             "v3.4-sam", "v12-rutabaga"]
  for x in cases:
    echo $parseVersion(x)

  let t1: seq[string] = @["v0.2", "v0.3", "v0.4", "v0.6.1", "v0.1", "v0.6",
                          "v0.5"]
  var t1d = map(t1, parseVersion)
  # sort(t1d, cmp)
  sort(t1d, cmpDesc)
  for x in t1d:
    echo $x
