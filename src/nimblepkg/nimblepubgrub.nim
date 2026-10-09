# Copyright (C) the Nimble contributors. All rights reserved.
# BSD License. Look at license.txt for more info.

## The PubGrub solver, `nimblesat`'s counterpart: the bridge between Nimble's
## package universe and the standalone PubGrub library (`pubgrub/` at the
## repository root). It serves two callers:
##
## - `--solver:pubgrub` (`pubGrubPackages`), where PubGrub resolves the
##   dependency graph;
## - the failure path of the default SAT solver: when SAT finds no solution,
##   PubGrub re-solves the same `pkgVersionTable` and its derivation-based
##   report becomes the error. A disagreement between the two is a solver
##   bug and is surfaced as such.
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
## case-insensitive name comparisons. Like SAT, the bridge reads `requires`
## only: the active features have already been folded into the root's
## requirements by then (`enableFeatures`).

import std/[tables, options, strutils]
import ./[version, packageinfotypes]
from ./options import Options, ResolutionAlgorithm, raMaxVer, raMinVer
from ./cli import displayInfo, LowPriority
from ./versiondiscovery import addDiscoveryErrors
import pubgrub

type
  NimbleTag* = object
    ## A special version as the solver's tag. Identity is the lowercased
    ## spelling only - `semver` (the `speSemanticVersion`, when known) rides
    ## along purely so reports can say `#b71392a (4.4.0)` and make a pin's
    ## conflict with an ordinary range self-evident.
    spelling*: string
    semver*: string

  LineVersion* = ref object
    ## An ordinary version as the solver keeps it on its ordered line: the
    ## `Version` with its semantic-version parts parsed once. The range
    ## algebra compares bounds constantly, and `Version.<`/`==` re-parse both
    ## strings on every call. A `ref`, so the algebra's copies are cheap.
    version: Version
    parts: SemVerParts

  NimbleTaggedVersion* = TaggedVersion[LineVersion, NimbleTag]
  NimbleVersionSet* = TaggedRanges[LineVersion, NimbleTag]
  NimbleDependency* = Dependency[string, NimbleVersionSet]

proc `==`*(a, b: NimbleTag): bool = a.spelling == b.spelling

proc `$`*(t: NimbleTag): string =
  if t.semver.len > 0: t.spelling & " (" & t.semver & ")"
  else: t.spelling

proc toLineVersion*(v: Version): LineVersion =
  ## `v` placed on the ordered line. Only for ordinary versions: a special
  ## version is a tag (`toTaggedVersion`).
  LineVersion(version: v, parts: parseSemVer($v))

proc `<`*(a, b: LineVersion): bool = cmpSemVer(a.parts, b.parts) < 0
proc `==`*(a, b: LineVersion): bool = cmpSemVer(a.parts, b.parts) == 0
proc `$`*(v: LineVersion): string = $v.version

proc toTag(v: Version): NimbleTag =
  NimbleTag(spelling: ($v).toLowerAscii,
            semver: v.speSemanticVersion.get(""))

proc toTaggedVersion*(v: Version): NimbleTaggedVersion =
  if v.isSpecial:
    tagVersion[LineVersion, NimbleTag](v.toTag)
  else:
    lineVersion[LineVersion, NimbleTag](toLineVersion(v))

proc lineSet(ran: VersionRange): Ranges[LineVersion] =
  ## The ordered-line part of a requirement. Special requirements admit no
  ## point on the line at all.
  case ran.kind
  of verLater: greaterThan(toLineVersion(ran.ver))
  of verEarlier: lessThan(toLineVersion(ran.ver))
  of verEqLater: atLeast(toLineVersion(ran.ver))
  of verEqEarlier: atMost(toLineVersion(ran.ver))
  of verEq:
    if ran.ver.isSpecial: emptyRange[LineVersion]()
    else: singleton(toLineVersion(ran.ver))
  of verAny: fullRange[LineVersion]()
  of verIntersect, verTilde, verCaret:
    intersection(lineSet(ran.verILeft), lineSet(ran.verIRight))
  of verSpecial: emptyRange[LineVersion]()

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
    onlyTags[LineVersion, NimbleTag](@[tag])
  of verAny:
    taggedFull[LineVersion, NimbleTag]()
  else:
    var tags: seq[NimbleTag]
    for v in universe:
      if v.isSpecial and satisfiesConstraint(v, ran):
        tags.add v.toTag
    tagged[LineVersion, NimbleTag](lineSet(ran), tags)

proc singleton*(v: Version): NimbleVersionSet =
  ## `V → VS` for the solver's `mixin singleton`: the set holding exactly
  ## this version, on whichever dimension it lives.
  singleton(toTaggedVersion(v))

# ------------------------------------------------------------------ provider

type
  Entry = object
    ## One listed version of a package, prepared for the search: where it
    ## sits in the version universe, parsed once, and - from the first time
    ## the package is needed - its requirements as version sets.
    version: Version
    tagged: NimbleTaggedVersion
    requires: seq[PkgTuple]
    dependencies: seq[NimbleDependency]

  PreparedPackage = object
    entries: seq[Entry]
    specials: seq[Version]
      ## The special versions listed: they decide what an ordinary range on
      ## this package admits (`toVersionSet`).
    translated: bool

  Prepared = object
    index: Table[string, int]  ## lowercased name -> `packages`
    packages: seq[PreparedPackage]

  PubGrubUniverse* = object
    ## `pkgVersionTable` prepared for the search - re-keyed by lowercased
    ## name, every version parsed once, requirements translated once - plus
    ## the root's identity and the version preference to search with. The
    ## preparation sits behind a `ref` so the provider procs can fill it in
    ## as the search reaches each package.
    data: ref Prepared
    rootName: string
    rootVersion: Version
    algorithm: ResolutionAlgorithm

proc initPubGrubUniverse*(pkgVersionTable: Table[string, PackageVersions],
                          algorithm = raMaxVer): PubGrubUniverse =
  result.algorithm = algorithm
  result.data = new Prepared
  for name, pv in pkgVersionTable:
    let key = name.toLowerAscii
    var package = PreparedPackage()
    for mi in pv.versions:
      package.entries.add Entry(version: mi.version,
                                tagged: toTaggedVersion(mi.version),
                                requires: mi.requires)
      if mi.version.isSpecial:
        package.specials.add mi.version
      if mi.isRoot:
        result.rootName = key
        result.rootVersion = mi.version
    result.data.index[key] = result.data.packages.len
    result.data.packages.add package

proc packageIndex(u: PubGrubUniverse, package: string): int =
  u.data.index.getOrDefault(package, -1)

proc translate(u: PubGrubUniverse, i: int) =
  ## Translates the requirements of every version of package `i` the first
  ## time any of them is needed; afterwards they are only looked up.
  if u.data.packages[i].translated: return
  for e in u.data.packages[i].entries.mitems:
    for (depName, depRange) in e.requires:
      let key = depName.toLowerAscii
      let d = u.packageIndex(key)
      let versions =
        if d >= 0: toVersionSet(depRange, u.data.packages[d].specials)
        else: toVersionSet(depRange)
      e.dependencies.add (package: key, versions: versions)
  u.data.packages[i].translated = true

proc prefers(u: PubGrubUniverse, a, b: Entry): bool =
  ## Whether `a` is tried before `b` - the SAT solver's order (`cmp` in
  ## nimblesat). Special versions come last whatever `Version.<` says (it
  ## ranks `#head` above every release): a range a pinned commit or `#head`
  ## happens to satisfy should still get a tagged release. Within each kind,
  ## newest first, or oldest first under `--minVer`.
  let aSpecial = a.tagged.kind == tvTag
  if aSpecial != (b.tagged.kind == tvTag): not aSpecial
  elif aSpecial:
    if u.algorithm == raMinVer: a.version < b.version
    else: b.version < a.version
  elif u.algorithm == raMinVer: a.tagged.version < b.tagged.version
  else: b.tagged.version < a.tagged.version

proc chooseVersion*(u: PubGrubUniverse, package: string,
                    allowed: NimbleVersionSet): Option[Version] =
  let i = u.packageIndex(package)
  if i < 0: return none(Version)
  var best = -1
  for j, e in u.data.packages[i].entries:
    if allowed.contains(e.tagged) and
        (best < 0 or u.prefers(e, u.data.packages[i].entries[best])):
      best = j
  if best >= 0:
    result = some(u.data.packages[i].entries[best].version)

proc dependencies*(u: PubGrubUniverse, package: string,
                   version: Version): seq[NimbleDependency] =
  let i = u.packageIndex(package)
  if i < 0: return
  u.translate(i)
  let target = toTaggedVersion(version)
  for e in u.data.packages[i].entries:
    if e.tagged == target:
      return e.dependencies

proc dependencyRangeHook*(u: PubGrubUniverse, package: string,
                          version: Version,
                          dependency: NimbleDependency): NimbleVersionSet =
  ## Nimble universes routinely mix ordered and special versions, so no
  ## interval widening: either every version of `package` declares this exact
  ## constraint (then it holds for all of them, and the report says "every
  ## version of ..."), or it is stated for the one version it was read from.
  let i = u.packageIndex(package)
  if i < 0: return singleton(toTaggedVersion(version))
  u.translate(i)
  for e in u.data.packages[i].entries:
    var declared = false
    for d in e.dependencies:
      if d.package == dependency.package:
        declared = d.versions == dependency.versions
        break
    if not declared:
      return singleton(toTaggedVersion(version))
  taggedFull[LineVersion, NimbleTag]()

proc packageExistsHook*(u: PubGrubUniverse, package: string): bool =
  ## Whether the universe knows the package at all. Lets the report say
  ## "foo doesn't exist" instead of "no versions of foo match ..." - the
  ## difference between a typo and an unsatisfiable constraint.
  u.packageIndex(package) >= 0

proc versionCountHook*(u: PubGrubUniverse, package: string,
                       allowed: NimbleVersionSet): int =
  let i = u.packageIndex(package)
  if i < 0: return 0
  for e in u.data.packages[i].entries:
    if allowed.contains(e.tagged): inc result

# ------------------------------------------------------------------ solving

type
  PubGrubAnswer* = object
    ## PubGrub's answer for a universe.
    solved*: bool
    packages*: seq[tuple[package: string, version: Version]]
      ## When solved: every decided package, root included, names lowercased.
    explanation*: string
      ## When not: the report saying why.

proc solveWithPubGrub*(pkgVersionTable: Table[string, PackageVersions],
                       algorithm = raMaxVer): PubGrubAnswer =
  ## Resolves the universe with PubGrub. Both uses go through here - the
  ## solver under `--solver:pubgrub` and the explanation of a SAT failure -
  ## so the generic solver is instantiated once, next to the provider hooks
  ## it looks up by `compiles`, and searches the same way for both.
  let u = initPubGrubUniverse(pkgVersionTable, algorithm)
  if u.rootName.len == 0:
    raise newException(ValueError, "the universe has no root package")
  let res = solve(u, u.rootName, u.rootVersion)
  case res.outcome
  of soSolved:
    PubGrubAnswer(solved: true, packages: res.packages)
  of soUnsolvable:
    PubGrubAnswer(solved: false, explanation: report(res.failure, u.rootName))

proc pubGrubPackages*(pkgVersionTable: Table[string, PackageVersions],
                      output: var string, options: Options): Table[string, Version] =
  ## `--solver:pubgrub`. PubGrub needs none of the scaffolding SAT has around
  ## it - the missing-dependency pre-check, the retries, the explanation
  ## after the fact: an absent package is part of its answer like any other
  ## conflict, and on failure its report is the error.
  displayInfo("Resolving dependencies with PubGrub", LowPriority)
  let answer = solveWithPubGrub(pkgVersionTable, options.resolutionAlgorithm)
  if answer.solved:
    # PubGrub names packages by their lowercased table key; the graph, and
    # everything downstream of it, by `PackageVersions.pkgName`.
    var nodeName = initTable[string, string]()
    for key, pv in pkgVersionTable:
      nodeName[key.toLowerAscii] = pv.pkgName
    for (package, version) in answer.packages:
      result[nodeName.getOrDefault(package, package)] = version
  else:
    output = "Dependency resolution failed:\n" & answer.explanation & "\n"
    output.addDiscoveryErrors(options)

# ------------------------------------------------------------ failure path

proc explainSolveFailure*(pkgVersionTable: Table[string, PackageVersions]):
    tuple[foundSolution: bool, explanation: string] =
  ## Re-solves the universe the SAT solver failed on. On agreement (also
  ## unsolvable) the explanation is the PubGrub report; on disagreement
  ## `foundSolution` is true and the caller should flag a solver bug. Never
  ## raises: an error in the bridge must not mask the original failure.
  try:
    let answer = solveWithPubGrub(pkgVersionTable)
    (answer.solved, answer.explanation)
  except CatchableError:
    (false, "")
