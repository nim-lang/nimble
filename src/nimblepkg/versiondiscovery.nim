# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import std/[os, tables, uri, options, strutils, sets, strformat, json, jsonutils]
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

proc getCacheDownloadDir*(url: string, ver: VersionRange, options: Options, vcsRevision: Sha1Hash = notSetSha1Hash): string =
  # Use version-agnostic cache directory ONLY for verAny (used during package discovery).
  # This allows enumerating all versions from a single git clone.
  # For all other version types (specific versions, ranges, special versions),
  # use version-specific directories to ensure correct version is checked out.
  let puri = parseUri(url)
  var dirName = ""
  for i in puri.hostname:
    case i
    of strutils.Letters, strutils.Digits:
      dirName.add i
    else: discard
  dirName.add "_"
  for i in puri.path:
    case i
    of strutils.Letters, strutils.Digits:
      dirName.add i
    else: discard
  # Include query string (e.g., ?subdir=generator) to differentiate subdirectories
  if puri.query != "":
    dirName.add "_"
    for i in puri.query:
      case i
      of strutils.Letters, strutils.Digits:
        dirName.add i
      else: discard
  # For any version type other than verAny, include the version in the directory name
  # This ensures each specific version gets its own cache directory
  if ver.kind != verAny:
    dirName.add "_"
    for i in $ver:
      case i
      of strutils.Letters, strutils.Digits:
        dirName.add i
      else: discard
  # When vcsRevision is specified (e.g., from lock file), include it in the cache directory
  # This ensures exact commits get their own cache directory
  if vcsRevision != notSetSha1Hash:
    dirName.add "_"
    dirName.add $vcsRevision
  options.pkgCachePath / dirName

proc getPackageDownloadInfo*(pv: PkgTuple, options: Options, doPrompt = false, vcsRevision: Sha1Hash = notSetSha1Hash): PackageDownloadInfo =
  if pv.name.isFileURL:
    return PackageDownloadInfo(meth: none(DownloadMethod), url: pv.name, subdir: "", downloadDir: "", pv: pv, vcsRevision: notSetSha1Hash)
  let (meth, url, metadata) =
      getDownloadInfo(pv, options, doPrompt, ignorePackageCache = false)
  let subdir = metadata.getOrDefault("subdir")
  let downloadDir = getCacheDownloadDir(url, pv.ver, options, vcsRevision)
  PackageDownloadInfo(meth: some meth, url: url, subdir: subdir, downloadDir: downloadDir, pv: pv, vcsRevision: vcsRevision)

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

proc getAllNimReleases*(options: Options, nimVersion: Option[Version]): seq[PackageMinimalInfo] =
  let releases = getOfficialReleases(options)
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

proc getPackageMinimalVersionsFromRepo*(
    repoDir: string,
    pkg: PkgTuple,
    downloadMethod: DownloadMethod,
    options: Options,
    nimBin: Option[string]
): Future[seq[PackageMinimalInfo]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Reads nimble files directly from git tags without checkout, using
    ## git ls-tree and git show to avoid expensive checkout + copyDir operations.
    result = newSeq[PackageMinimalInfo]()
    let name = pkg[0]

    # Find the git repository root (repoDir might be a subdirectory)
    var gitRoot = repoDir
    var subdirPath = ""

    # Check if we're in a subdirectory by looking for .git
    try:
      if not dirExists(gitRoot / ".git"):
        # Walk up to find the git root
        var currentDir = repoDir
        while not dirExists(currentDir / ".git") and currentDir.parentDir() != currentDir:
          currentDir = currentDir.parentDir()

        if dirExists(currentDir / ".git"):
          gitRoot = currentDir
          # Calculate relative path from git root to repoDir
          subdirPath = repoDir.relativePath(gitRoot).replace("\\", "/")
        # If no .git found, proceed anyway - git commands might still work
    except:
      # If anything fails, just use repoDir as-is
      gitRoot = repoDir

    # Check cache first
    try:
      let taggedVersions = getTaggedVersions(name, options)
      if taggedVersions.isSome:
        var cacheFresh = true
        try:
          let localTags = await getTagsListAsync(gitRoot, downloadMethod)
          cacheFresh = cachedTagsCoverLocalTags(taggedVersions.get, localTags)
        except CatchableError:
          discard
        if cacheFresh:
          return taggedVersions.get
    except:
      discard

    # Fetch all tags
    var tags = initOrderedTable[Version, string]()
    try:
      await gitFetchTagsAsync(gitRoot, downloadMethod, options)
      tags = (await getTagsListAsync(gitRoot, downloadMethod)).getVersionList()
    except ref NimbleGitError as e:
      options.satResult.gitErrors.add(&"Git error fetching tags for {name} (could be a network issue): {e.msg}")
      displayWarning(&"Git error fetching tags for {name}: {e.msg}", HighPriority)
      return
    except CatchableError as e:
      displayWarning(&"Error fetching tags for {name}: {e.msg}", HighPriority)
      return

    # Get current HEAD version info (files already on disk)
    try:
      result.add getPkgInfo(repoDir, options, nimBin).getMinimalInfo(options)
    except CatchableError as e:
      displayWarning(&"Error getting package info for {name}: {e.msg}", HighPriority)

    # Process each tag - read nimble file directly from git
    for (ver, tag) in tags.pairs:
      try:
        # List nimble files in this tag
        let nimbleFiles = await gitListNimbleFilesInCommitAsync(gitRoot, tag)
        if nimbleFiles.len == 0:
          displayInfo(&"No nimble file found in tag {tag} for {name}", LowPriority)
          continue

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
          continue

        # Prefer nimble file matching package name
        var nimbleFilePath = relevantNimbleFiles[0]
        let expectedName = name & ".nimble"
        for nf in relevantNimbleFiles:
          if nf.endsWith(expectedName) or nf == expectedName:
            nimbleFilePath = nf
            break

        # Read nimble file content from git
        let nimbleContent = await gitShowFileAsync(gitRoot, tag, nimbleFilePath)

        # Try declarative parser first (faster, no temp file needed)
        let minimalInfo = getMinimalInfoFromContent(nimbleContent, name, ver, url = "", options)
        if minimalInfo.isSome:
          result.addUnique(minimalInfo.get)
        else:
          # Fall back to temp file + VM parser for complex nimble files
          let tempNimbleFile = getTempDir() / &"{name}_{tag}.nimble"
          try:
            writeFile(tempNimbleFile, nimbleContent)
            let pkgInfo = getPkgInfoFromFile(nimBin, tempNimbleFile, options, useCache=false)
            result.addUnique(pkgInfo.getMinimalInfo(options))
          finally:
            try:
              removeFile(tempNimbleFile)
            except: discard

      except CatchableError as e:
        displayInfo(&"Error reading tag {tag} for {name}: {e.msg}", LowPriority)

    # Save to cache
    try:
      saveTaggedVersions(name, result, options)
    except CatchableError as e:
      displayWarning(&"Error saving tagged versions for {name}: {e.msg}", LowPriority)

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

proc downloadPkgFromUrlAsync*(pv: PkgTuple, options: Options, doPrompt = false, nimBin: Option[string]): Future[(DownloadPkgResult, Option[DownloadMethod])] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Async version of downloadPkgFromUrl that downloads from a package URL.
    let dlInfo = getPackageDownloadInfo(pv, options, doPrompt)
    return await downloadFromDownloadInfoAsync(dlInfo, options, nimBin)

proc downloadPkInfoForPvAsync*(pv: PkgTuple, options: Options, doPrompt = false, nimBin: Option[string]): Future[PackageInfo] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Async version of downloadPkInfoForPv that downloads and gets package info.
    let downloadRes = await downloadPkgFromUrlAsync(pv, options, doPrompt, nimBin)
    return getPkgInfo(downloadRes[0].dir, options, nimBin, pikRequires)

var downloadCache {.threadvar.}: Table[string, Future[seq[PackageMinimalInfo]]]

proc downloadMinimalPackageImpl(pv: PkgTuple, options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Internal implementation of async download without caching.
    if pv.name == "": return newSeq[PackageMinimalInfo]()
    if pv.isNim and not options.disableNimBinaries:
      if pv.ver.kind == verSpecial:
        # For special versions, use sync download (nim binary downloads don't benefit from async)
        {.gcsafe.}:
          return await downloadNimSpecialVersion(pv, options)
      return getAllNimReleases(options, getNimVersionFromBin(nimBin.getNimBin))

    # During version discovery, we only need to read .nimble files, not compile code
    # So we ignore submodules to speed up cloning and avoid failures from broken submodules
    var versionDiscoveryOptions = options
    versionDiscoveryOptions.ignoreSubmodules = true

    if pv.name.isFileURL:
      return @[getPackageFromFileUrl(pv.name, versionDiscoveryOptions, nimBin).getMinimalInfo(versionDiscoveryOptions)]

    if pv.ver.kind in [verSpecial, verEq]: #if special or equal, we dont retrieve more versions as we only need one.
      let pkgInfo = await downloadPkInfoForPvAsync(pv, versionDiscoveryOptions, false, nimBin)
      result = @[pkgInfo.getMinimalInfo(versionDiscoveryOptions)]
    else:
      let (downloadRes, downloadMeth) = await downloadPkgFromUrlAsync(pv, versionDiscoveryOptions, false, nimBin)
      result = await getPackageMinimalVersionsFromRepo(downloadRes.dir, pv, downloadMeth.get, versionDiscoveryOptions, nimBin)

    #Make sure the url is set for the package
    if pv.name.isUrl:
      for r in result.mitems:
        # Always set URL for URL-based packages to ensure subdirectories have correct URL
        r.url = pv.name
    elif result.len > 0 and result[0].url == "":
      # For name-based discovery, resolve the canonical URL so that
      # normalizeRequirements can match URL-based requirements to this package.
      try:
        let dlInfo = getPackageDownloadInfo(pv, versionDiscoveryOptions, doPrompt = false)
        for r in result.mitems:
          r.url = dlInfo.url
      except CatchableError:
        discard

proc computeDownloadCacheKey*(pv: PkgTuple, options: Options): string =
  ## Canonical cache key for a package's version discovery download.
  ## Uses the package URL (not the version) since we download all versions anyway,
  ## so name- and URL-based requirements for the same repo can share one download.
  try:
    if pv.name.isFileURL or pv.name.isURL or (pv.isNim and not options.disableNimBinaries):
      # For special cases, use the name as-is
      return pv.name
    else:
      # For package names, resolve to canonical URL for proper deduplication.
      # Include the subdir so packages that are different subdirs of the same
      # repo (e.g. issue678 dependency_1 / dependency_2) get distinct keys.
      try:
        let dlInfo = getPackageDownloadInfo(pv, options, doPrompt = false)
        result = dlInfo.url
        if dlInfo.subdir.len > 0:
          result.add "?subdir=" & dlInfo.subdir
        return result
      except:
        return pv.name
  except:
    pv.name

proc memoizedDownloadMinimal*(pv: PkgTuple, options: Options, nimBin: Option[string],
    fetch: GetPackageMinimal): Future[seq[PackageMinimalInfo]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Memoizes version discovery downloads for the lifetime of a resolution pass.
    let cacheKey = computeDownloadCacheKey(pv, options)

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

proc fillPackageTableFromPreferred*(packages: var Table[string, PackageVersions], preferredPackages: seq[PackageMinimalInfo]) =
  for pkg in preferredPackages:
    if not hasVersion(packages, pkg.name, pkg.version):
      if not packages.hasKey(pkg.name):
        packages[pkg.name] = PackageVersions(pkgName: pkg.name, versions: @[pkg])
      else:
        packages[pkg.name].versions.add pkg

proc getInstalledMinimalPackages*(options: Options): seq[PackageMinimalInfo] =
  getInstalledPkgsMin(options.getPkgsDir(), options).mapIt(it.getMinimalInfo(options))

proc getMinimalFromPreferred*(pv: PkgTuple, getMinimalPackage: GetPackageMinimal, preferredPackages: seq[PackageMinimalInfo], options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Async version of getMinimalFromPreferred that uses async package fetching.
    # Check if we have a preferred package first
    for pp in preferredPackages:
      if (pp.name == pv.name or pp.url == pv.name) and pp.version.withinRange(pv.ver):
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

proc addVersionUnique*(versions: var seq[PackageMinimalInfo], ver: PackageMinimalInfo) =
  ## Adds a version if no entry with the same name+version already exists.
  ## Uses name+version comparison instead of full struct equality to avoid
  ## duplicates from parallel branches that discover the same package independently.
  for existing in versions:
    if cmpIgnoreCase(existing.name, ver.name) == 0 and existing.version == ver.version:
      return
  versions.add ver

proc mergeVersionTables(dest: var Table[string, PackageVersions], source: Table[string, PackageVersions]) =
  ## Helper proc to merge version tables.
  for pkgName, pkgVersions in source:
    if pkgName notin dest:
      dest[pkgName] = pkgVersions
    else:
      for ver in pkgVersions.versions:
        dest[pkgName].versions.addVersionUnique ver

proc processRequirements*(pv: PkgTuple, visitedParam: HashSet[PkgTuple], getMinimalPackage: GetPackageMinimal, preferredPackages: seq[PackageMinimalInfo] = newSeq[PackageMinimalInfo](), options: Options, nimBin: Option[string]): Future[Table[string, PackageVersions]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Async version of processRequirements that returns computed versions instead of mutating shared state.
    ## This allows for safe parallel execution since there's no shared mutable state.
    ## Takes visited by value since we pass separate copies to each top-level dependency branch.
    ## Processes all nested dependencies in parallel for maximum performance.
    result = initTable[string, PackageVersions]()

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
        expandActiveFeatures(pkgMin, result)

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
      var reqResults: seq[Table[string, PackageVersions]] = @[]
      if not options.parallelDiscovery:
        for req in allRequirements:
          try:
            let reqResult = await processRequirements(req, visited, getMinimalPackage, preferredPackages, options, nimBin)
            reqResults.add reqResult
          except CatchableError:
            failedReqs.add req.name
      else:
        var reqFutures: seq[Future[Table[string, PackageVersions]]] = @[]
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
      for pkgMin in validPkgMins.mitems:
        let pkgName = pkgMin.name.toLower
        if pv.ver.kind == verSpecial:
          # Keep both the commit hash and the actual semantic version
          if pkgMin.version.speSemanticVersion.isSome:
            discard
          else:
            var specialVer = newVersion($pv.ver)
            specialVer.speSemanticVersion = some($pkgMin.version)
            pkgMin.version = specialVer

          if pkgName notin result:
            result[pkgName] = PackageVersions(pkgName: pkgName, versions: @[pkgMin])
          else:
            result[pkgName].versions.addVersionUnique pkgMin
        else:
          if pkgName notin result:
            result[pkgName] = PackageVersions(pkgName: pkgName, versions: @[pkgMin])
          else:
            result[pkgName].versions.addVersionUnique pkgMin

      # Merge all successful requirement results
      for reqResult in reqResults:
        mergeVersionTables(result, reqResult)

      # Only add URL packages if we have valid versions
      if pv.name.isUrl and validPkgMins.len > 0:
        result[pv.name] = PackageVersions(pkgName: pv.name, versions: validPkgMins)

    except CatchableError as e:
      # Some old packages may have invalid requirements (i.e repos that doesn't exist anymore)
      # we need to avoid adding it to the package table as this will cause the solver to fail
      displayWarning(&"Error processing requirements for {pv.name}: {e.msg}", HighPriority)

proc collectAllVersions*(package: PackageMinimalInfo, options: Options, getMinimalPackage: GetPackageMinimal, preferredPackages: seq[PackageMinimalInfo] = newSeq[PackageMinimalInfo](), nimBin: Option[string]): Future[Table[string, PackageVersions]] {.async.} =
  {.cast(raises: [CatchableError]).}:
    ## Collects all package versions for dependency resolution.
    ## Processes top-level dependencies in parallel (default) or sequentially (with --sync).
    ## Each branch gets its own visited set to avoid race conditions on shared state.
    ## Returns the merged version table.

    result = initTable[string, PackageVersions]()
    if not options.parallelDiscovery:
      for pv in package.requires:
        var visitedCopy = initHashSet[PkgTuple]()
        let resultTable = await processRequirements(pv, visitedCopy, getMinimalPackage, preferredPackages, options, nimBin)
        mergeVersionTables(result, resultTable)
    else:
      var futures: seq[Future[Table[string, PackageVersions]]] = @[]
      for pv in package.requires:
        var visitedCopy = initHashSet[PkgTuple]()
        futures.add processRequirements(pv, visitedCopy, getMinimalPackage, preferredPackages, options, nimBin)
      await allFutures(futures)
      for fut in futures:
        if not fut.failed:
          mergeVersionTables(result, fut.read())
