# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import std/[os, tables, uri, options, strutils, sets, strformat, json, jsonutils]
import chronos
import version, packageinfotypes, download, packageinfo, packageparser, options,
  sha1hashes, tools, downloadnim, cli, declarativeparser, common
import compat/[sequtils]
export declarativeparser

type
  GetPackageMinimal* = proc (pv: PkgTuple, options: Options, nimBin: Option[string]): seq[PackageMinimalInfo]
  GetPackageMinimalAsync* = proc (pv: PkgTuple, options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.}

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

proc getPackageMinimalVersionsFromRepo*(repoDir: string, pkg: PkgTuple, version: Version, downloadMethod: DownloadMethod, options: Options, nimBin: Option[string]): seq[PackageMinimalInfo] =
  result = newSeq[PackageMinimalInfo]()

  let name = pkg[0]
  let taggedVersions = getTaggedVersions(name, options)
  if taggedVersions.isSome:
    return taggedVersions.get

  # During version discovery, we only need to read .nimble files, not compile code
  # So we can safely ignore submodules to avoid issues with repos that have
  # submodules that fail to clone (e.g., waku's zerokit submodule)
  var versionDiscoveryOptions = options
  versionDiscoveryOptions.ignoreSubmodules = true

  # Fetch tags and use git show directly on repoDir (read-only git operations).
  # Only create a tempDir copy if we need the fallback checkout path (rare).
  var tags = initOrderedTable[Version, string]()
  try:
    gitFetchTags(repoDir, downloadMethod, versionDiscoveryOptions)
    tags = getTagsList(repoDir, downloadMethod).getVersionList()
  except NimbleGitError as e:
    options.satResult.gitErrors.add(&"Git error fetching tags for {name} (could be a network issue): {e.msg}")
    displayWarning(&"Git error fetching tags for {name}: {e.msg}", HighPriority)
  except CatchableError as e:
    displayWarning(&"Error fetching tags for {name}: {e.msg}", HighPriority)

  # Lazy copy: only created when fallback checkout is needed
  var tempDir = ""
  var tempDirCreated = false

  # Process all tagged versions (no limit)
  for (ver, tag) in tags.pairs:
    try:
      let tagVersion = newVersion($ver)

      if not tagVersion.withinRange(pkg[1]):
        displayInfo(&"Ignoring {name}:{tagVersion} because out of range {pkg[1]}", LowPriority)
        continue

      # Try git show + declarative parser first (faster, avoids checkout)
      var parsed = false
      try:
        let nimbleFiles = gitListNimbleFilesInCommit(repoDir, tag)
        if nimbleFiles.len > 0:
          # Prefer nimble file matching package name
          var nimbleFilePath = nimbleFiles[0]
          let expectedName = name & ".nimble"
          for nf in nimbleFiles:
            if nf.endsWith(expectedName) or nf == expectedName:
              nimbleFilePath = nf
              break

          let nimbleContent = gitShowFile(repoDir, tag, nimbleFilePath)
          let minimalInfo = getMinimalInfoFromContent(nimbleContent, name, tagVersion, url = "", options)
          if minimalInfo.isSome:
            result.addUnique(minimalInfo.get)
            parsed = true
      except CatchableError:
        discard  # Fall back to checkout approach

      # Fall back to checkout + VM parser if declarative parsing failed
      if not parsed:
        # Lazy copy: create tempDir only when we actually need to checkout
        if not tempDirCreated:
          tempDir = repoDir & "_versions"
          removeDir(tempDir)
          copyDir(repoDir, tempDir)
          tempDirCreated = true
        discard doCheckout(downloadMethod, tempDir, tag, versionDiscoveryOptions)
        result.addUnique getPkgInfo(tempDir, options, nimBin, pikRequires).getMinimalInfo(options)
        #here we copy the directory to its own folder so we have it cached for future usage
        let downloadInfo = getPackageDownloadInfo((name, tagVersion.toVersionRange()), options)
        if not dirExists(downloadInfo.downloadDir):
          copyDir(tempDir, downloadInfo.downloadDir)

    except CatchableError as e:
      displayWarning(
        &"Error reading tag {tag}: for package {name}. This may not be relevant as it could be an old version of the package. \n {e.msg}",
         HighPriority)

  # Add HEAD version last (tagged releases take precedence if same version exists)
  try:
    result.addUnique getPkgInfo(repoDir, options, nimBin, pikRequires).getMinimalInfo(options)
  except CatchableError as e:
    displayWarning(&"Error getting package info for {name}: {e.msg}", HighPriority)

  saveTaggedVersions(name, result, options)

  # Clean up tempDir if it was created
  if tempDirCreated:
    try:
      removeDir(tempDir)
    except CatchableError as e:
      displayWarning(&"Error cleaning up temporary directory {tempDir}: {e.msg}", LowPriority)

proc getPackageMinimalVersionsFromRepoAsync*(repoDir: string, pkg: PkgTuple, version: Version, downloadMethod: DownloadMethod, options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
  ## Async version of getPackageMinimalVersionsFromRepo that uses async operations for VCS commands.
  result = newSeq[PackageMinimalInfo]()

  let name = pkg[0]
  try:
    let taggedVersions = getTaggedVersions(name, options)
    if taggedVersions.isSome:
      return taggedVersions.get
  except CatchableError:
    discard # Continue with fetching from repo

  let tempDir = repoDir & "_versions"
  # During version discovery, we only need to read .nimble files, not compile code
  # So we can safely ignore submodules to avoid issues with repos that have
  # submodules that fail to clone (e.g., waku's zerokit submodule)
  var versionDiscoveryOptions = options
  versionDiscoveryOptions.ignoreSubmodules = true
  try:
    removeDir(tempDir)
    copyDir(repoDir, tempDir)
    var tags = initOrderedTable[Version, string]()
    try:
      await gitFetchTagsAsync(tempDir, downloadMethod, versionDiscoveryOptions)
      tags = (await getTagsListAsync(tempDir, downloadMethod)).getVersionList()
    except ref NimbleGitError as e:
      options.satResult.gitErrors.add(&"Git error fetching tags for {name} (could be a network issue): {e.msg}")
      displayWarning(&"Git error fetching tags for {name}: {e.msg}", HighPriority)
    except CatchableError as e:
      displayWarning(&"Error fetching tags for {name}: {e.msg}", HighPriority)

    # Process all tagged versions (no limit)
    for (ver, tag) in tags.pairs:
      try:
        let tagVersion = newVersion($ver)

        # Try git show + declarative parser first (faster, avoids checkout)
        var parsed = false
        try:
          let nimbleFiles = await gitListNimbleFilesInCommitAsync(tempDir, tag)
          if nimbleFiles.len > 0:
            # Prefer nimble file matching package name
            var nimbleFilePath = nimbleFiles[0]
            let expectedName = name & ".nimble"
            for nf in nimbleFiles:
              if nf.endsWith(expectedName) or nf == expectedName:
                nimbleFilePath = nf
                break

            let nimbleContent = await gitShowFileAsync(tempDir, tag, nimbleFilePath)
            let minimalInfo = getMinimalInfoFromContent(nimbleContent, name, tagVersion, url = "", options)
            if minimalInfo.isSome:
              result.addUnique(minimalInfo.get)
              parsed = true
        except CatchableError:
          discard  # Fall back to checkout approach

        # Fall back to checkout + VM parser if declarative parsing failed
        if not parsed:
          discard await doCheckoutAsync(downloadMethod, tempDir, tag, versionDiscoveryOptions)
          result.addUnique getPkgInfo(tempDir, options, nimBin, pikRequires).getMinimalInfo(options)
          #here we copy the directory to its own folder so we have it cached for future usage
          let downloadInfo = getPackageDownloadInfo((name, tagVersion.toVersionRange()), options)
          if not dirExists(downloadInfo.downloadDir):
            copyDir(tempDir, downloadInfo.downloadDir)

      except CatchableError as e:
        displayWarning(
          &"Error reading tag {tag}: for package {name}. This may not be relevant as it could be an old version of the package. \n {e.msg}",
           HighPriority)

    # Add HEAD version last (tagged releases take precedence if same version exists)
    try:
      result.addUnique getPkgInfo(repoDir, options, nimBin, pikRequires).getMinimalInfo(options)
    except CatchableError as e:
      displayWarning(&"Error getting package info for {name}: {e.msg}", HighPriority)

    try:
      saveTaggedVersions(name, result, options)
    except CatchableError as e:
      displayWarning(&"Error saving tagged versions for {name}: {e.msg}", LowPriority)
  finally:
    try:
      removeDir(tempDir)
    except CatchableError as e:
      displayWarning(&"Error cleaning up temporary directory {tempDir}: {e.msg}", LowPriority)

proc getPackageMinimalVersionsFromRepoAsyncFast*(
    repoDir: string,
    pkg: PkgTuple,
    downloadMethod: DownloadMethod,
    options: Options,
    nimBin: Option[string]
): Future[seq[PackageMinimalInfo]] {.async.} =
  ## Fast version that reads nimble files directly from git tags without checkout.
  ## Uses git ls-tree and git show to avoid expensive checkout + copyDir operations.
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

proc downloadMinimalPackage*(pv: PkgTuple, options: Options, nimBin: Option[string]): seq[PackageMinimalInfo] =
  if pv.name == "": return newSeq[PackageMinimalInfo]()
  if pv.isNim and not options.disableNimBinaries:
    if pv.ver.kind == verSpecial:
      # For special versions like #devel, #commit-sha, etc., download the binary
      # and get the actual version using the declarative parser
      let extractedDir = downloadAndExtractNimMatchedVersion(pv.ver, options)
      var ver = newVersion($pv.ver)
      let nimbleFile = extractedDir.get / "nim.nimble"
      if nimbleFile.fileExists:
        let nimVersion = extractNimVersion(nimbleFile)
        if nimVersion != "":
          ver.speSemanticVersion = some(nimVersion)
      return @[PackageMinimalInfo(name: "nim", version: ver)]
    return getAllNimReleases(options, getNimVersionFromBin(nimBin.get))
  # During version discovery, we only need to read .nimble files, not compile code
  # So we ignore submodules to speed up cloning and avoid failures from broken submodules
  var versionDiscoveryOptions = options
  versionDiscoveryOptions.ignoreSubmodules = true
  if pv.name.isFileURL:
    result = @[getPackageFromFileUrl(pv.name, versionDiscoveryOptions, nimBin).getMinimalInfo(versionDiscoveryOptions)]
    return
  if pv.ver.kind in [verSpecial, verEq]: #if special or equal, we dont retrieve more versions as we only need one.
    result = @[downloadPkInfoForPv(pv, versionDiscoveryOptions, false, nimBin).getMinimalInfo(versionDiscoveryOptions)]
  else:
    let (downloadRes, downloadMeth) = downloadPkgFromUrl(pv, versionDiscoveryOptions, false, nimBin)
    result = getPackageMinimalVersionsFromRepo(downloadRes.dir, pv, downloadRes.version, downloadMeth.get, versionDiscoveryOptions, nimBin)
  #Make sure the url is set for the package
  if pv.name.isUrl:
    for r in result.mitems:
      if r.url == "":
        r.url = pv.name

proc downloadFromDownloadInfoAsync*(dlInfo: PackageDownloadInfo, options: Options, nimBin: Option[string]): Future[(DownloadPkgResult, Option[DownloadMethod])] {.async.} =
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
  ## Async version of downloadPkgFromUrl that downloads from a package URL.
  let dlInfo = getPackageDownloadInfo(pv, options, doPrompt)
  return await downloadFromDownloadInfoAsync(dlInfo, options, nimBin)

proc downloadPkInfoForPvAsync*(pv: PkgTuple, options: Options, doPrompt = false, nimBin: Option[string]): Future[PackageInfo] {.async.} =
  ## Async version of downloadPkInfoForPv that downloads and gets package info.
  let downloadRes = await downloadPkgFromUrlAsync(pv, options, doPrompt, nimBin)
  return getPkgInfo(downloadRes[0].dir, options, nimBin, pikRequires)

var downloadCache {.threadvar.}: Table[string, Future[seq[PackageMinimalInfo]]]

proc downloadMinimalPackageAsyncImpl(pv: PkgTuple, options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
  ## Internal implementation of async download without caching.
  if pv.name == "": return newSeq[PackageMinimalInfo]()
  if pv.isNim and not options.disableNimBinaries:
    if pv.ver.kind == verSpecial:
      # For special versions, delegate to the sync version which handles downloading
      {.gcsafe.}:
        return downloadMinimalPackage(pv, options, nimBin)
    return getAllNimReleases(options, getNimVersionFromBin(nimBin.get))

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
    result = await getPackageMinimalVersionsFromRepoAsyncFast(downloadRes.dir, pv, downloadMeth.get, versionDiscoveryOptions, nimBin)

  #Make sure the url is set for the package
  if pv.name.isUrl:
    for r in result.mitems:
      # Always set URL for URL-based packages to ensure subdirectories have correct URL
      r.url = pv.name

proc downloadMinimalPackageAsync*(pv: PkgTuple, options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
  ## Async version of downloadMinimalPackage with deduplication.
  ## If multiple calls request the same package concurrently, they share the same download.
  ## Cache key uses canonical package URL (not version) since we download all versions anyway.

  # Get canonical URL to use as cache key (handles both short names and full URLs)
  var cacheKey: string
  try:
    if pv.name.isFileURL or pv.name == "" or (pv.isNim and not options.disableNimBinaries):
      # For special cases, use the name as-is
      cacheKey = pv.name
    elif pv.name.isUrl:
      # For direct URLs (including subdirectories), use the URL as-is
      # Don't normalize because subdirectories must be treated as separate packages
      cacheKey = pv.name
    else:
      # For package names, resolve to canonical URL for proper deduplication
      try:
        let dlInfo = getPackageDownloadInfo(pv, options, doPrompt = false)
        cacheKey = dlInfo.url
      except:
        # If resolution fails, fall back to using name
        cacheKey = pv.name
  except:
    # If any check fails, use name as-is
    cacheKey = pv.name

  # Check if download is already in progress
  if downloadCache.hasKey(cacheKey):
    # Wait for the existing download to complete and reuse all versions
    return await downloadCache[cacheKey]

  # Start new download and cache the future
  let downloadFuture = downloadMinimalPackageAsyncImpl(pv, options, nimBin)
  downloadCache[cacheKey] = downloadFuture

  try:
    result = await downloadFuture
  finally:
    # Remove from cache after completion (success or failure)
    downloadCache.del(cacheKey)

proc fillPackageTableFromPreferred*(packages: var Table[string, PackageVersions], preferredPackages: seq[PackageMinimalInfo]) =
  for pkg in preferredPackages:
    if not hasVersion(packages, pkg.name, pkg.version):
      if not packages.hasKey(pkg.name):
        packages[pkg.name] = PackageVersions(pkgName: pkg.name, versions: @[pkg])
      else:
        packages[pkg.name].versions.add pkg

proc getInstalledMinimalPackages*(options: Options): seq[PackageMinimalInfo] =
  getInstalledPkgsMin(options.getPkgsDir(), options).mapIt(it.getMinimalInfo(options))

proc getMinimalFromPreferred(pv: PkgTuple,  getMinimalPackage: GetPackageMinimal, preferredPackages: seq[PackageMinimalInfo], options: Options, nimBin: Option[string]): seq[PackageMinimalInfo] =
  # Check if we have a preferred package first
  for pp in preferredPackages:
    if (pp.name == pv.name or pp.url == pv.name) and pp.version.withinRange(pv.ver):
      result.add pp
  
  # Try to download all versions to give the SAT solver full choice
  try:
    let downloaded = getMinimalPackage(pv, options, nimBin)
    for pkg in downloaded:
      result.addUnique pkg
  except CatchableError:
    # If download fails but we have preferred packages, use those
    if result.len == 0:
      raise

proc getMinimalFromPreferredAsync*(pv: PkgTuple, getMinimalPackage: GetPackageMinimalAsync, preferredPackages: seq[PackageMinimalInfo], options: Options, nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
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

proc processRequirements(versions: var Table[string, PackageVersions], pv: PkgTuple, visited: var HashSet[PkgTuple], getMinimalPackage: GetPackageMinimal, preferredPackages: seq[PackageMinimalInfo] = newSeq[PackageMinimalInfo](), options: Options, nimBin: Option[string]) =
  if pv in visited:
    return

  visited.incl pv

  # For special versions, always process them even if we think we have the package
  # This ensures the special version gets downloaded and added to the version table
  try:
    if pv.ver.kind == verSpecial or not hasVersion(versions, pv):
      var pkgMins = getMinimalFromPreferred(pv, getMinimalPackage, preferredPackages, options, nimBin)

      # First, validate all requirements for all package versions before adding anything
      var validPkgMins: seq[PackageMinimalInfo] = @[]
      for pkgMin in pkgMins:
        var allRequirementsValid = true
        # Test if all requirements can be processed without errors
        for req in pkgMin.requires:
          try:
            # Try to get minimal package info for the requirement to validate it exists
            discard getMinimalFromPreferred(req, getMinimalPackage, preferredPackages, options, nimBin)
          except NimbleError:
            # Skip packages with invalid/unresolvable dependencies
            # This can happen for packages with URLs that can't be identified,
            # repos that no longer exist, etc.
            allRequirementsValid = false
            displayWarning(&"Skipping package {pkgMin.name}@{pkgMin.version} due to invalid dependency: {req.name}", HighPriority)
            break

        if allRequirementsValid:
          validPkgMins.add pkgMin

      # Only add packages with valid requirements to the versions table
      for pkgMin in validPkgMins.mitems:
        let pkgName = pkgMin.name.toLower
        if pv.ver.kind == verSpecial:
          # Keep both the commit hash and the actual semantic version
          # If pkgMin.version already has speSemanticVersion set (e.g., from downloadMinimalPackage
          # for nim special versions), preserve it. Otherwise, use the version string.
          if pkgMin.version.speSemanticVersion.isSome:
            # Already has semantic version set (e.g., nim#devel with version extracted from compilation.nim)
            discard
          else:
            var specialVer = newVersion($pv.ver)
            specialVer.speSemanticVersion = some($pkgMin.version)  # Store the real version
            pkgMin.version = specialVer

          # Add special version alongside existing versions - let the SAT solver choose
          # The cmp function places special versions first so they get set FALSE first,
          # meaning the SAT solver will prefer regular tagged versions over #head
          if pkgName notin versions:
            versions[pkgName] = PackageVersions(pkgName: pkgName, versions: @[pkgMin])
          else:
            versions[pkgName].versions.addUnique pkgMin
        else:
          # Regular versions: add alongside existing versions
          if pkgName notin versions:
            versions[pkgName] = PackageVersions(pkgName: pkgName, versions: @[pkgMin])
          else:
            versions[pkgName].versions.addUnique pkgMin

        # Expand any globally active features into this package's requires
        expandActiveFeatures(pkgMin, versions)
        # Now recursively process the requirements (we know they're valid)
        for req in pkgMin.requires:
          processRequirements(versions, req, visited, getMinimalPackage, preferredPackages, options, nimBin)
      
      # Only add URL packages if we have valid versions
      if pv.name.isUrl and validPkgMins.len > 0:
        versions[pv.name] = PackageVersions(pkgName: pv.name, versions: validPkgMins)
        
    else:
      # Package already has a matching version in the table (e.g. from pkgcache),
      # but we still need to recursively process its requirements to ensure
      # transitive dependencies are discovered.
      let pkgName = pv.name.toLower
      if pkgName in versions:
        for pkgMin in versions[pkgName].versions:
          if pkgMin.version.withinRange(pv.ver):
            for req in pkgMin.requires:
              processRequirements(versions, req, visited, getMinimalPackage, preferredPackages, options, nimBin)
  except CatchableError as e:
    # In offline mode, fail immediately - don't try to recover
    if options.offline:
      raise
    # Some old packages may have invalid requirements (i.e repos that doesn't exist anymore)
    # we need to avoid adding it to the package table as this will cause the solver to fail
    displayWarning(&"Error processing requirements for {pv.name}: {e.msg}", HighPriority)

proc processRequirementsAsync*(pv: PkgTuple, visitedParam: HashSet[PkgTuple], getMinimalPackage: GetPackageMinimalAsync, preferredPackages: seq[PackageMinimalInfo] = newSeq[PackageMinimalInfo](), options: Options, nimBin: Option[string]): Future[Table[string, PackageVersions]] {.async.} =
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
    var pkgMins = await getMinimalFromPreferredAsync(pv, getMinimalPackage, preferredPackages, options, nimBin)

    # Expand any globally active features into package requires
    for pkgMin in pkgMins.mitems:
      expandActiveFeatures(pkgMin, result)

    # Collect all unique requirements from all package versions first
    var allRequirements: seq[PkgTuple] = @[]
    for pkgMin in pkgMins:
      for req in pkgMin.requires:
        var found = false
        for existing in allRequirements:
          if existing.name == req.name:
            found = true
            break
        if not found:
          allRequirements.add req

    # Process all unique requirements in parallel FIRST (before adding to result)
    # This way we discover invalid dependencies before committing
    var reqFutures: seq[Future[Table[string, PackageVersions]]] = @[]
    var reqNames: seq[string] = @[]
    for req in allRequirements:
      reqFutures.add processRequirementsAsync(req, visited, getMinimalPackage, preferredPackages, options, nimBin)
      reqNames.add req.name

    # Wait for all requirement processing to complete
    if reqFutures.len > 0:
      await allFutures(reqFutures)

    # Check which requirements failed and collect successful results
    var failedReqs: seq[string] = @[]
    var reqResults: seq[Table[string, PackageVersions]] = @[]
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
          result[pkgName].versions.addUnique pkgMin
      else:
        if pkgName notin result:
          result[pkgName] = PackageVersions(pkgName: pkgName, versions: @[pkgMin])
        else:
          result[pkgName].versions.addUnique pkgMin

    # Merge all successful requirement results
    for reqResult in reqResults:
      for pkgName, pkgVersions in reqResult:
        if not result.hasKey(pkgName):
          result[pkgName] = pkgVersions
        else:
          for ver in pkgVersions.versions:
            result[pkgName].versions.addUnique ver

    # Only add URL packages if we have valid versions
    if pv.name.isUrl and validPkgMins.len > 0:
      result[pv.name] = PackageVersions(pkgName: pv.name, versions: validPkgMins)

  except CatchableError as e:
    # Some old packages may have invalid requirements (i.e repos that doesn't exist anymore)
    # we need to avoid adding it to the package table as this will cause the solver to fail
    displayWarning(&"Error processing requirements for {pv.name}: {e.msg}", HighPriority)

proc collectAllVersions*(versions: var Table[string, PackageVersions], package: PackageMinimalInfo, options: Options, getMinimalPackage: GetPackageMinimal, preferredPackages: seq[PackageMinimalInfo] = newSeq[PackageMinimalInfo](), nimBin: Option[string]) =
  var visited = initHashSet[PkgTuple]()
  for pv in package.requires:
    processRequirements(versions, pv, visited, getMinimalPackage, preferredPackages, options, nimBin)

proc mergeVersionTables(dest: var Table[string, PackageVersions], source: Table[string, PackageVersions]) =
  ## Helper proc to merge version tables. Synchronous to avoid closure capture issues.
  ## All versions (including special versions) are added alongside existing versions.
  ## The SAT solver will choose the best version based on the cmp function.
  for pkgName, pkgVersions in source:
    if pkgName notin dest:
      dest[pkgName] = pkgVersions
    else:
      for ver in pkgVersions.versions:
        dest[pkgName].versions.addUnique ver

proc collectAllVersionsAsync*(package: PackageMinimalInfo, options: Options, getMinimalPackage: GetPackageMinimalAsync, preferredPackages: seq[PackageMinimalInfo] = newSeq[PackageMinimalInfo](), nimBin: Option[string]): Future[Table[string, PackageVersions]] {.async.} =
  ## Async version of collectAllVersions that processes top-level dependencies in parallel.
  ## Uses return-based approach: each branch returns its computed versions, then we merge them.
  ## This allows for safe parallel execution with no shared mutable state during processing.
  ## Returns the merged version table instead of mutating a parameter.

  # Process all top-level requirements in parallel
  # Each gets its own visited set to avoid race conditions
  var futures: seq[Future[Table[string, PackageVersions]]] = @[]
  for pv in package.requires:
    var visitedCopy = initHashSet[PkgTuple]()
    futures.add processRequirementsAsync(pv, visitedCopy, getMinimalPackage, preferredPackages, options, nimBin)

  # Wait for all to complete
  await allFutures(futures)

  # Merge all results into a new table
  result = initTable[string, PackageVersions]()
  for fut in futures:
    let resultTable = fut.read()
    mergeVersionTables(result, resultTable)
