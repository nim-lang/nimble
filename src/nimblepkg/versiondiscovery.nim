# Copyright (C) the Nimble contributors. All rights reserved.
# BSD License. Look at license.txt for more info.

import std/[os, tables, options, strutils, sets, strformat, json, jsonutils]
import chronos
import version, packageinfotypes, download, packageinfo, packageparser, options,
  sha1hashes, tools, downloadnim, cli, declarativeparser, common
import compat/[sequtils]
export declarativeparser

type
  GetPackageMinimal* = proc (pv: PkgTuple, options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.}

  TaggedVersionsCache* = Table[string, seq[PackageMinimalInfo]]
    ## Central cache for all package tagged versions, keyed by normalized package name

const TaggedVersionsFileName* = "tagged_versions.json"

proc isFileUrl*(pkgDownloadInfo: PackageDownloadInfo): bool =
  pkgDownloadInfo.meth.isNone and pkgDownloadInfo.url.isFileURL

proc getPackageDownloadInfo*(pv: PkgTuple, options: Options, doPrompt = false, vcsRevision: Sha1Hash = notSetSha1Hash): PackageDownloadInfo =
  if pv.name.isFileURL:
    return PackageDownloadInfo(meth: none(DownloadMethod), url: pv.name, subdir: "", downloadDir: "", pv: pv, vcsRevision: notSetSha1Hash)
  let (meth, url, metadata) =
      getDownloadInfo(pv, options, doPrompt, ignorePackageCache = false)
  let subdir = metadata.getOrDefault("subdir")
  let downloadDir = getCacheDownloadDir(url, pv.ver, options, vcsRevision)
  PackageDownloadInfo(meth: some meth, url: url, subdir: subdir, downloadDir: downloadDir, pv: pv, vcsRevision: vcsRevision)

proc getLockFileDownloadInfo*(pv: PkgTuple, dep: LockFileDep,
                             options: Options): PackageDownloadInfo =
  ## Builds download information directly from the lock entry. In particular,
  ## this must not call getDownloadInfo: that resolves package names through
  ## packages.json and can replace the locked repository with an indexed one.
  let lockedPv = (name: dep.url, ver: pv.ver)
  if dep.url.isFileURL:
    return PackageDownloadInfo(meth: none(DownloadMethod), url: dep.url,
      subdir: "", downloadDir: "", pv: lockedPv,
      vcsRevision: notSetSha1Hash)

  let (url, metadata) = getUrlData(dep.url)
  let subdir = metadata.getOrDefault("subdir")
  PackageDownloadInfo(meth: some(dep.downloadMethod), url: url,
    subdir: subdir,
    downloadDir: getCacheDownloadDir(url, pv.ver, options, dep.vcsRevision),
    pv: lockedPv, vcsRevision: dep.vcsRevision)

proc getPackageFromFileUrl*(fileUrl: string, options: Options, nimBin: Option[string]): PackageInfo = 
  let absPath = extractFilePathFromURL(fileUrl)
  getPkgInfo(absPath, options, nimBin, pikRequires)

proc downloadFromDownloadInfo*(dlInfo: PackageDownloadInfo, options: Options, nimBin: Option[string]): (DownloadPkgResult, Option[DownloadMethod]) =
  if dlInfo.isFileUrl:
    let pkgInfo = getPackageFromFileUrl(dlInfo.url, options, nimBin)
    let downloadRes = (dir: pkgInfo.getNimbleFileDir(), version: pkgInfo.basicInfo.version, vcsRevision: notSetSha1Hash)
    (downloadRes, none(DownloadMethod))
  else:
    let downloadRes = downloadPkg(dlInfo.url, dlInfo.pv.ver, dlInfo.meth.get, dlInfo.subdir, options,
                  dlInfo.downloadDir, vcsRevision = dlInfo.vcsRevision, nimBin = nimBin)
    (downloadRes, dlInfo.meth)

proc downloadPkgFromUrl*(pv: PkgTuple, options: Options, doPrompt = false, nimBin: Option[string]): (DownloadPkgResult, Option[DownloadMethod]) = 
  let dlInfo = getPackageDownloadInfo(pv, options, doPrompt)
  downloadFromDownloadInfo(dlInfo, options, nimBin)
        
proc downloadPkInfoForPv*(pv: PkgTuple, options: Options, doPrompt = false, nimBin: Option[string]): PackageInfo  =
  let downloadRes = downloadPkgFromUrl(pv, options, doPrompt, nimBin)
  result = getPkgInfo(downloadRes[0].dir, options, nimBin, pikRequires)

proc getAllNimReleases*(options: Options, nimVersion: Option[Version]): Future[seq[PackageMinimalInfo]] {.async.} =
  let releases = await getOfficialReleases(options)
  for release in releases:
    result.add PackageMinimalInfo(name: "nim", version: release)

  if nimVersion.isSome:
    result.addUnique PackageMinimalInfo(name: "nim", version: nimVersion.get)

proc normalizePackageName*(pkgName: string): string =
  ## Normalizes a package name for use as cache key (lowercase for consistent lookups)
  pkgName.toLowerAscii

proc getTaggedVersionsCacheFile*(options: Options): string =
  ## Returns the path to the centralized tagged versions cache file
  options.pkgCachePath / TaggedVersionsFileName

proc readTaggedVersionsCache*(options: Options): TaggedVersionsCache =
  ## Reads the entire tagged versions cache from disk
  let cacheFile = getTaggedVersionsCacheFile(options)
  if cacheFile.fileExists:
    try:
      result = cacheFile.readFile.parseJson().to(TaggedVersionsCache)
    except CatchableError as e:
      displayWarning(&"Error reading tagged versions cache: {e.msg}", HighPriority)
      result = initTable[string, seq[PackageMinimalInfo]]()
  else:
    result = initTable[string, seq[PackageMinimalInfo]]()

proc writeTaggedVersionsCache*(cache: TaggedVersionsCache, options: Options) =
  ## Writes the entire tagged versions cache to disk atomically
  let cacheFile = getTaggedVersionsCacheFile(options)
  let tempFile = cacheFile & ".tmp"
  try:
    createDir(cacheFile.parentDir)
    writeFile(tempFile, cache.toJson().pretty)
    {.cast(raises: [CatchableError]).}:
      moveFile(tempFile, cacheFile)  # Atomic rename
  except CatchableError as e:
    displayWarning(&"Error saving tagged versions cache: {e.msg}", HighPriority)
    try:
      removeFile(tempFile)
    except:
      discard

proc getTaggedVersions*(pkgName: string, options: Options): Option[seq[PackageMinimalInfo]] =
  ## Gets tagged versions for a package from the centralized cache
  let cache = readTaggedVersionsCache(options)
  let normalizedName = normalizePackageName(pkgName)
  if normalizedName in cache:
    return some(cache[normalizedName])
  return none(seq[PackageMinimalInfo])

proc saveTaggedVersions*(pkgName: string, versions: seq[PackageMinimalInfo], options: Options) =
  ## Saves tagged versions for a package to the centralized cache
  var cache = readTaggedVersionsCache(options)
  let normalizedName = normalizePackageName(pkgName)
  cache[normalizedName] = versions
  writeTaggedVersionsCache(cache, options)

proc cachedTagsCoverLocalTags*(cached: seq[PackageMinimalInfo], tagsList: seq[string]): bool =
  ## Returns true iff every parsed git tag has a corresponding version in `cached`.
  ## Used to detect stale tagged_versions.json entries when the local repo has tags
  ## that aren't represented in the cache (cache predates a newer release).
  let parsedTags = tagsList.getVersionList()
  for ver, _ in parsedTags.pairs:
    var found = false
    for c in cached:
      if c.version == ver:
        found = true
        break
    if not found:
      return false
  return true

proc cacheToPackageVersionTable*(options: Options): Table[string, PackageVersions] =
  ## Loads the tagged versions cache and converts it to a package version table.
  ## This allows reusing cached package versions instead of re-fetching them.
  ## Note: Skips package versions that have URL-based requirements since those
  ## dependencies may not be resolved in the cache.
  let cache = readTaggedVersionsCache(options)
  result = initTable[string, PackageVersions]()
  for pkgName, versions in cache:
    var validVersions: seq[PackageMinimalInfo] = @[]
    for v in versions:
      var hasUrlDep = false
      for req in v.requires:
        if req.name.isUrl:
          hasUrlDep = true
          break
      if not hasUrlDep:
        var cleanVersion = v
        cleanVersion.isRoot = false  # Clear isRoot - it's set at runtime, not from cache
        validVersions.add cleanVersion
    if validVersions.len > 0:
      result[pkgName] = PackageVersions(pkgName: pkgName, versions: validVersions)

proc locateGitRoot(repoDir: string): tuple[gitRoot, subdirPath: string] =
  ## The git repository `repoDir` is in, and where in it `repoDir` is. When
  ## no `.git` is found, `repoDir` itself: git commands might still work.
  result = (gitRoot: repoDir, subdirPath: "")
  try:
    if not dirExists(repoDir / ".git"):
      var currentDir = repoDir
      while not dirExists(currentDir / ".git") and currentDir.parentDir() != currentDir:
        currentDir = currentDir.parentDir()
      if dirExists(currentDir / ".git"):
        result = (gitRoot: currentDir,
                  subdirPath: repoDir.relativePath(currentDir).replace("\\", "/"))
  except CatchableError:
    discard

proc cachedVersions(name: string, options: Options): Option[seq[PackageMinimalInfo]] =
  ## The versions of `name` the cache holds. `nimble refresh` sets forceFetch
  ## so the cache is never trusted: the whole point of the command is to go
  ## look at the network. Offline there is no network to look at, so
  ## forceFetch keeps only its other meaning - don't reuse the current
  ## solution - and the cache is what we re-solve against.
  if options.forceFetch and not options.offline:
    return none(seq[PackageMinimalInfo])
  try:
    getTaggedVersions(name, options)
  except CatchableError:
    none(seq[PackageMinimalInfo])

proc cacheIsFresh(cached: seq[PackageMinimalInfo], gitRoot, repoDir: string,
                  downloadMethod: DownloadMethod, options: Options,
                  nimBin: Option[string]): Future[bool] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Whether the cached versions are all there is to the clone: one for
    ## every tag it has, and one for its checkout.
    var fresh = true
    try:
      let localTags = await getTagsListAsync(gitRoot, downloadMethod)
      fresh = cachedTagsCoverLocalTags(cached, localTags)
    except CatchableError:
      discard
    if not fresh:
      return false
    # A stricter requirement may have downloaded an untagged HEAD after an
    # earlier request cached only releases. Covering the tags is not enough:
    # discovery must also include the checkout we just downloaded.
    try:
      let checkoutVersion = getPkgInfo(repoDir, options, nimBin).basicInfo.version
      return cached.anyIt(it.version == checkoutVersion)
    except CatchableError:
      return false

proc fetchTags(gitRoot, name: string, downloadMethod: DownloadMethod,
               options: Options, fetch: bool): Future[Option[OrderedTable[Version, string]]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## The clone's tags, by version, after fetching them all when `fetch`
    ## (never offline: whatever the clone already has is all there is). None
    ## when git fails.
    try:
      if fetch and not options.offline:
        await gitFetchTagsAsync(gitRoot, downloadMethod, options)
      return some((await getTagsListAsync(gitRoot, downloadMethod)).getVersionList())
    except ref NimbleGitError as e:
      options.satResult.gitErrors.add(&"Git error fetching tags for {name} (could be a network issue): {e.msg}")
      displayWarning(&"Git error fetching tags for {name}: {e.msg}", HighPriority)
    except CatchableError as e:
      displayWarning(&"Error fetching tags for {name}: {e.msg}", HighPriority)

proc readCheckout(repoDir, name: string, options: Options,
                  nimBin: Option[string]): Option[PackageMinimalInfo] =
  ## The version checked out (the files already on disk).
  try:
    return some(getPkgInfo(repoDir, options, nimBin).getMinimalInfo(options))
  except CatchableError as e:
    displayWarning(&"Error getting package info for {name}: {e.msg}", HighPriority)

proc readTaggedVersion(gitRoot, subdirPath, name: string, ver: Version,
                       tag: string, options: Options,
                       nimBin: Option[string]): Future[Option[PackageMinimalInfo]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## The version a tag holds, read from its nimble file straight out of git
    ## (git ls-tree and git show, no checkout). None when the tag has no
    ## nimble file to read.
    try:
      let nimbleFiles = await gitListNimbleFilesInCommitAsync(gitRoot, tag)
      if nimbleFiles.len == 0:
        displayInfo(&"No nimble file found in tag {tag} for {name}", LowPriority)
        return

      # Filter nimble files to those in the subdirectory (if applicable)
      var relevantNimbleFiles: seq[string] = @[]
      if subdirPath != "":
        for nf in nimbleFiles:
          if nf.startsWith(subdirPath & "/") or nf.startsWith(subdirPath):
            relevantNimbleFiles.add(nf)
      else:
        relevantNimbleFiles = nimbleFiles

      if relevantNimbleFiles.len == 0:
        displayInfo(&"No nimble file found in tag {tag} (subdir: {subdirPath}) for {name}", LowPriority)
        return

      # Prefer nimble file matching package name
      var nimbleFilePath = relevantNimbleFiles[0]
      let expectedName = name & ".nimble"
      for nf in relevantNimbleFiles:
        if nf.endsWith(expectedName) or nf == expectedName:
          nimbleFilePath = nf
          break

      let nimbleContent = await gitShowFileAsync(gitRoot, tag, nimbleFilePath)

      # Try declarative parser first (faster, no temp file needed)
      let minimalInfo = getMinimalInfoFromContent(nimbleContent, name, ver, url = "", options)
      if minimalInfo.isSome:
        return minimalInfo
      # Fall back to temp file + VM parser for complex nimble files
      let tempNimbleFile = getTempDir() / &"{name}_{tag}.nimble"
      try:
        writeFile(tempNimbleFile, nimbleContent)
        let pkgInfo = getPkgInfoFromFile(nimBin, tempNimbleFile, options, useCache=false)
        return some(pkgInfo.getMinimalInfo(options))
      finally:
        try:
          removeFile(tempNimbleFile)
        except: discard
    except CatchableError as e:
      displayInfo(&"Error reading tag {tag} for {name}: {e.msg}", LowPriority)

proc getPackageMinimalVersionsFromRepo*(
    repoDir: string,
    pkg: PkgTuple,
    downloadMethod: DownloadMethod,
    options: Options,
    nimBin: Option[string]
): Future[seq[PackageMinimalInfo]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Every version of the package: its checkout and each of its tags, read
    ## from the cache when it covers them all.
    result = newSeq[PackageMinimalInfo]()
    let name = pkg[0]
    let (gitRoot, subdirPath) = locateGitRoot(repoDir)

    let cached = cachedVersions(name, options)
    if cached.isSome and
        await cacheIsFresh(cached.get, gitRoot, repoDir, downloadMethod, options, nimBin):
      return cached.get

    let tags = await fetchTags(gitRoot, name, downloadMethod, options, fetch = true)
    if tags.isNone:
      return

    let checkout = readCheckout(repoDir, name, options, nimBin)
    if checkout.isSome:
      result.add checkout.get

    for (ver, tag) in tags.get.pairs:
      let read = await readTaggedVersion(gitRoot, subdirPath, name, ver, tag, options, nimBin)
      if read.isSome:
        result.addUnique(read.get)

    # Save to cache
    try:
      saveTaggedVersions(name, result, options)
    except CatchableError as e:
      displayWarning(&"Error saving tagged versions for {name}: {e.msg}", LowPriority)

type
  UnreadTag = object
    ## A tag listed, its nimble file not read yet: what reading it takes.
    gitRoot, subdirPath, tag, lockDir: string
    name: string
      ## The package as the requirement named it, which is how
      ## `getPackageMinimalVersionsFromRepo` names what it reads and caches.
    version: Version

var unreadTags {.threadvar.}: Table[string, UnreadTag]
  ## The versions listed without reading, by `unreadKey`.

proc unreadKey(mi: PackageMinimalInfo): string =
  ## A listed version's name is the package as its requirement named it: a
  ## URL tells forks apart.
  mi.name.toLowerAscii & "\t" & $mi.version

proc isUnreadVersion*(mi: PackageMinimalInfo): bool =
  ## Whether `mi` is a version listed without reading
  ## (`listPackageMinimalVersionsFromRepo`): nothing known of it but its name
  ## and version, its requirements still to be read (`readUnreadVersions`).
  mi.requires.len == 0 and mi.features.len == 0 and mi.unreadKey in unreadTags

proc listPackageMinimalVersionsFromRepo*(
    repoDir: string,
    pkg: PkgTuple,
    downloadMethod: DownloadMethod,
    options: Options,
    nimBin: Option[string],
    lockDir = ""
): Future[tuple[read, unread: seq[PackageMinimalInfo]]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## `getPackageMinimalVersionsFromRepo` reading only what is at hand: the
    ## checkout, and the versions the cache holds. Every other tag is listed
    ## unread, nothing known of it but its version, to be read when it is
    ## needed (`readUnreadVersions`). `lockDir` is the clone's download
    ## directory, which a read takes turns on with its download.
    let name = pkg[0]
    let (gitRoot, subdirPath) = locateGitRoot(repoDir)

    let cached = cachedVersions(name, options)
    if cached.isSome and
        await cacheIsFresh(cached.get, gitRoot, repoDir, downloadMethod, options, nimBin):
      result.read = cached.get
      return

    # The tags of a package the cache knows are those of its clone, as
    # current as the cache: reading the cache doesn't fetch either. Only
    # some of its versions are cached when it was read this way, and fetching
    # whenever the cache doesn't cover the clone would fetch on every run.
    let tags = await fetchTags(gitRoot, name, downloadMethod, options,
                               fetch = cached.isNone)
    if tags.isNone:
      return

    result.read = cached.get(@[])
    let checkout = readCheckout(repoDir, name, options, nimBin)
    if checkout.isSome:
      result.read.addUnique checkout.get
    if cached.isNone:
      try:
        saveTaggedVersions(name, result.read, options)
      except CatchableError as e:
        displayWarning(&"Error saving tagged versions for {name}: {e.msg}", LowPriority)

    for (ver, tag) in tags.get.pairs:
      if not result.read.anyIt(it.version == ver):
        let listed = PackageMinimalInfo(name: if name.isNim: "nim" else: name,
                                        version: ver)
        unreadTags[listed.unreadKey] = UnreadTag(
          gitRoot: gitRoot, subdirPath: subdirPath, tag: tag,
          lockDir: if lockDir.len > 0: lockDir else: gitRoot,
          name: name, version: ver)
        result.unread.add listed

proc downloadNimSpecialVersion*(
    pv: PkgTuple, options: Options
): Future[seq[PackageMinimalInfo]] {.async.} =
  ## Downloads a special nim version (like #devel, #commit-sha) and extracts version info.
  let extractedDir = await downloadAndExtractNimMatchedVersion(pv.ver, options)
  var ver = newVersion($pv.ver)
  # Guard for the case when extraction failed (e.g. when a corrupt archive was downloaded).
  if extractedDir.isNone:
    return
  let nimbleFile = extractedDir.get / "nim.nimble"
  if nimbleFile.fileExists:
    let nimVersion = extractNimVersion(nimbleFile)
    if nimVersion != "":
      ver.speSemanticVersion = some(nimVersion)
  return @[PackageMinimalInfo(name: "nim", version: ver)]

proc downloadFromDownloadInfoAsync*(dlInfo: PackageDownloadInfo, options: Options, nimBin: Option[string]): Future[(DownloadPkgResult, Option[DownloadMethod])] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Async version of downloadFromDownloadInfo that uses async download operations.
    if dlInfo.isFileUrl:
      let pkgInfo = getPackageFromFileUrl(dlInfo.url, options, nimBin)
      let downloadRes = (dir: pkgInfo.getNimbleFileDir(), version: pkgInfo.basicInfo.version, vcsRevision: notSetSha1Hash)
      return (downloadRes, none(DownloadMethod))
    else:
      let downloadRes = await downloadPkgAsync(dlInfo.url, dlInfo.pv.ver, dlInfo.meth.get, dlInfo.subdir, options,
                    dlInfo.downloadDir, vcsRevision = dlInfo.vcsRevision, nimBin = nimBin)
      return (downloadRes, dlInfo.meth)

proc getPackageDownloadInfoUnchecked(pv: PkgTuple, options: Options, doPrompt = false): PackageDownloadInfo {.tags: [].} =
  {.cast(tags: []).}:
    getPackageDownloadInfo(pv, options, doPrompt)

proc downloadPkgFromUrlAsync*(pv: PkgTuple, options: Options, doPrompt = false, nimBin: Option[string]): Future[(DownloadPkgResult, Option[DownloadMethod])] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Async version of downloadPkgFromUrl that downloads from a package URL.
    let dlInfo = getPackageDownloadInfoUnchecked(pv, options, doPrompt)
    return await downloadFromDownloadInfoAsync(dlInfo, options, nimBin)

proc downloadPkInfoForPvAsync*(pv: PkgTuple, options: Options, doPrompt = false, nimBin: Option[string]): Future[PackageInfo] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Async version of downloadPkInfoForPv that downloads and gets package info.
    let downloadRes = await downloadPkgFromUrlAsync(pv, options, doPrompt, nimBin)
    return getPkgInfo(downloadRes[0].dir, options, nimBin, pikRequires)

var downloadCache {.threadvar.}: Table[string, Future[seq[PackageMinimalInfo]]]

var cloneLocks {.threadvar.}: Table[string, AsyncLock]

proc minimalPackageImpl(pv: PkgTuple, options: Options, nimBin: Option[string],
                        lazy: bool): Future[seq[PackageMinimalInfo]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Internal implementation of async download without caching. `lazy`
    ## reads only what is at hand of a range's versions
    ## (`listPackageMinimalVersionsFromRepo`).
    if pv.name == "": return newSeq[PackageMinimalInfo]()
    if pv.isNim and not options.disableNimBinaries:
      if pv.ver.kind == verSpecial:
        # For special versions, use sync download (nim binary downloads don't benefit from async)
        {.gcsafe.}:
          return await downloadNimSpecialVersion(pv, options)
      return await getAllNimReleases(options, getNimVersionFromBin(nimBin.getNimBin))

    # During version discovery, we only need to read .nimble files, not compile code
    # So we ignore submodules to speed up cloning and avoid failures from broken submodules
    var versionDiscoveryOptions = options
    versionDiscoveryOptions.ignoreSubmodules = true

    if pv.name.isFileURL:
      return @[getPackageFromFileUrl(pv.name, versionDiscoveryOptions, nimBin).getMinimalInfo(versionDiscoveryOptions)]

    # Packages in different subdirectories of one repository share its clone,
    # and a download starts by deleting it: one at a time.
    let dlInfo = getPackageDownloadInfoUnchecked(pv, versionDiscoveryOptions)
    let clone = cloneLocks.mgetOrPut(dlInfo.downloadDir, newAsyncLock())
    var unread: seq[PackageMinimalInfo]
    await clone.acquire()
    try:
      let (downloadRes, downloadMeth) = await downloadFromDownloadInfoAsync(dlInfo, versionDiscoveryOptions, nimBin)
      if pv.ver.kind in [verSpecial, verEq]: #if special or equal, we dont retrieve more versions as we only need one.
        let pkgInfo = getPkgInfo(downloadRes.dir, versionDiscoveryOptions, nimBin, pikRequires)
        result = @[pkgInfo.getMinimalInfo(versionDiscoveryOptions)]
      elif lazy:
        (result, unread) = await listPackageMinimalVersionsFromRepo(downloadRes.dir, pv, downloadMeth.get, versionDiscoveryOptions, nimBin, dlInfo.downloadDir)
      else:
        result = await getPackageMinimalVersionsFromRepo(downloadRes.dir, pv, downloadMeth.get, versionDiscoveryOptions, nimBin)
    finally:
      clone.release()
    result.add unread

    #Make sure the url is set for the package
    if pv.name.isUrl:
      for r in result.mitems:
        # Always set URL for URL-based packages to ensure subdirectories have correct URL
        r.url = pv.name
    elif result.len > 0 and result[0].url == "":
      # For name-based discovery, resolve the canonical URL so that
      # normalizeRequirements can match URL-based requirements to this package.
      try:
        let dlInfo = getPackageDownloadInfoUnchecked(pv, versionDiscoveryOptions, doPrompt = false)
        for r in result.mitems:
          r.url = dlInfo.url
      except CatchableError:
        discard

proc downloadMinimalPackageImpl(pv: PkgTuple, options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    return await minimalPackageImpl(pv, options, nimBin, lazy = false)

proc listMinimalPackageImpl(pv: PkgTuple, options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    return await minimalPackageImpl(pv, options, nimBin, lazy = true)

proc computeDownloadCacheKey*(pv: PkgTuple, options: Options): string =
  ## Canonical cache key for a package's version discovery download.
  ## Uses the package URL (not the version) since a range/tag download fetches all
  ## tagged versions anyway, so name- and URL-based range requirements for the same
  ## repo can share one download.
  ##
  ## Exception: a special version (e.g. a pinned #<commit>) is downloaded on its
  ## own — it does NOT enumerate tags (see the `verSpecial` early-out in
  ## downloadMinimalPackageImpl) — and that download is what learns the commit's
  ## semantic version. A range download of the same repo never fetches that commit,
  ## so the two must not share a memoization entry: otherwise, whichever runs first
  ## wins and, if the range wins, the pinned commit is never downloaded, its
  ## semantic version is never learned, and it can no longer satisfy a coexisting
  ## normal `>=` constraint — 
  try:
    if pv.name.isFileURL or pv.name.isURL or (pv.isNim and not options.disableNimBinaries):
      # For special cases, use the name as-is
      result = pv.name
    else:
      # For package names, resolve to canonical URL for proper deduplication.
      # Include the subdir so packages that are different subdirs of the same
      # repo (e.g. issue678 dependency_1 / dependency_2) get distinct keys.
      try:
        let dlInfo = getPackageDownloadInfo(pv, options, doPrompt = false)
        result = dlInfo.url
        if dlInfo.subdir.len > 0:
          result.add "?subdir=" & dlInfo.subdir
      except:
        result = pv.name
  except:
    result = pv.name
  if pv.ver.kind == verSpecial:
    result.add "@" & $pv.ver

proc computeDownloadCacheKeyUnchecked(pv: PkgTuple, options: Options): string {.tags: [].} =
  {.cast(tags: []).}:
    computeDownloadCacheKey(pv, options)

proc memoizedDownloadMinimal*(pv: PkgTuple, options: Options, nimBin: Option[string],
    fetch: GetPackageMinimal, kind = ""): Future[seq[PackageMinimalInfo]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Memoizes version discovery downloads for the lifetime of a resolution
    ## pass. Fetches of another `kind` don't share their answers.
    let cacheKey = kind & computeDownloadCacheKeyUnchecked(pv, options)

    if downloadCache.hasKey(cacheKey):
      return await downloadCache[cacheKey]

    let downloadFuture = fetch(pv, options, nimBin)
    downloadCache[cacheKey] = downloadFuture

    try:
      result = await downloadFuture
    except CatchableError:
      downloadCache.del(cacheKey)
      raise

proc downloadMinimalPackage*(pv: PkgTuple, options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Async version of downloadMinimalPackage with deduplication.
    ## If multiple calls request the same package concurrently, they share the same download.
    ## Cache key uses canonical package URL (not version) since we download all versions anyway.
    return await memoizedDownloadMinimal(pv, options, nimBin, downloadMinimalPackageImpl)

proc listMinimalPackage*(pv: PkgTuple, options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## `downloadMinimalPackage` reading only what is at hand of a package's
    ## versions - its checkout, and what the cache holds. It lists the others
    ## unread (`isUnreadVersion`), for `readUnreadVersions` to read when they
    ## are needed.
    return await memoizedDownloadMinimal(pv, options, nimBin, listMinimalPackageImpl,
                                         kind = "listed ")

proc addVersionUnique*(versions: var seq[PackageMinimalInfo], incoming: PackageMinimalInfo) =
  ## Adds a version if no entry with the same name+version already exists.
  ## When duplicate special versions carry different amounts of metadata, keep
  ## the existing package identity and enrich its version with the semantic
  ## version discovered from the compiler.
  for existing in versions.mitems:
    if cmpIgnoreCase(existing.name, incoming.name) == 0 and
        existing.version == incoming.version:
      if existing.version.isSpecial and
          existing.version.speSemanticVersion.isNone and
          incoming.version.speSemanticVersion.isSome:
        existing.version.speSemanticVersion =
          incoming.version.speSemanticVersion
      return
  versions.add incoming

proc fillPackageTableFromPreferred*(packages: var Table[string, PackageVersions], preferredPackages: seq[PackageMinimalInfo]) =
  for pkg in preferredPackages:
    if not packages.hasKey(pkg.name):
      packages[pkg.name] = PackageVersions(pkgName: pkg.name, versions: @[pkg])
    else:
      packages[pkg.name].versions.addVersionUnique pkg

proc getInstalledMinimalPackages*(options: Options): seq[PackageMinimalInfo] =
  getInstalledPkgsMin(options.getPkgsDir(), options).mapIt(it.getMinimalInfo(options))

proc getMinimalFromPreferred*(pv: PkgTuple, getMinimalPackage: GetPackageMinimal, preferredPackages: seq[PackageMinimalInfo], options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Async version of getMinimalFromPreferred that uses async package fetching.
    # Check if we have a preferred package first
    for pp in preferredPackages:
      if pp.name != pv.name and pp.url != pv.name:
        continue
      # A `#branch`/`#commit`/`#tag` requirement is only met by a package that
      # actually is that ref, so it takes `satisfiesConstraint` rather than
      # `withinRange`, which accepts any normal version for a special range.
      # Being lenient here is not merely permissive: the caller relabels every
      # candidate it gets back as the requested special version, so an installed
      # `2.4.0` would enter the version table posing as `#<commit>` while still
      # carrying 2.4.0's own requirements - and the solver would then hold that
      # release's dependencies for a revision that changed them.
      let satisfies =
        if pv.ver.kind == verSpecial: pp.version.satisfiesConstraint(pv.ver)
        else: pp.version.withinRange(pv.ver)
      if satisfies:
        result.add pp

    # Try to download all versions to give the SAT solver full choice
    try:
      let downloaded = await getMinimalPackage(pv, options, nimBin)
      for pkg in downloaded:
        result.addUnique pkg
    except CatchableError as e:
      # If download fails but we have preferred packages, use those
      if result.len == 0:
        raise e

proc expandActiveFeatures(pkgMin: var PackageMinimalInfo, versions: Table[string, PackageVersions]) =
  ## If the package has globally active features, expand them into its requires.
  for featureStr in getGloballyActiveFeatures():
    let parts = featureStr.split(".")
    if parts.len != 3: continue
    if cmpIgnoreCase(parts[1], pkgMin.name) != 0: continue
    let featureName = parts[2]
    if featureName in pkgMin.features:
      for req in pkgMin.features[featureName]:
        pkgMin.requires.addUnique(convertNimAliasToNim(req))

proc mergeVersionTables*(dest: var Table[string, PackageVersions], source: Table[string, PackageVersions]) =
  ## Helper proc to merge version tables.
  for pkgName, pkgVersions in source:
    if pkgName notin dest:
      dest[pkgName] = pkgVersions
    else:
      for ver in pkgVersions.versions:
        dest[pkgName].versions.addVersionUnique ver

proc addDiscovered(table: var Table[string, PackageVersions], pv: PkgTuple,
                   pkgMins: var seq[PackageMinimalInfo]) =
  ## Files the versions found for `pv` under their package name. A version
  ## found for a special requirement becomes that special version, keeping
  ## the version its nimble file declares as its semantic version.
  for pkgMin in pkgMins.mitems:
    let pkgName = pkgMin.name.toLower
    if pv.ver.kind == verSpecial and pkgMin.version.speSemanticVersion.isNone:
      var specialVer = newVersion($pv.ver)
      specialVer.speSemanticVersion = some($pkgMin.version)
      pkgMin.version = specialVer
    if pkgName notin table:
      table[pkgName] = PackageVersions(pkgName: pkgName, versions: @[pkgMin])
    else:
      table[pkgName].versions.addVersionUnique pkgMin

proc discoverRequirement*(pv: PkgTuple, getMinimalPackage: GetPackageMinimal,
    preferredPackages: seq[PackageMinimalInfo], options: Options,
    nimBin: Option[string]): Future[TableRef[string, PackageVersions]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## The versions that can meet `pv`, filed the way `processRequirements`
    ## files them, without going on to their own requirements: the step a
    ## search that fetches as it goes takes for each requirement it reaches.
    result = newTable[string, PackageVersions]()
    try:
      var pkgMins = await getMinimalFromPreferred(pv, getMinimalPackage, preferredPackages, options, nimBin)
      for pkgMin in pkgMins.mitems:
        expandActiveFeatures(pkgMin, result[])
      result[].addDiscovered(pv, pkgMins)
      if pv.name.isUrl and pkgMins.len > 0:
        result[pv.name] = PackageVersions(pkgName: pv.name, versions: pkgMins)
    except CatchableError as e:
      displayWarning(&"Error processing requirements for {pv.name}: {e.msg}", HighPriority)

proc readUnreadVersion(mi: PackageMinimalInfo, options: Options,
                       nimBin: Option[string]): Future[Option[PackageMinimalInfo]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    let tag = unreadTags[mi.unreadKey]
    let clone = cloneLocks.mgetOrPut(tag.lockDir, newAsyncLock())
    await clone.acquire()
    try:
      return await readTaggedVersion(tag.gitRoot, tag.subdirPath, tag.name,
                                     tag.version, tag.tag, options, nimBin)
    finally:
      clone.release()

proc readUnreadVersions*(versions: seq[PackageMinimalInfo], options: Options,
                         nimBin: Option[string]): Future[seq[Option[PackageMinimalInfo]]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Reads versions `listMinimalPackage` listed unread, all at once: each as
    ## `discoverRequirement` files what `downloadMinimalPackage` reads of it,
    ## or none when its tag has no nimble file to read. The cache keeps them.
    var versionDiscoveryOptions = options
    versionDiscoveryOptions.ignoreSubmodules = true
    var reading: seq[Future[Option[PackageMinimalInfo]]]
    for mi in versions:
      reading.add readUnreadVersion(mi, versionDiscoveryOptions, nimBin)
    await allFutures(reading)
    var cache = readTaggedVersionsCache(options)
    var cached = false
    for i, read in reading:
      var found = if read.failed: none(PackageMinimalInfo) else: read.read()
      if found.isSome:
        let name = unreadTags[versions[i].unreadKey].name
        cache.mgetOrPut(normalizePackageName(name), @[]).addUnique found.get
        cached = true
        found.get.url = versions[i].url
        expandActiveFeatures(found.get, initTable[string, PackageVersions]())
      result.add found
    if cached:
      writeTaggedVersionsCache(cache, options)

proc processRequirements*(pv: PkgTuple, visitedParam: HashSet[PkgTuple], getMinimalPackage: GetPackageMinimal, preferredPackages: seq[PackageMinimalInfo] = newSeq[PackageMinimalInfo](), options: Options, nimBin: Option[string]): Future[TableRef[string, PackageVersions]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Async version of processRequirements that returns computed versions instead of mutating shared state.
    ## This allows for safe parallel execution since there's no shared mutable state.
    ## Takes visited by value since we pass separate copies to each top-level dependency branch.
    ## Processes all nested dependencies in parallel for maximum performance.
    result = newTable[string, PackageVersions]()

    # Make a local mutable copy
    var visited = visitedParam

    if pv in visited:
      return

    visited.incl pv

    # For special versions, always process them even if we think we have the package
    # This ensures the special version gets downloaded and added to the version table
    try:
      var pkgMins = await getMinimalFromPreferred(pv, getMinimalPackage, preferredPackages, options, nimBin)

      # Expand any globally active features into package requires
      for pkgMin in pkgMins.mitems:
        expandActiveFeatures(pkgMin, result[])

      # Collect all unique requirements from all package versions.
      # Special versions (like #head) are kept separately even if the same
      # package name exists with a normal version, since they need their own resolution.
      var allRequirements: seq[PkgTuple] = @[]
      for pkgMin in pkgMins:
        for req in pkgMin.requires:
          var found = false
          for existing in allRequirements:
            if existing.name == req.name and
               existing.ver.kind == req.ver.kind:
              found = true
              break
          if not found:
            allRequirements.add req

      # Process all unique requirements (parallel or sequential based on flag)
      var failedReqs: seq[string] = @[]
      var reqResults: seq[TableRef[string, PackageVersions]] = @[]
      if not options.parallelDiscovery:
        for req in allRequirements:
          try:
            let reqResult = await processRequirements(req, visited, getMinimalPackage, preferredPackages, options, nimBin)
            reqResults.add reqResult
          except CatchableError:
            failedReqs.add req.name
      else:
        var reqFutures: seq[Future[TableRef[string, PackageVersions]]] = @[]
        var reqNames: seq[string] = @[]
        for req in allRequirements:
          reqFutures.add processRequirements(req, visited, getMinimalPackage, preferredPackages, options, nimBin)
          reqNames.add req.name
        if reqFutures.len > 0:
          await allFutures(reqFutures)
        for i, reqFut in reqFutures:
          if reqFut.failed:
            failedReqs.add reqNames[i]
          else:
            reqResults.add reqFut.read()

      # Filter out package versions that depend on failed requirements
      var validPkgMins: seq[PackageMinimalInfo] = @[]
      for pkgMin in pkgMins:
        var allRequirementsValid = true
        for req in pkgMin.requires:
          if req.name in failedReqs:
            allRequirementsValid = false
            displayWarning(&"Skipping package {pkgMin.name}@{pkgMin.version} due to invalid dependency: {req.name}", HighPriority)
            break
        if allRequirementsValid:
          validPkgMins.add pkgMin

      # Add valid packages to the result table
      result[].addDiscovered(pv, validPkgMins)

      # Merge all successful requirement results
      for reqResult in reqResults:
        mergeVersionTables(result[], reqResult[])

      # Only add URL packages if we have valid versions
      if pv.name.isUrl and validPkgMins.len > 0:
        result[pv.name] = PackageVersions(pkgName: pv.name, versions: validPkgMins)

    except CatchableError as e:
      # Some old packages may have invalid requirements (i.e repos that doesn't exist anymore)
      # we need to avoid adding it to the package table as this will cause the solver to fail
      displayWarning(&"Error processing requirements for {pv.name}: {e.msg}", HighPriority)

proc collectAllVersions*(package: PackageMinimalInfo, options: Options, getMinimalPackage: GetPackageMinimal, preferredPackages: seq[PackageMinimalInfo] = newSeq[PackageMinimalInfo](), nimBin: Option[string]): Future[TableRef[string, PackageVersions]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Collects all package versions for dependency resolution.
    ## Processes top-level dependencies in parallel (default) or sequentially (with --sync).
    ## Each branch gets its own visited set to avoid race conditions on shared state.

    result = newTable[string, PackageVersions]()
    if not options.parallelDiscovery:
      for pv in package.requires:
        var visitedCopy = initHashSet[PkgTuple]()
        let resultTable = await processRequirements(pv, visitedCopy, getMinimalPackage, preferredPackages, options, nimBin)
        mergeVersionTables(result[], resultTable[])
    else:
      var futures: seq[Future[TableRef[string, PackageVersions]]] = @[]
      for pv in package.requires:
        var visitedCopy = initHashSet[PkgTuple]()
        futures.add processRequirements(pv, visitedCopy, getMinimalPackage, preferredPackages, options, nimBin)
      await allFutures(futures)
      for fut in futures:
        if not fut.failed:
          mergeVersionTables(result[], fut.read()[])

proc addDiscoveryErrors*(output: var string, options: Options) =
  ## The git errors version discovery ran into: a package that seems not to
  ## exist may only have been unreachable.
  if options.satResult.gitErrors.len > 0:
    output.add "The following errors occurred during package discovery (could be network issues):\n"
    for err in options.satResult.gitErrors:
      output.add &"  - {err}\n"
