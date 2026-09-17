# Copyright (C) the Nimble contributors. All rights reserved.
# BSD License. Look at license.txt for more info.

## The bridge between Nimble's package universe and the standalone PubGrub
## library (`pubgrub/` at the repository root), used on the resolution
## *failure* path only: when the SAT solver finds no solution, PubGrub
## re-solves the same `pkgVersionTable` and its derivation-based report is
## appended to the error output. SAT remains the solver; a disagreement
## between the two is a solver bug and is surfaced as such.
##
## The translation mirrors `satisfiesConstraint` (version.nim) - the strict
## matcher SAT builds its constraints from - exactly:
##
## - Ordinary versions live on `TaggedRanges`' ordered line. `Version.<` is
##   total over non-special versions, and the translation never places a
##   special version on the line.
## - Special versions (`#head`, `#<commit>`) become tags, compared by their
##   lowercased spelling, which is how `Version.==` compares specials.
## - A `verSpecial` requirement admits exactly its own tag.
## - `verAny` admits everything, tags included.
## - An ordinary range admits the special versions of the *universe* whose
##   `speSemanticVersion` satisfies it - decided here, at translation time,
##   by asking `satisfiesConstraint` itself, so the two can never drift.
##
## Package names are lowercased throughout, matching Nimble's
## case-insensitive name comparisons. Feature requirements are deliberately
## not translated yet: the explanation covers the base dependency graph.

import std/[tables, options, strutils]
import ./[version, packageinfotypes]
import pubgrub

type
  NimbleTag* = object
    ## A special version as the solver's tag. Identity is the lowercased
    ## spelling only - `semver` (the `speSemanticVersion`, when known) rides
    ## along purely so reports can say `#b71392a (4.4.0)` and make a pin's
    ## conflict with an ordinary range self-evident.
    spelling*: string
    semver*: string

  NimbleTaggedVersion* = TaggedVersion[Version, NimbleTag]
  NimbleVersionSet* = TaggedRanges[Version, NimbleTag]
  NimbleDependency* = Dependency[string, NimbleVersionSet]

proc `==`*(a, b: NimbleTag): bool = a.spelling == b.spelling

proc `$`*(t: NimbleTag): string =
  if t.semver.len > 0: t.spelling & " (" & t.semver & ")"
  else: t.spelling

proc toTag(v: Version): NimbleTag =
  NimbleTag(spelling: ($v).toLowerAscii,
            semver: v.speSemanticVersion.get(""))

proc toTaggedVersion*(v: Version): NimbleTaggedVersion =
  if v.isSpecial:
    tagVersion[Version, NimbleTag](v.toTag)
  else:
    lineVersion[Version, NimbleTag](v)

proc lineSet(ran: VersionRange): Ranges[Version] =
  ## The ordered-line part of a requirement. Special requirements admit no
  ## point on the line at all.
  case ran.kind
  of verLater: greaterThan(ran.ver)
  of verEarlier: lessThan(ran.ver)
  of verEqLater: atLeast(ran.ver)
  of verEqEarlier: atMost(ran.ver)
  of verEq:
    if ran.ver.isSpecial: emptyRange[Version]() else: singleton(ran.ver)
  of verAny: fullRange[Version]()
  of verIntersect, verTilde, verCaret:
    intersection(lineSet(ran.verILeft), lineSet(ran.verIRight))
  of verSpecial: emptyRange[Version]()

proc toVersionSet*(ran: VersionRange,
                   universe: openArray[Version] = []): NimbleVersionSet =
  ## Translates one requirement into a version set. `universe` is the list of
  ## versions actually available for the required package; it is what decides
  ## which special versions an ordinary range admits (via their
  ## `speSemanticVersion`). A special version not in the universe is not in
  ## the set - which is all a solver over that universe can observe.
  case ran.kind
  of verSpecial:
    # The requirement's own Version rarely carries a semantic version; the
    # matching universe entry usually does. Borrow it so the requirement
    # renders annotated too.
    var tag = toTag(ran.spe)
    if tag.semver.len == 0:
      for v in universe:
        if v.isSpecial:
          let candidate = toTag(v)
          if candidate == tag and candidate.semver.len > 0:
            tag.semver = candidate.semver
            break
    onlyTags[Version, NimbleTag](@[tag])
  of verAny:
    taggedFull[Version, NimbleTag]()
  else:
    var tags: seq[NimbleTag]
    for v in universe:
      if v.isSpecial and satisfiesConstraint(v, ran):
        tags.add v.toTag
    tagged[Version, NimbleTag](lineSet(ran), tags)

proc singleton*(v: Version): NimbleVersionSet =
  ## `V → VS` for the solver's `mixin singleton`: the set holding exactly
  ## this version, on whichever dimension it lives.
  singleton(toTaggedVersion(v))

# ------------------------------------------------------------------ provider

type
  PubGrubUniverse* = object
    ## `pkgVersionTable` re-keyed by lowercased name, plus the root's identity.
    packages: Table[string, PackageVersions]
    rootName: string
    rootVersion: Version

proc initPubGrubUniverse*(pkgVersionTable: Table[string, PackageVersions]):
    PubGrubUniverse =
  for name, pv in pkgVersionTable:
    result.packages[name.toLowerAscii] = pv
    for mi in pv.versions:
      if mi.isRoot:
        result.rootName = name.toLowerAscii
        result.rootVersion = mi.version

proc availableVersions(u: PubGrubUniverse, package: string): seq[Version] =
  if package in u.packages:
    for mi in u.packages[package].versions:
      result.add mi.version

proc chooseVersion*(u: PubGrubUniverse, package: string,
                    allowed: NimbleVersionSet): Option[Version] =
  ## Newest-first, like the SAT solver's default preference. `Version.<`
  ## already prefers `#head` over everything and tagged releases over other
  ## specials, so it doubles as the preference order here.
  if package notin u.packages: return none(Version)
  for mi in u.packages[package].versions:
    if allowed.contains(toTaggedVersion(mi.version)) and
        (result.isNone or result.get < mi.version):
      result = some(mi.version)

proc dependencies*(u: PubGrubUniverse, package: string,
                   version: Version): seq[NimbleDependency] =
  if package notin u.packages: return
  for mi in u.packages[package].versions:
    if mi.version == version:
      for (depName, depRange) in mi.requires:
        let key = depName.toLowerAscii
        result.add (package: key,
                    versions: toVersionSet(depRange, u.availableVersions(key)))
      return

proc constraintOn(u: PubGrubUniverse, mi: PackageMinimalInfo,
                  package: string): Option[NimbleVersionSet] =
  for (depName, depRange) in mi.requires:
    if depName.toLowerAscii == package:
      return some(toVersionSet(depRange, u.availableVersions(package)))

proc dependencyRangeHook*(u: PubGrubUniverse, package: string,
                          version: Version,
                          dependency: NimbleDependency): NimbleVersionSet =
  ## Nimble universes routinely mix ordered and special versions, so no
  ## interval widening: either every version of `package` declares this exact
  ## constraint (then it holds for all of them, and the report says "every
  ## version of ..."), or it is stated for the one version it was read from.
  for mi in u.packages[package].versions:
    let c = u.constraintOn(mi, dependency.package)
    if c.isNone or c.get != dependency.versions:
      return singleton(toTaggedVersion(version))
  taggedFull[Version, NimbleTag]()

proc packageExistsHook*(u: PubGrubUniverse, package: string): bool =
  ## Whether the universe knows the package at all. Lets the report say
  ## "foo doesn't exist" instead of "no versions of foo match ..." - the
  ## difference between a typo and an unsatisfiable constraint.
  package in u.packages

proc versionCountHook*(u: PubGrubUniverse, package: string,
                       allowed: NimbleVersionSet): int =
  if package notin u.packages: return 0
  for mi in u.packages[package].versions:
    if allowed.contains(toTaggedVersion(mi.version)): inc result

# ------------------------------------------------------------ failure path

proc explainSolveFailure*(pkgVersionTable: Table[string, PackageVersions]):
    tuple[foundSolution: bool, explanation: string] =
  ## Re-solves the universe the SAT solver failed on. On agreement (also
  ## unsolvable) the explanation is the PubGrub report; on disagreement
  ## `foundSolution` is true and the caller should flag a solver bug. Never
  ## raises: an error in the bridge must not mask the original failure.
  try:
    let u = initPubGrubUniverse(pkgVersionTable)
    if u.rootName.len == 0: return (false, "")
    let res = solve(u, u.rootName, u.rootVersion)
    case res.outcome
    of soUnsolvable: (false, report(res.failure, u.rootName))
    of soSolved: (true, "")
  except CatchableError:
    (false, "")
