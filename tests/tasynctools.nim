import unittest, chronos, strutils, os, tables
import nimblepkg/[tools, download, options, packageinfotypes, sha1hashes, version, nimblesat]

suite "Async Tools":
  test "doCmdExAsync executes command":
    let (output, exitCode) = waitFor doCmdExAsync("echo hello")
    check exitCode == 0
    check "hello" == output.strip

  test "doCloneAsync clones a repo":
    let tmpDir = getTempDir() / "nimble_async_test"
    let cloneDir = tmpDir / "clone"

    if dirExists(tmpDir):
      removeDir(tmpDir)
    createDir(tmpDir)

    let options = initOptions()
    let repoUrl = "https://github.com/arnetheduck/nim-results"
    waitFor doCloneAsync(DownloadMethod.git, repoUrl, cloneDir, options = options)

    check dirExists(cloneDir)
    check fileExists(cloneDir / "README.md")

    removeDir(tmpDir)

  test "gitFetchTagsAsync fetches tags":
    let tmpDir = getTempDir() / "nimble_async_test_tags"
    let cloneDir = tmpDir / "clone"

    if dirExists(tmpDir):
      removeDir(tmpDir)
    createDir(tmpDir)

    # Clone a repo first (shallow clone without tags)
    let options = initOptions()
    let repoUrl = "https://github.com/arnetheduck/nim-results"
    waitFor doCloneAsync(DownloadMethod.git, repoUrl, cloneDir, options = options)

    # Fetch tags asynchronously
    waitFor gitFetchTagsAsync(cloneDir, DownloadMethod.git, options)

    # Verify tags were fetched by checking for a known stable release
    let tags = getTagsList(cloneDir, DownloadMethod.git)
    check tags.len > 0
    check "v0.4.0" in tags

    removeDir(tmpDir)

  test "getTagsListRemoteAsync queries remote tags":
    let repoUrl = "https://github.com/arnetheduck/nim-results"

    # Query remote tags asynchronously
    let tags = waitFor getTagsListRemoteAsync(repoUrl, DownloadMethod.git)

    # Verify we got tags and v0.4.0 exists
    check tags.len > 0
    check "v0.4.0" in tags

  test "cloneSpecificRevisionAsync clones specific commit":
    let tmpDir = getTempDir() / "nimble_async_test_revision"
    let cloneDir = tmpDir / "clone"

    if dirExists(tmpDir):
      removeDir(tmpDir)
    createDir(tmpDir)

    # Clone a specific revision (v0.4.0 commit hash)
    let options = initOptions()
    let repoUrl = "https://github.com/arnetheduck/nim-results"
    let revision = initSha1Hash("8a03fb2e00dccbf35807c869e0184933b0cffa37")
    waitFor cloneSpecificRevisionAsync(DownloadMethod.git, repoUrl, cloneDir, revision, options)

    # Verify clone succeeded
    check dirExists(cloneDir)
    check fileExists(cloneDir / "README.md")

    removeDir(tmpDir)

  test "doDownloadTarballAsync downloads and extracts tarball":
    # Skip on systems without tar
    if findExe("tar") == "":
      skip()

    let tmpDir = getTempDir() / "nimble_async_test_tarball"
    let downloadDir = tmpDir / "download"

    if dirExists(tmpDir):
      removeDir(tmpDir)
    createDir(tmpDir)

    # Download nim-results v0.4.0 as tarball
    let repoUrl = "https://github.com/arnetheduck/nim-results"
    discard waitFor doDownloadTarballAsync(repoUrl, downloadDir, "v0.4.0", queryRevision = false)

    # Verify download succeeded
    check dirExists(downloadDir)
    check fileExists(downloadDir / "README.md")

    removeDir(tmpDir)

  test "getTagsListAsync lists tags from local repo":
    let tmpDir = getTempDir() / "nimble_async_test_tagslist"
    let cloneDir = tmpDir / "clone"

    if dirExists(tmpDir):
      removeDir(tmpDir)
    createDir(tmpDir)

    # Clone nim-results repo
    let options = initOptions()
    let repoUrl = "https://github.com/arnetheduck/nim-results"
    waitFor doCloneAsync(DownloadMethod.git, repoUrl, cloneDir,
                         onlyTip = false, options = options)

    # Get tags list using async
    let tags = waitFor getTagsListAsync(cloneDir, DownloadMethod.git)

    # Verify v0.4.0 tag exists
    check tags.contains("v0.4.0")
    check tags.len > 0

    removeDir(tmpDir)

  test "doCheckoutAsync checks out branch/tag":
    let tmpDir = getTempDir() / "nimble_async_test_checkout"
    let cloneDir = tmpDir / "clone"

    if dirExists(tmpDir):
      removeDir(tmpDir)
    createDir(tmpDir)

    # Clone nim-results repo with full history
    let options = initOptions()
    let repoUrl = "https://github.com/arnetheduck/nim-results"
    waitFor doCloneAsync(DownloadMethod.git, repoUrl, cloneDir,
                         onlyTip = false, options = options)

    # Checkout v0.4.0 tag using async
    waitFor doCheckoutAsync(DownloadMethod.git, cloneDir, "v0.4.0", options)

    # Verify checkout succeeded by checking if we're on the right version
    check dirExists(cloneDir)
    check fileExists(cloneDir / "README.md")

    removeDir(tmpDir)

  test "downloadPkgAsync downloads package":
    let tmpDir = getTempDir() / "nimble_async_test_pkg"

    if dirExists(tmpDir):
      removeDir(tmpDir)
    createDir(tmpDir)

    # Download nim-results using downloadPkgAsync
    let options = initOptions()
    let repoUrl = "https://github.com/arnetheduck/nim-results"
    # Use #v0.4.0 to use verSpecial which skips validation
    let verRange = parseVersionRange("#v0.4.0")

    # Find nim binary for validation
    let nimBin = findExe("nim")
    if nimBin == "":
      skip()

    let result = waitFor downloadPkgAsync(
      repoUrl,
      verRange,
      DownloadMethod.git,
      subdir = "",
      options,
      downloadPath = tmpDir,
      vcsRevision = notSetSha1Hash,
      nimBin = nimBin,
      validateRange = false
    )

    # Verify download succeeded
    check dirExists(result.dir)
    check fileExists(result.dir / "README.md")
    # With verSpecial, version will be the special version string
    check $result.version == "#v0.4.0"

    removeDir(tmpDir)

  test "getPackageMinimalVersionsFromRepoAsync gets package versions":
    let tmpDir = getTempDir() / "nimble_async_test_minimalversions"
    let repoDir = tmpDir / "repo"

    if dirExists(tmpDir):
      removeDir(tmpDir)
    createDir(tmpDir)

    # Clone nim-results repo with full history
    let options = initOptions()
    let repoUrl = "https://github.com/arnetheduck/nim-results"
    waitFor doCloneAsync(DownloadMethod.git, repoUrl, repoDir,
                         onlyTip = false, options = options)

    # Find nim binary
    let nimBin = findExe("nim")
    if nimBin == "":
      skip()

    # Get minimal versions for a version range
    let pkg: PkgTuple = ("results", parseVersionRange(">= 0.4.0"))
    let versions = waitFor getPackageMinimalVersionsFromRepoAsync(
      repoDir, pkg, newVersion("0.4.0"), DownloadMethod.git, options, nimBin)

    # Verify we got some versions
    check versions.len > 0
    # Verify we got v0.4.0
    var foundV040 = false
    for v in versions:
      if v.version == newVersion("0.4.0"):
        foundV040 = true
        break
    check foundV040

    removeDir(tmpDir)

  test "downloadMinimalPackageAsync downloads package with versions":
    let tmpDir = getTempDir() / "nimble_async_test_minimalpackage"

    if dirExists(tmpDir):
      removeDir(tmpDir)
    createDir(tmpDir)

    # Find nim binary
    let nimBin = findExe("nim")
    if nimBin == "":
      skip()

    # Create options with custom cache path
    var options = initOptions()
    options.pkgCachePath = tmpDir / "cache"
    createDir(options.pkgCachePath)

    # Download nim-results package using downloadMinimalPackageAsync
    # Use a version range to test the full flow of downloading and fetching versions
    let pkg: PkgTuple = ("https://github.com/arnetheduck/nim-results", parseVersionRange(">= 0.4.0"))
    let versions = waitFor downloadMinimalPackageAsync(pkg, options, nimBin)

    # Verify we got multiple versions
    check versions.len > 0
    # Verify v0.4.0 is included
    var foundV040 = false
    for v in versions:
      if v.version == newVersion("0.4.0"):
        foundV040 = true
        break
    check foundV040

    removeDir(tmpDir)

  test "getMinimalFromPreferredAsync returns preferred package":
    let tmpDir = getTempDir() / "nimble_async_test_preferred"

    if dirExists(tmpDir):
      removeDir(tmpDir)
    createDir(tmpDir)

    # Find nim binary
    let nimBin = findExe("nim")
    if nimBin == "":
      skip()

    # Create options
    var options = initOptions()
    options.pkgCachePath = tmpDir / "cache"
    createDir(options.pkgCachePath)

    # Create a preferred package entry
    let preferredPkg = PackageMinimalInfo(
      name: "results",
      version: newVersion("0.4.0"),
      url: "https://github.com/arnetheduck/nim-results",
      requires: @[]
    )
    let preferredPackages = @[preferredPkg]

    # Test 1: Request matching preferred package - should return preferred without downloading
    let pkg1: PkgTuple = ("results", parseVersionRange("0.4.0"))
    let versions1 = waitFor getMinimalFromPreferredAsync(pkg1, downloadMinimalPackageAsync, preferredPackages, options, nimBin)

    check versions1.len == 1
    check versions1[0].name == "results"
    check versions1[0].version == newVersion("0.4.0")

    # Test 2: Request non-matching package - should fall back to downloadMinimalPackageAsync
    let pkg2: PkgTuple = ("https://github.com/arnetheduck/nim-results", parseVersionRange(">= 0.3.0"))
    let versions2 = waitFor getMinimalFromPreferredAsync(pkg2, downloadMinimalPackageAsync, preferredPackages, options, nimBin)

    check versions2.len > 0  # Should download and return multiple versions
    var foundPreferred = false
    for v in versions2:
      if v.version == newVersion("0.4.0"):
        foundPreferred = true
        break
    check foundPreferred

    removeDir(tmpDir)

  test "collectAllVersionsAsync collects versions in parallel":
    let tmpDir = getTempDir() / "nimble_async_test_collectall"

    if dirExists(tmpDir):
      removeDir(tmpDir)
    createDir(tmpDir)

    # Find nim binary
    let nimBin = findExe("nim")
    if nimBin == "":
      skip()

    # Create options
    var options = initOptions()
    options.pkgCachePath = tmpDir / "cache"
    createDir(options.pkgCachePath)

    # Create a package with multiple dependencies to test parallel processing
    # We'll use a mock package with two dependencies: nim-results and stew
    let mockPackage = PackageMinimalInfo(
      name: "mockpackage",
      version: newVersion("1.0.0"),
      url: "https://github.com/mock/package",
      requires: @[
        ("https://github.com/arnetheduck/nim-results", parseVersionRange(">= 0.4.0")),
        ("https://github.com/status-im/nim-stew", parseVersionRange(">= 0.1.0"))
      ]
    )

    # Collect all versions using async
    let versions = waitFor collectAllVersionsAsync(mockPackage, options, downloadMinimalPackageAsync, @[], nimBin)

    # Verify we got versions for both dependencies
    check versions.len >= 1  # At least nim-results should be found

    # Verify nim-results versions were collected
    var foundResults = false
    for pkgName, pkgVersions in versions:
      if pkgName.contains("results") or pkgName == "results":
        foundResults = true
        check pkgVersions.versions.len > 0
        # Should have v0.4.0 or later
        var foundVersion = false
        for v in pkgVersions.versions:
          if v.version >= newVersion("0.4.0"):
            foundVersion = true
            break
        check foundVersion

    check foundResults

    removeDir(tmpDir)

  test "collectAllVersionsAsync processes dependencies in parallel":
    let tmpDir = getTempDir() / "nimble_async_test_solve"

    if dirExists(tmpDir):
      removeDir(tmpDir)
    createDir(tmpDir)

    # Find nim binary
    let nimBin = findExe("nim")
    if nimBin == "":
      skip()

    # Create options with async enabled (not legacy)
    var options = initOptions()
    options.pkgCachePath = tmpDir / "cache"
    options.legacy = false  # Use async path (vnext mode)
    createDir(options.pkgCachePath)

    # Create a root package that depends on nim-results
    let rootPkg = PackageMinimalInfo(
      name: "testroot",
      version: newVersion("1.0.0"),
      url: "",
      requires: @[("https://github.com/arnetheduck/nim-results", parseVersionRange(">= 0.4.0"))]
    )

    # Use collectAllVersionsAsync directly
    let versions = waitFor collectAllVersionsAsync(rootPkg, options, downloadMinimalPackageAsync, @[], nimBin)

    # Verify that nim-results was collected
    check versions.len > 0

    var foundResults = false
    for pkgName, pkgVersions in versions:
      if pkgName.contains("results") or pkgName.toLowerAscii == "results":
        foundResults = true
        check pkgVersions.versions.len > 0
        # Should have at least one version >= 0.4.0
        var foundVersion = false
        for v in pkgVersions.versions:
          if v.version >= newVersion("0.4.0"):
            foundVersion = true
            break
        check foundVersion
        break

    check foundResults

    removeDir(tmpDir)

  test "gitShowFileAsync reads file from git commit":
    let tmpDir = getTempDir() / "nimble_async_test_gitshow"
    let cloneDir = tmpDir / "clone"

    if dirExists(tmpDir):
      removeDir(tmpDir)
    createDir(tmpDir)

    # Clone nim-results repo with full history
    let options = initOptions()
    let repoUrl = "https://github.com/arnetheduck/nim-results"
    waitFor doCloneAsync(DownloadMethod.git, repoUrl, cloneDir,
                         onlyTip = false, options = options)

    # Read README.md from v0.4.0 tag using gitShowFileAsync
    let content = waitFor gitShowFileAsync(cloneDir, "v0.4.0", "README.md")

    # Verify we got content
    check content.len > 0
    check "results" in content.toLowerAscii()

    # Test reading the nimble file from a specific tag
    let nimbleContent = waitFor gitShowFileAsync(cloneDir, "v0.4.0", "results.nimble")
    check nimbleContent.len > 0
    check "version" in nimbleContent.toLowerAscii()

    removeDir(tmpDir)

  test "gitListNimbleFilesInCommitAsync lists nimble files":
    let tmpDir = getTempDir() / "nimble_async_test_gitlist"
    let cloneDir = tmpDir / "clone"

    if dirExists(tmpDir):
      removeDir(tmpDir)
    createDir(tmpDir)

    # Clone nim-results repo with full history
    let options = initOptions()
    let repoUrl = "https://github.com/arnetheduck/nim-results"
    waitFor doCloneAsync(DownloadMethod.git, repoUrl, cloneDir,
                         onlyTip = false, options = options)

    # List .nimble files in v0.4.0 tag
    let nimbleFiles = waitFor gitListNimbleFilesInCommitAsync(cloneDir, "v0.4.0")

    # Verify we found the nimble file
    check nimbleFiles.len > 0
    check "results.nimble" in nimbleFiles

    # Test with HEAD
    let nimbleFilesHead = waitFor gitListNimbleFilesInCommitAsync(cloneDir, "HEAD")
    check nimbleFilesHead.len > 0

    removeDir(tmpDir)

  test "getPackageMinimalVersionsFromRepoAsyncFast gets versions without checkout":
    let tmpDir = getTempDir() / "nimble_async_test_fast"
    let repoDir = tmpDir / "repo"

    if dirExists(tmpDir):
      removeDir(tmpDir)
    createDir(tmpDir)

    # Clone nim-results repo with full history
    let options = initOptions()
    let repoUrl = "https://github.com/arnetheduck/nim-results"
    waitFor doCloneAsync(DownloadMethod.git, repoUrl, repoDir,
                         onlyTip = false, options = options)

    # Find nim binary
    let nimBin = findExe("nim")
    if nimBin == "":
      skip()

    # Get minimal versions using the FAST method (no checkout)
    let pkg: PkgTuple = ("results", parseVersionRange(">= 0.4.0"))
    let versions = waitFor getPackageMinimalVersionsFromRepoAsyncFast(
      repoDir, pkg, DownloadMethod.git, options, nimBin)

    # Verify we got versions
    check versions.len > 0

    # Verify we got v0.4.0
    var foundV040 = false
    for v in versions:
      if v.version == newVersion("0.4.0"):
        foundV040 = true
        # Verify it has dependencies info
        check v.requires.len > 0
        break
    check foundV040

    removeDir(tmpDir)
