# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

## Everything behind `nimble refresh` past the package list itself: bringing
## the repos backing known packages up to date and reporting which newer
## versions that made visible. Refreshing picks no versions, writes no lock
## file and installs nothing.

import std/[os, algorithm, sets, sequtils, strformat, strutils, tables]
import std/options as std_opt
import chronos

import common, options, packageinfotypes, packageinfo, version, cli,
       versiondiscovery, developfile, vcstools, download, paths

type
  RefreshOutcome* = object
    ## What a global refresh could not do, split by cause so the two never get
    ## conflated in the summary.
    failed*: seq[string]   ## `name: reason` for packages that errored out.
    unknown*: seq[string]  ## Names no package list knows about.

  SolveProjectDeps* = proc (options: var Options, nimBin: var Option[string]):
    PackageInfo {.nimcall.}
    ## Resolves the current project, so the project refresh can walk the
    ## solution. Passed in because solving lives in the main pipeline.

const globalRefreshWorkers = 8 ## How many repos a global refresh fetches at once.

proc maxCachedVersion(cache: TaggedVersionsCache, pkgName: string): Option[Version] =
  ## Highest non-special version known for `pkgName` in the tagged versions cache.
  let key = normalizePackageName(pkgName)
  if key notin cache:
    return none(Version)
  for pkg in cache[key]:
    if pkg.version.isSpecial:
      continue
    if result.isNone or pkg.version > result.get:
      result = some pkg.version

proc newestLocalTag(dir: string, options: Options): Option[(Version, string)] =
  ## Highest version tag present in the local clone, with the tag that carries it.
  for ver, tag in getTagsList(dir, DownloadMethod.git).getVersionList().pairs:
    if result.isNone or ver > result.get[0]:
      result = some (ver, tag)

proc refreshDevelopDeps(rootPkg: PackageInfo, options: Options,
                        nimBin: Option[string]): tuple[updated, skipped: seq[string]] =
  ## Fetches every develop/vendor repo and moves it to its newest tag when the
  ## working copy is clean. A dirty repo is reported and skipped, never touched;
  ## one failing repo never aborts the refresh.
  for dep in processDevelopDependencies(rootPkg, options, nimBin):
    let
      name = dep.basicInfo.name
      dir = dep.getNimbleFileDir
    try:
      gitFetchTags(dir, DownloadMethod.git, options)
    except CatchableError as e:
      displayWarning(&"Could not fetch develop dependency {name} at {dir}: {e.msg}",
                     HighPriority)
      continue
    let newest = newestLocalTag(dir, options)
    if newest.isNone or newest.get[0] <= dep.basicInfo.version:
      continue
    let (target, tag) = newest.get
    if not isWorkingCopyClean(dir.Path):
      result.skipped.add &"{name} {dir}"
      continue
    if doCheckout(DownloadMethod.git, dir, tag, options):
      result.updated.add &"{name} {dep.basicInfo.version} -> {target}"
    else:
      displayWarning(
        &"Failed to checkout {name} to version {target} at {dir}.", HighPriority)

proc newerVersions(names: seq[string],
                   before, after: TaggedVersionsCache): seq[string] =
  ## Lines describing the packages whose newest known version grew over the
  ## course of a refresh, as `name old -> new`.
  for name in names:
    let
      oldVer = maxCachedVersion(before, name)
      newVer = maxCachedVersion(after, name)
    if newVer.isNone: continue
    if oldVer.isNone or newVer.get > oldVer.get:
      let fromVer = if oldVer.isSome: $oldVer.get else: "(none)"
      result.add &"{name} {fromVer} -> {newVer.get}"

proc displayRefreshSummary(rootName: string, depNames: seq[string],
                           before, after: TaggedVersionsCache,
                           develop: tuple[updated, skipped: seq[string]]) =
  display("Refreshed", &"{depNames.len} dependencies of {rootName}",
          priority = HighPriority)
  let upgrades = newerVersions(depNames, before, after)

  if upgrades.len > 0:
    display("Info:", "Newer versions available:", priority = HighPriority)
    for line in upgrades:
      display("", "  " & line, priority = HighPriority)
  if develop.updated.len > 0:
    display("Info:", "Updated develop dependencies:", priority = HighPriority)
    for line in develop.updated:
      display("", "  " & line, priority = HighPriority)
  if develop.skipped.len > 0:
    display("Info:", "Skipped (uncommitted changes):", priority = HighPriority)
    for line in develop.skipped:
      display("", "  " & line, priority = HighPriority)
  if upgrades.len == 0 and develop.updated.len == 0:
    display("Info:", "Everything is up to date.", priority = HighPriority)

proc refreshProjectDeps*(options: var Options, nimBin: var Option[string],
                         solveProject: SolveProjectDeps) =
  ## The clone half of `nimble refresh`: git-fetch every repo backing a
  ## (transitive) dependency of the current project, repopulate version
  ## discovery, and report what newer versions that made visible. Picks no
  ## version, writes no lock file, installs nothing.
  let before = readTaggedVersionsCache(options)
  var rootPackage: PackageInfo
  options.forceFetch = true
  try:
    rootPackage = solveProject(options, nimBin)
  finally:
    options.forceFetch = false

  let develop = refreshDevelopDeps(rootPackage, options, nimBin)

  var depNames: seq[string]
  for solvedPkg in options.satResult.solvedPkgs:
    if solvedPkg.pkgName.isNim or
       cmpIgnoreCase(solvedPkg.pkgName, rootPackage.basicInfo.name) == 0:
      continue
    depNames.addUnique solvedPkg.pkgName
  displayRefreshSummary(rootPackage.basicInfo.name, depNames, before,
                        readTaggedVersionsCache(options), develop)

proc globalRefreshTargets(options: Options): seq[string] =
  ## Everything a global refresh covers: the packages installed in the global
  ## package dir, plus every package the tagged versions cache already knows
  ## about. A package can be in either set alone - installed before the cache
  ## existed, or only ever pulled in as a transitive dependency of some past
  ## solve - and both are things the user expects `refresh -g` to update.
  ##
  ## Names are used exactly as they were recorded, because that is what
  ## version discovery resolves: a package name goes through the package list,
  ## a URL (a fork, say) is fetched directly. Rewriting one into the other
  ## would refresh a different repo than the one the entry came from.
  var seen: HashSet[string]
  template consider(rawName: string) =
    let name = rawName
    if name.len > 0 and not name.isNim and
       not seen.containsOrIncl(normalizePackageName(name)):
      result.add name

  for pkg in getInstalledMinimalPackages(options):
    consider pkg.name
  for cachedName in readTaggedVersionsCache(options).keys:
    consider cachedName
  result.sort()

proc displayGlobalRefreshSummary(targets: seq[string],
                                 before, after: TaggedVersionsCache,
                                 outcome: RefreshOutcome) =
  display("Refreshed", &"{targets.len} global packages", priority = HighPriority)
  let upgrades = newerVersions(targets, before, after)
  if upgrades.len > 0:
    display("Info:", "Newer versions available:", priority = HighPriority)
    for line in upgrades:
      display("", "  " & line, priority = HighPriority)
  else:
    display("Info:", "Everything is up to date.", priority = HighPriority)
  # Kept apart from the failures below: nothing went wrong with these, there is
  # just no published package by that name to look at.
  if outcome.unknown.len > 0:
    display("Info:", &"{outcome.unknown.len} packages are not in any package " &
            "list and cannot be refreshed:", priority = HighPriority)
    for name in outcome.unknown:
      display("", "  " & name, priority = HighPriority)
  if outcome.failed.len > 0:
    display("Info:", &"Could not refresh {outcome.failed.len} packages:",
            priority = HighPriority)
    for line in outcome.failed:
      display("", "  " & line, priority = HighPriority)

proc fetchRefreshTargets(targets: seq[string], options: Options,
                         nimBin: Option[string]): RefreshOutcome =
  ## Re-runs version discovery for every target, a few at a time, reporting
  ## which ones could not be refreshed and why.
  var
    next = 0
    done = 0
    outcome: RefreshOutcome

  proc worker() {.async.} =
    while next < targets.len:
      let name = targets[next]
      inc next
      try:
        discard await downloadMinimalPackage(
          (name: name, ver: VersionRange(kind: verAny)), options, nimBin)
      except PackageNotFoundError:
        # Not a failure: the name simply isn't in any package list, so there is
        # nothing to fetch. Typically a package installed as a dependency of a
        # URL-based one, whose own name was never published.
        outcome.unknown.add name
      except CatchableError as e:
        # One unreachable repo must not abort the whole refresh.
        outcome.failed.add &"{name}: {e.msg}"
      inc done
      # Reported on completion, so the count still climbs in order even though
      # the packages themselves finish out of order.
      display("Fetched", &"({done}/{targets.len}) {name}",
              priority = HighPriority)

  let workerCount =
    if options.parallelDiscovery: min(globalRefreshWorkers, targets.len)
    else: 1
  var workers: seq[Future[void]]
  for _ in 0 ..< workerCount:
    workers.add worker()
  waitFor allFutures(workers)
  outcome

proc refreshGlobalDeps*(options: var Options, nimBin: Option[string]) =
  ## The global half of `nimble refresh`: re-run version discovery against the
  ## network for every globally known package and report what newer versions
  ## that made visible. Like the project half it picks no version and installs
  ## nothing - it only updates what nimble knows is out there.
  let
    before = readTaggedVersionsCache(options)
    targets = globalRefreshTargets(options)
  if targets.len == 0:
    display("Info:", "No global packages to refresh.", priority = HighPriority)
    return

  # This walks the network once per package, so say what is about to happen
  # and keep reporting progress rather than going quiet for minutes.
  display("Refreshing", &"{targets.len} global packages, this may take a while",
          priority = HighPriority)

  # A nimble file the declarative parser cannot handle falls back to the VM
  # parser, which needs a compiler. Refresh resolves nothing, so nothing has
  # picked a nim yet: use whatever is on PATH. Without one those few packages
  # are reported at the end rather than aborting the refresh.
  var refreshNimBin = nimBin
  if refreshNimBin.isNone:
    let systemNim = findExe("nim")
    if systemNim.len > 0:
      refreshNimBin = some(systemNim)

  var outcome: RefreshOutcome
  options.forceFetch = true
  try:
    outcome = fetchRefreshTargets(targets, options, refreshNimBin)
  finally:
    options.forceFetch = false

  displayGlobalRefreshSummary(targets, before, readTaggedVersionsCache(options),
                              outcome)

