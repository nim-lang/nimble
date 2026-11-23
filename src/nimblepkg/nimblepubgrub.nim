# Copyright (C) the Nimble contributors. All rights reserved.
# BSD License. Look at license.txt for more info.

## The PubGrub solver, `nimblesat`'s counterpart: the bridge between Nimble's
## package universe and the standalone PubGrub library (`pubgrub/` at the
## repository root). It serves three callers:
##
## - `--solver:pubgrub` (`pubGrubPackages`), where PubGrub resolves the
##   dependency graph;
## - `discoverLazily` (nimblesolver), which searches what it has fetched so
##   far, leaving out the requirements not fetched yet (`Unfetched`), and is
##   told which versions the search tried and what it is missing;
## - the failure path of `--solver:sat`. When SAT finds no solution,
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

import std/[tables, options, strutils, algorithm]
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
    preferred: int
      ## The entry to try before any other while it is allowed, or -1.
    translated: bool
    ordered: seq[int]
      ## The entries of ordinary versions, oldest first (`lineOrder`).
    sorted: bool

  Prepared = object
    index: Table[string, int]  ## lowercased name -> `packages`
    packages: seq[PreparedPackage]
    visited: seq[tuple[package: string, version: Version]]
      ## Every version the search asked the dependencies of.
    missing: seq[PkgTuple]
      ## The requirements it left out because they are `Unfetched`.

  Unfetched* = proc (req: PkgTuple): bool
    ## Whether a requirement's package is still to be fetched. The search
    ## goes on as if a version did not have such a requirement, and reports
    ## it, so whoever fetches can fetch it and search again.

  PubGrubUniverse* = object
    ## `pkgVersionTable` prepared for the search - re-keyed by lowercased
    ## name, every version parsed once, requirements translated once - plus
    ## the root's identity and the version preferences to search with. The
    ## preparation sits behind a `ref` so the provider procs can fill it in
    ## as the search reaches each package.
    data: ref Prepared
    rootName: string
    rootVersion: Version
    algorithm: ResolutionAlgorithm
    unfetched: Unfetched

proc initPubGrubUniverse*(pkgVersionTable: Table[string, PackageVersions],
                          algorithm = raMaxVer,
                          preferred = initTable[string, Version](),
                          unfetched: Unfetched = nil):
    PubGrubUniverse =
  ## `preferred` names, per package, a version to try before the others
  ## whenever it is still allowed (`chooseVersion`).
  result.algorithm = algorithm
  result.unfetched = unfetched
  result.data = new Prepared
  var wanted = initTable[string, NimbleTaggedVersion]()
  for name, version in preferred:
    wanted[name.toLowerAscii] = toTaggedVersion(version)
  for name, pv in pkgVersionTable:
    let key = name.toLowerAscii
    var package = PreparedPackage(preferred: -1)
    for mi in pv.versions:
      let tagged = toTaggedVersion(mi.version)
      if package.preferred < 0 and key in wanted and tagged == wanted[key]:
        package.preferred = package.entries.len
      package.entries.add Entry(version: mi.version, tagged: tagged,
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

proc lineOrder(u: PubGrubUniverse, i: int): seq[int] =
  ## The ordinary versions of package `i`, oldest first, sorted the first time
  ## they are asked for. A version listed twice is its first listing, the one
  ## `dependencies` reads.
  if not u.data.packages[i].sorted:
    var line: seq[tuple[version: LineVersion, entry: int]]
    for k, e in u.data.packages[i].entries:
      if e.tagged.kind == tvVersion: line.add (e.tagged.version, k)
    # Stable, so equal versions stay in listing order.
    line.sort(proc (a, b: tuple[version: LineVersion, entry: int]): int =
      if a.version < b.version: -1 elif b.version < a.version: 1 else: 0)
    for k, (version, entry) in line:
      if k == 0 or not (line[k - 1].version == version):
        u.data.packages[i].ordered.add entry
    u.data.packages[i].sorted = true
  u.data.packages[i].ordered

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

proc preferredAllowed(u: PubGrubUniverse, i: int,
                      allowed: NimbleVersionSet): bool =
  let p = u.data.packages[i].preferred
  p >= 0 and allowed.contains(u.data.packages[i].entries[p].tagged)

proc chooseVersion*(u: PubGrubUniverse, package: string,
                    allowed: NimbleVersionSet): Option[Version] =
  ## The preferred version while it is allowed, else the best by `prefers`.
  let i = u.packageIndex(package)
  if i < 0: return none(Version)
  if u.preferredAllowed(i, allowed):
    return some(u.data.packages[i].entries[u.data.packages[i].preferred].version)
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
  u.data.visited.add (package: package, version: version)
  let target = toTaggedVersion(version)
  for e in u.data.packages[i].entries:
    if e.tagged == target:
      if u.unfetched.isNil:
        return e.dependencies
      # `translate` keeps one dependency per requirement, in order.
      for k, req in e.requires:
        if u.unfetched(req): u.data.missing.add req
        else: result.add e.dependencies[k]
      return

proc declares(u: PubGrubUniverse, e: Entry,
              dependency: NimbleDependency): bool =
  ## Whether the search sees version `e` require exactly `dependency`. It
  ## leaves out a requirement still to be fetched (`dependencies`).
  for k, d in e.dependencies:
    if d.package == dependency.package and d.versions == dependency.versions:
      return u.unfetched.isNil or not u.unfetched(e.requires[k])

proc dependencyRangeHook*(u: PubGrubUniverse, package: string,
                          version: Version,
                          dependency: NimbleDependency): NimbleVersionSet =
  ## The versions of `package` the solver states this dependency for at once.
  ## Of the ordinary versions, the run around `version` that declares exactly
  ## it, up to the next version that doesn't - open past the oldest and the
  ## newest, where no version could differ - or, for a special `version`, all
  ## of them if they all do. Of the special versions, all but those that
  ## don't. A range of ordinary versions never holds a special version, so the
  ## two never mix. A run is one fact instead of one per version, which is
  ## fewer facts to search and what lets the report say "foo 1.2.0 to 1.4.1
  ## depends on ...".
  ##
  ## Only what the search sees counts. A version not read yet requires nothing
  ## (`discoverLazily`), so it ends a run, and so does a version whose
  ## requirement waits on a fetch.
  let exact = singleton(toTaggedVersion(version))
  let i = u.packageIndex(package)
  if i < 0: return exact
  u.translate(i)
  template entries: untyped = u.data.packages[i].entries
  var differing: seq[NimbleTag]
  for k, e in entries:
    if e.tagged.kind == tvTag and not u.declares(e, dependency):
      # A tag listed twice is its first listing, the one `dependencies` reads.
      var first = true
      for earlier in 0 ..< k:
        if entries[earlier].tagged == e.tagged: first = false
      if first: differing.add e.tagged.tag
  let
    target = toTaggedVersion(version)
    order = u.lineOrder(i)
  var line = emptyRange[LineVersion]()
  if target.kind == tvTag:
    var every = true
    for k in order:
      if not u.declares(entries[k], dependency): every = false
    if every: line = fullRange[LineVersion]()
  else:
    var at = -1
    for k, e in order:
      if entries[e].tagged == target: at = k
    if at < 0: return exact
    var (low, high) = (at, at)
    while low > 0 and u.declares(entries[order[low - 1]], dependency): dec low
    while high < order.high and
        u.declares(entries[order[high + 1]], dependency):
      inc high
    line = interval(
      if low == 0: noBound[LineVersion]()
      else: inclBound(entries[order[low]].tagged.version),
      if high == order.high: noBound[LineVersion]()
      else: exclBound(entries[order[high + 1]].tagged.version))
  tagged[LineVersion, NimbleTag](line, differing, cofinite = true)

proc packageExistsHook*(u: PubGrubUniverse, package: string): bool =
  ## Whether the universe knows the package at all. Lets the report say
  ## "foo couldn't be found" instead of "no versions of foo match ..." - the
  ## difference between a typo or an unreachable repository and an
  ## unsatisfiable constraint.
  u.packageIndex(package) >= 0

proc versionCountHook*(u: PubGrubUniverse, package: string,
                       allowed: NimbleVersionSet): int =
  ## A preferred version still allowed counts as the only one, so its package
  ## is decided early, before the choices that could rule it out - the way
  ## Dart's pub treats a locked version.
  let i = u.packageIndex(package)
  if i < 0: return 0
  if u.preferredAllowed(i, allowed): return 1
  for e in u.data.packages[i].entries:
    if allowed.contains(e.tagged): inc result

proc orList(parts: openArray[string]): string =
  ## "a", "a or b", "a, b or c".
  for k, part in parts:
    if k > 0: result.add(if k == parts.high: " or " else: ", ")
    result.add part

proc requirementText(versions: NimbleVersionSet): string =
  ## `versions` the way a requirement on them is written: `>= 2.2.14`,
  ## `>= 1.0 & < 2.0`, `== 2.2.12`, `#head`, or several joined by "or".
  var parts: seq[string]
  let alone = versions.line.segments.len == 1 and not versions.cofinite and
    versions.tags.len == 0
  for (lower, upper) in versions.line.segments:
    if lower.kind == bkIncluded and upper.kind == bkIncluded and
        lower.value == upper.value:
      parts.add((if alone: "== " else: "") & $lower.value)
      continue
    var sides: seq[string]
    case lower.kind
    of bkIncluded: sides.add ">= " & $lower.value
    of bkExcluded: sides.add "> " & $lower.value
    of bkUnbounded: discard
    case upper.kind
    of bkIncluded: sides.add "<= " & $upper.value
    of bkExcluded: sides.add "< " & $upper.value
    of bkUnbounded: discard
    parts.add(if sides.len == 0: "any release" else: sides.join(" & "))
  var tags: seq[string]
  for t in versions.tags: tags.add $t
  if not versions.cofinite: parts.add tags
  elif tags.len == 0: parts.add "any special version"
  else: parts.add "any special version but " & tags.join(", ")
  parts.orList

proc versionsTextHook*(u: PubGrubUniverse, package: string,
                       versions: NimbleVersionSet, positive: bool): string =
  ## How PubGrub's report writes versions. What a dependency allows is
  ## written as a requirement is (`requirementText`). The versions a package
  ## is at are the listed ones the set holds - `1.4.2`, `26.9.0 to 26.10.2` -
  ## rather than the bounds the solver widened it to, and nothing at all when
  ## it holds every one; a set holding none is written as a requirement.
  if versions.isFull: return ""
  let i = u.packageIndex(package)
  if positive and i >= 0:
    template entries: untyped = u.data.packages[i].entries
    var
      parts: seq[string]
      run: seq[Version]
      every = true
    proc endRun(parts: var seq[string], run: var seq[Version]) =
      if run.len == 1: parts.add $run[0]
      elif run.len > 1: parts.add $run[0] & " to " & $run[^1]
      run.setLen 0
    for k in u.lineOrder(i):
      if versions.contains(entries[k].tagged): run.add entries[k].version
      else:
        every = false
        endRun(parts, run)
    endRun(parts, run)
    var seen: seq[NimbleTag]
    for e in entries:
      if e.tagged.kind == tvTag and e.tagged.tag notin seen:
        seen.add e.tagged.tag
        if versions.contains(e.tagged): parts.add $e.tagged.tag
        else: every = false
    if parts.len > 0:
      return if every: "" else: parts.orList
  requirementText(versions)

# ------------------------------------------------------------------ solving

type
  PubGrubAnswer* = object
    ## PubGrub's answer for a universe.
    solved*: bool
    packages*: seq[tuple[package: string, version: Version]]
      ## When solved: every decided package, root included, names lowercased.
    explanation*: string
      ## When not: the report saying why.
    visited*: seq[tuple[package: string, version: Version]]
      ## Every version the search asked the dependencies of, lowercased.
    missing*: seq[PkgTuple]
      ## The `unfetched` requirements of those versions, left out of the
      ## search. Unless empty, the answer is only what the universe fetched
      ## so far allows.

proc solveWithPubGrub*(pkgVersionTable: Table[string, PackageVersions],
                       algorithm = raMaxVer,
                       preferred = initTable[string, Version](),
                       unfetched: Unfetched = nil): PubGrubAnswer =
  ## Resolves the universe with PubGrub, trying the `preferred` versions
  ## first. Both uses go through here - the solver under `--solver:pubgrub`
  ## and the explanation of a SAT failure - so the generic solver is
  ## instantiated once, next to the provider hooks it looks up by `compiles`,
  ## and searches the same way for both.
  let u = initPubGrubUniverse(pkgVersionTable, algorithm, preferred, unfetched)
  if u.rootName.len == 0:
    raise newException(ValueError, "the universe has no root package")
  let res = solve(u, u.rootName, u.rootVersion)
  case res.outcome
  of soSolved:
    result = PubGrubAnswer(solved: true, packages: res.packages)
  of soUnsolvable:
    result = PubGrubAnswer(solved: false,
                           explanation: report(res.failure, u.rootName, u))
  result.visited = u.data.visited
  result.missing = u.data.missing

proc pubGrubPackages*(pkgVersionTable: Table[string, PackageVersions],
                      output: var string, options: Options,
                      preferred = initTable[string, Version]()):
    Table[string, Version] =
  ## `--solver:pubgrub`. PubGrub needs none of the scaffolding SAT has around
  ## it - the missing-dependency pre-check, the retries, the explanation
  ## after the fact: an absent package is part of its answer like any other
  ## conflict, and on failure its report is the error. Nor the repeated
  ## solves SAT uses to prefer a version: `preferred` is tried first.
  displayInfo("Resolving dependencies with PubGrub", LowPriority)
  let answer = solveWithPubGrub(pkgVersionTable, options.resolutionAlgorithm,
                                preferred)
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
