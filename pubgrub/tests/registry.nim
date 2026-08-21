# Copyright (C) 2026 the Nim PubGrub authors. All rights reserved.
# BSD License. Look at license.txt for more info.

## An in-memory package universe for the solver tests.
##
## Versions are `major.minor` because every worked example in the PubGrub
## documentation leaves the patch at zero, and two components are enough for
## `^1.0.0` and `>=1.0.0 <2.0.0` to mean different things.

import std/[tables, options, algorithm]
import pubgrub/[ranges, solver]

type
  Ver* = object
    major*, minor*, patch*: int

  VerSet* = Ranges[Ver]
  Dep* = Dependency[string, VerSet]

  Registry* = object
    packages*: OrderedTable[string, seq[tuple[version: Ver, deps: seq[Dep]]]]

proc v*(major: int; minor = 0; patch = 0): Ver =
  Ver(major: major, minor: minor, patch: patch)

proc `<`*(a, b: Ver): bool =
  if a.major != b.major: a.major < b.major
  elif a.minor != b.minor: a.minor < b.minor
  else: a.patch < b.patch

proc `$`*(a: Ver): string =
  ## The patch is omitted when zero so the two-component goldens from the
  ## PubGrub documentation stay readable.
  result = $a.major & "." & $a.minor
  if a.patch != 0: result.add "." & $a.patch

proc caret*(major: int; minor = 0): VerSet =
  ## `^major.minor` - up to but excluding the next major.
  between(v(major, minor), v(major + 1, 0))

proc exactly*(major: int; minor = 0; patch = 0): VerSet =
  singleton(v(major, minor, patch))

proc anyVersion*(): VerSet = fullRange[Ver]()

proc dep*(name: string, versions: VerSet): Dep = (package: name, versions: versions)

proc add*(reg: var Registry, name: string, version: Ver, deps: varargs[Dep]) =
  reg.packages.mgetOrPut(name, @[]).add (version, @deps)

proc sortedVersions(reg: Registry, package: string): seq[Ver] =
  for (ver, _) in reg.packages[package]:
    result.add ver
  sort(result, proc (a, b: Ver): int = (if a < b: -1 elif b < a: 1 else: 0))

proc constraintOn(reg: Registry, package: string, version: Ver,
                  on: string): Option[VerSet] =
  ## What `package` at `version` requires of `on`, if anything.
  for (ver, deps) in reg.packages[package]:
    if ver == version:
      for d in deps:
        if d.package == on: return some(d.versions)
      return none(VerSet)

proc chooseVersion*(reg: Registry, package: string,
                    allowed: VerSet): Option[Ver] =
  ## Newest-first, which is what makes the examples backtrack the way the
  ## documentation describes.
  if package notin reg.packages: return none(Ver)
  for (ver, _) in reg.packages[package]:
    if allowed.contains(ver) and (result.isNone or result.get < ver):
      result = some(ver)

proc dependencies*(reg: Registry, package: string, version: Ver): seq[Dep] =
  for (ver, deps) in reg.packages[package]:
    if ver == version: return deps

proc dependencyRangeHook*(reg: Registry, package: string, version: Ver,
                          dependency: Dep): VerSet =
  ## Widens outwards from `version` for as long as the neighbouring versions
  ## declare the same constraint on the same package. A run that reaches the
  ## oldest or newest version is left open on that side, so a package whose
  ## every version agrees yields the full range - which is what makes the
  ## report say "every version of foo".
  let versions = reg.sortedVersions(package)
  var low, high: int
  for i, ver in versions:
    if ver == version:
      low = i
      high = i
      break
  proc agrees(i: int): bool =
    let c = reg.constraintOn(package, versions[i], dependency.package)
    c.isSome and c.get == dependency.versions
  while low > 0 and agrees(low - 1): dec low
  while high < versions.high and agrees(high + 1): inc high
  interval(
    if low == 0: noBound[Ver]() else: inclBound(versions[low]),
    if high == versions.high: noBound[Ver]() else: exclBound(versions[high + 1]))

proc versionCountHook*(reg: Registry, package: string, allowed: VerSet): int =
  if package notin reg.packages: return 0
  for (ver, _) in reg.packages[package]:
    if allowed.contains(ver): inc result

proc solution*(res: SolveResult[string, Ver, VerSet]): seq[string] =
  ## The solution as sorted `name version` strings, so tests can compare
  ## against a literal without depending on decision order.
  doAssert res.outcome == soSolved, "expected a solution, got a failure"
  for (package, version) in res.packages:
    result.add package & " " & $version
  sort result
