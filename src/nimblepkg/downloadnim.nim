import std/[strutils, terminal, times, uri, sequtils, options, jsonutils]
import compat/[json, osproc, os]

import chronos
import chronos/apps/http/[httpclient, httpcommon]

import zippy/tarballs as zippy_tarballs
import zippy/ziparchives as zippy_zips

import common, options, packageinfo, nimenv, download, packagemetadatafile

when defined(curl):
  import math

import version, cli
when defined(curl):
  import libcurl except Version

# import cliparams, common, utils
# import telemetry
proc getBinArchiveFormat*(): string =
  when defined(windows):
    return ".zip"
  else:
    return ".tar.xz"

proc getCpuArch*(): int =
  ## Get CPU arch on Windows - get env var PROCESSOR_ARCHITECTURE
  var failMsg = ""

  let
    archEnv = getEnv("PROCESSOR_ARCHITECTURE")
    arch6432Env = getEnv("PROCESSOR_ARCHITEW6432")
  if arch6432Env.len != 0:
    # https://blog.differentpla.net/blog/2013/03/10/processor-architew6432/
    result = 64
  elif "64" in archEnv:
    # https://superuser.com/a/1441469
    result = 64
  elif "86" in archEnv:
    result = 32
  else:
    failMsg =
      "PROCESSOR_ARCHITECTURE = " & archEnv & ", PROCESSOR_ARCHITEW6432 = " & arch6432Env

  # Die if unsupported - better fail than guess
  if result == 0:
    raise newException(NimbleError, "Could not detect CPU architecture: " & failMsg)

proc getNimBinariesDir*(options: Options): string =
  return options.nimBinariesDir

proc getMingwPath*(options: Options): string =
  let arch = getCpuArch()
  return getNimBinariesDir(options) / "mingw" & $arch

proc getMingwBin*(options: Options): string =
  return getMingwPath(options) / "bin"

proc isDefaultCCInPath*(): bool =
  # Fixes issue #104
  when defined(macosx):
    return findExe("clang") != ""
  else:
    return findExe("gcc") != ""

proc getGccArch*(options: Options): int =
  ## Get gcc arch by getting pointer size x 8
  var
    outp = ""
    errC = 0

  when defined(windows):
    # Add MingW bin dir to PATH so getGccArch can find gcc.
    let pathEnv = getEnv("PATH")
    if not isDefaultCCInPath() and dirExists(options.getMingwBin()):
      putEnv("PATH", options.getMingwBin() & PathSep & pathEnv)

    (outp, errC) = execCmdEx(
      "cmd /c echo int main^(^) { return sizeof^(void *^); } | gcc -xc - -o archtest && archtest"
    )

    putEnv("PATH", pathEnv)
  else:
    (outp, errC) = execCmdEx(
      "echo \"int main() { return sizeof(void *); }\" | gcc -xc - -o archtest && ./archtest"
    )

  removeFile("archtest".addFileExt(ExeExt))

  if errC in [4, 8]:
    return errC * 8
  else:
    # Fallback when arch detection fails. See https://github.com/dom96/choosenim/issues/284
    return when defined(windows): 32 else: 64

proc isRosetta*(): bool =
  try:
    let res = execCmdEx("sysctl -in sysctl.proc_translated")
    if res.exitCode == 0:
      return res.output.strip() == "1"
  except CatchableError:
    return false

proc isAppleSilicon*(): bool =
  when defined(macosx):
    try:
      let res = execCmdEx("uname -m")
      if res.exitCode == 0:
        return res.output.strip() == "arm64"
    except CatchableError:
      return false

proc getPlatformString*(arch: int): string =
  ## Returns the platform string used in releases.json (e.g., "linux_x64", "macosx_arm64")
  let os =
    when defined(windows):
      "windows"
    elif defined(linux):
      "linux"
    elif defined(macosx):
      "macosx"
    else:
      # For other platforms, fall back to source
      "source_tar"

  when defined(macosx):
    if isAppleSilicon():
      return os & "_arm64"
    else:
      return os & "_x64"
  else:
    # For Windows and Linux
    return os & "_x" & $arch

proc getNightliesUrl*(parsedContents: JsonNode, arch: int): (string, string) =
  let os =
    when defined(windows):
      "windows"
    elif defined(linux):
      "linux"
    elif defined(macosx):
      "osx"
    elif defined(freebsd):
      "freebsd"
    elif defined(openbsd):
      "openbsd"
    elif defined(haiku):
      "haiku"
  for jn in parsedContents.getElems():
    if jn["name"].getStr().contains("devel"):
      let tagName = jn{"tag_name"}.getStr("")
      for asset in jn["assets"].getElems():
        let aname = asset["name"].getStr()
        let url = asset{"browser_download_url"}.getStr("")
        if os in aname:
          when not defined(macosx):
            if "x" & $arch in aname:
              result = (url, tagName)
          else:
            if not isAppleSilicon():
              result = (url, tagName)
        if result[0].len != 0:
          break
    if result[0].len != 0:
      break

proc getLatestCommit*(repo, branch: string): string =
  ## Get latest commit for remote Git repo with ls-remote
  ##
  ## Returns "" if Git isn't available
  let git = findExe("git")
  if git.len != 0:
    var cmd = when defined(windows): "cmd /c " else: ""
    cmd &= git.quoteShell & " ls-remote " & repo & " " & branch

    let (outp, errC) = execCmdEx(cmd)
    if errC == 0:
      for line in outp.splitLines():
        result = line.split('\t')[0]
        break
    else:
      display("Warning", outp & "\ngit ls-remote failed", Warning, HighPriority)

proc doCmdRaw*(cmd: string) =
  var command = cmd
  # To keep output in sequence
  stdout.flushFile()
  stderr.flushFile()

  if defined(macosx) and isRosetta():
    command = "arch -arm64 " & command

  displayDebug("Executing", command)
  displayDebug("Work Dir", getCurrentDir())
  let (output, exitCode) = execCmdEx(command)
  displayDebug("Finished", "with exit code " & $exitCode)
  displayDebug("Output", output)

  if exitCode != QuitSuccess:
    raise newException(
      NimbleError,
      "Execution failed with exit code $1\nCommand: $2\nOutput: $3" %
        [$exitCode, command, output],
    )

const
  releasesJsonUrl = "https://nim-lang.org/releases.json"
  githubNightliesReleasesUrl =
    "https://api.github.com/repos/nim-lang/nightlies/releases"
  githubUrl = "https://github.com/nim-lang/Nim"
  websiteUrlXz = "https://nim-lang.org/download/nim-$1.tar.xz"
  websiteUrlGz = "https://nim-lang.org/download/nim-$1.tar.gz"
  csourcesUrl = "https://github.com/nim-lang/csources"
  dlArchive = "archive/$1.tar.gz"

const # Windows-only
  mingwUrl = "https://nim-lang.org/download/mingw$1.zip"

const progressBarLength = 50

proc showIndeterminateBar(progress, speed: BiggestInt, lastPos: var int) =
  try:
    eraseLine()
  except OSError:
    echo ""
  if lastPos >= progressBarLength:
    lastPos = 0

  var spaces = repeat(' ', progressBarLength)
  spaces[lastPos] = '#'
  lastPos.inc()
  stdout.write(
    "[$1] $2mb $3kb/s" % [spaces, $(progress div (1000 * 1000)), $(speed div 1000)]
  )
  stdout.flushFile()

proc showBar(fraction: float, speed: BiggestInt) =
  try:
    eraseLine()
  except OSError:
    echo ""
  let hashes = repeat('#', int(fraction * progressBarLength))
  let spaces = repeat(' ', progressBarLength - hashes.len)
  stdout.write(
    "[$1$2] $3% $4kb/s" %
      [hashes, spaces, formatFloat(fraction * 100, precision = 4), $(speed div 1000)]
  )
  stdout.flushFile()

when defined(curl):
  proc checkCurl(code: Code) =
    if code != E_OK:
      raise newException(AssertionError, "CURL failed: " & $easy_strerror(code))

  proc downloadFileCurl(url, outputPath: string) =
    displayDebug("Downloading using Curl")
    # Based on: https://curl.haxx.se/libcurl/c/url2file.html
    let curl = libcurl.easy_init()
    defer:
      curl.easy_cleanup()

    # Enable progress bar.
    #checkCurl curl.easy_setopt(OPT_VERBOSE, 1)
    checkCurl curl.easy_setopt(OPT_NOPROGRESS, 0)

    # Set which URL to download and tell curl to follow redirects.
    checkCurl curl.easy_setopt(OPT_URL, url)
    checkCurl curl.easy_setopt(OPT_FOLLOWLOCATION, 1)

    type UserData = ref object
      file: File
      lastProgressPos: int
      bytesWritten: int
      lastSpeedUpdate: float
      speed: BiggestInt
      needsUpdate: bool

    # Set up progress callback.
    proc onProgress(userData: pointer, dltotal, dlnow, ultotal, ulnow: float): cint =
      result = 0 # Ensure download isn't terminated.

      let userData = cast[UserData](userData)

      # Only update once per second.
      if userData.needsUpdate:
        userData.needsUpdate = false
      else:
        return

      let fraction = dlnow.float / dltotal.float
      if fraction.classify == fcNan:
        return

      if fraction == Inf:
        showIndeterminateBar(dlnow.BiggestInt, userData.speed, userData.lastProgressPos)
      else:
        showBar(fraction, userData.speed)

    checkCurl curl.easy_setopt(OPT_PROGRESSFUNCTION, onProgress)

    # Set up write callback.
    proc onWrite(data: ptr char, size: cint, nmemb: cint, userData: pointer): cint =
      let userData = cast[UserData](userData)
      let len = size * nmemb
      result = userData.file.writeBuffer(data, len).cint
      doAssert result == len

      # Handle speed measurement.
      const updateInterval = 0.25
      userData.bytesWritten += result
      if epochTime() - userData.lastSpeedUpdate > updateInterval:
        userData.speed = userData.bytesWritten * int(1 / updateInterval)
        userData.bytesWritten = 0
        userData.lastSpeedUpdate = epochTime()
        userData.needsUpdate = true

    checkCurl curl.easy_setopt(OPT_WRITEFUNCTION, onWrite)

    # Open file for writing and set up UserData.
    let userData = UserData(
      file: open(outputPath, fmWrite),
      lastProgressPos: 0,
      lastSpeedUpdate: epochTime(),
      speed: 0,
    )
    defer:
      userData.file.close()
    checkCurl curl.easy_setopt(OPT_WRITEDATA, userData)
    checkCurl curl.easy_setopt(OPT_PROGRESSDATA, userData)

    # Download the file.
    checkCurl curl.easy_perform()

    # Verify the response code.
    var responseCode: int
    checkCurl curl.easy_getinfo(INFO_RESPONSE_CODE, addr responseCode)

    if responseCode != 200:
      raise newException(
        HTTPRequestError, "Expected HTTP code $1 got $2" % [$200, $responseCode]
      )

type
  ProgressTracker = object
    totalRead: int
    lastSpeedUpdate: float
    bytesSinceUpdate: int
    speed: int
    lastPos: int
    hadProgress: bool
    contentLen: uint64

proc tick(tracker: var ProgressTracker) =
  let now = epochTime()
  const updateInterval = 0.25

  if now - tracker.lastSpeedUpdate > updateInterval:
    tracker.speed = (tracker.bytesSinceUpdate.float / (now - tracker.lastSpeedUpdate)).int
    tracker.bytesSinceUpdate = 0
    tracker.lastSpeedUpdate = now

  if tracker.contentLen > 0:
    showBar(tracker.totalRead.float / tracker.contentLen.float, tracker.speed)
  else:
    showIndeterminateBar(tracker.totalRead, tracker.speed, tracker.lastPos)

proc finish(tracker: var ProgressTracker) =
  if tracker.hadProgress:
    showBar(1, 0)
    echo ""

proc downloadFileNim(url, outputPath: string, disableSslCertCheck = false) {.async.} =
  displayDebug("Downloading using Chronos")
  let flags = if disableSslCertCheck:
    {HttpClientFlag.NoVerifyHost, HttpClientFlag.NoVerifyServerName}
  else: {}
  let session = HttpSessionRef.new(flags = flags, provider = getProvider())

  try:
    var request = HttpClientRequestRef.new(
      session, url, headers = {UserAgentHeader: nimbleUserAgent}
    ).valueOr:
      raise newException(HttpRequestError, error)

    var response = await request.sendWithRedirect()
    if response.status >= 400:
      await response.closeWait()
      raise newException(HttpRequestError, "Server returned status: " & $response.status)

    try:
      const bufSize = 65536

      let
        file = open(outputPath, fmWrite)
        reader = response.getBodyReader()

      var tracker = ProgressTracker(
        contentLen: response.contentLength,
        lastSpeedUpdate: epochTime(),
      )

      try:
        var buf = newSeq[byte](bufSize)

        while not reader.atEof:
          let n = await reader.readOnce(addr buf[0], buf.len)

          if n == 0:
            break

          discard file.writeBuffer(addr buf[0], n)

          tracker.totalRead += n
          tracker.bytesSinceUpdate += n
          tracker.hadProgress = true
          tracker.tick()
      finally:
        await reader.closeWait()
        close(file)

      tracker.finish()
    finally:
      await response.closeWait()

  except CatchableError:
    raise newException(HttpRequestError, getCurrentExceptionMsg())
  finally:
    await session.closeWait()

proc downloadFile*(url, outputPath: string, disableSslCertCheck = false) {.async.} =
  # For debugging.
  display("GET:", url, priority = DebugPriority)

  # Create outputPath's directory if it doesn't exist already.
  createDir(outputPath.splitFile.dir)

  # Download to a temporary file
  let tempOutputPath = outputPath & "_temp"
  try:
    await downloadFileNim(url, tempOutputPath, disableSslCertCheck)
  except HttpRequestError as exc:
    echo("") # Skip line with progress bar.
    let msg =
      "Couldn't download file from $1.\nResponse was: $2" %
      [url, getCurrentExceptionMsg()]
    display("Info:", msg, Warning, MediumPriority)
    if tempOutputPath.fileExists: removeFile(tempOutputPath)
    raise exc

  moveFile(tempOutputPath, outputPath)

proc getDownloadPath*(downloadUrl: string, options: Options): string =
  let (_, name, ext) = downloadUrl.splitFile()
  getNimBinariesDir(options) / name & ext

  # report(initTiming(DownloadTime, url, startTime, $LabelSuccess), params)

proc needsDownload(
    downloadUrl: string, outputPath: var string, options: Options
): bool =
  ## Returns whether the download should commence.
  ##
  ## The `outputPath` argument is filled with the valid download path.
  result = true
  outputPath = getDownloadPath(downloadUrl, options)
  if outputPath.fileExists():
    # TODO: Verify sha256.
    display("Info:", "$1 already downloaded" % outputPath, priority = HighPriority)
    return false

proc getBinaryUrlFromReleases*(version: Version, arch: int, disableSslCertCheck = false): Option[string] =
  ## Get the binary download URL for a specific version and platform from releases.json
  ## Returns None if the platform/version combination is not available
  try:
    let rawContents = waitFor retrieveUrl(releasesJsonUrl, disableSslCertCheck)
    let parsedContents = parseJson(rawContents)
    let versionStr = $version

    if not parsedContents.hasKey(versionStr):
      return none(string)

    let versionData = parsedContents[versionStr]
    let platformStr = getPlatformString(arch)

    if not versionData.hasKey(platformStr):
      # Platform not available for this version
      return none(string)

    let platformData = versionData[platformStr]

    # Prefer nimlang_url if available, otherwise use github_url
    if platformData.hasKey("nimlang_url"):
      return some(platformData["nimlang_url"].getStr())
    elif platformData.hasKey("github_url"):
      return some(platformData["github_url"].getStr())

    return none(string)
  except CatchableError:
    return none(string)

proc downloadImpl(version: Version, options: Options): Future[string] {.async.} =
  let arch = getGccArch(options)
  displayDebug("Detected", "arch as " & $arch & "bit")
  if version.isSpecial():
    var reference, url = ""
    if $version in ["#devel", "#head"]: # and not params.latest:
      # Install nightlies by default for devel channel
      try:
        let rawContents = await retrieveUrl(githubNightliesReleasesUrl, options.disableSslCertCheck)
        let parsedContents = parseJson(rawContents)
        (url, reference) = getNightliesUrl(parsedContents, arch)
        if url.len == 0:
          display(
            "Warning",
            "Recent nightly release not found, installing latest devel commit.",
            Warning, HighPriority,
          )
        reference = if reference.len == 0: "devel" else: reference
      except HttpRequestError:
        # Unable to get nightlies release json from github API, fallback
        # to `choosenim devel --latest`
        display(
          "Warning", "Nightlies build unavailable, building latest commit", Warning,
          HighPriority,
        )

    if url.len == 0:
      let
        commit = getLatestCommit(githubUrl, "devel")
        archive = if commit.len != 0: commit else: "devel"
      reference =
        case normalize($version)
        of "#head":
          archive
        else:
          ($version)[1 .. ^1]
      url = $(parseUri(githubUrl) / (dlArchive % reference))
    display(
      "Downloading", "Nim $1 from $2" % [reference, "GitHub"], priority = HighPriority
    )
    var outputPath: string
    if not needsDownload(url, outputPath, options):
      return outputPath

    await downloadFile(url, outputPath, options.disableSslCertCheck)
    result = outputPath
  else:
    display(
      "Downloading",
      "Nim $1 from $2" % [$version, "nim-lang.org"],
      priority = HighPriority,
    )

    var outputPath: string

    # Try to get binary URL from releases.json
    let binaryUrlOpt = getBinaryUrlFromReleases(version, arch, options.disableSslCertCheck)
    if binaryUrlOpt.isSome():
      let binUrl = binaryUrlOpt.get()
      if not needsDownload(binUrl, outputPath, options):
        return outputPath
      try:
        await downloadFile(binUrl, outputPath, options.disableSslCertCheck)
        return outputPath
      except HttpRequestError:
        display(
          "Info:",
          "Binary download failed, falling back to source",
          priority = HighPriority,
        )
    else:
      # Platform/version not available in releases.json
      when defined(macosx):
        display(
          "Info:",
          "Binary build for $1 not available on this platform, building from source" %
            $version,
          priority = HighPriority,
        )
      else:
        display(
          "Info:",
          "Binary build unavailable, building from source",
          priority = HighPriority,
        )

    # Fall back to source tarball
    let hasUnxz = findExe("unxz") != ""
    let url = (if hasUnxz: websiteUrlXz else: websiteUrlGz) % $version
    if not needsDownload(url, outputPath, options):
      return outputPath
    await downloadFile(url, outputPath, options.disableSslCertCheck)
    result = outputPath

proc downloadNim*(version: Version, options: Options): Future[string] {.async.} =
  ## Returns the path of the downloaded .tar.(gz|xz) file.
  try:
    await downloadImpl(version, options)
  except HttpRequestError:
    raise newException(NimbleError, "Version $1 does not exist." % $version)

proc downloadCSources*(options: Options): string =
  let
    commit = getLatestCommit(csourcesUrl, "master")
    archive = if commit.len != 0: commit else: "master"
    csourcesArchiveUrl = $(parseUri(csourcesUrl) / (dlArchive % archive))

  var outputPath: string
  if not needsDownload(csourcesArchiveUrl, outputPath, options):
    return outputPath

  display("Downloading", "Nim C sources from GitHub", priority = HighPriority)
  waitFor downloadFile(csourcesArchiveUrl, outputPath, options.disableSslCertCheck)
  return outputPath

proc downloadMingw*(options: Options): string =
  let
    arch = getCpuArch()
    url = mingwUrl % $arch
  var outputPath: string
  if not needsDownload(url, outputPath, options):
    return outputPath

  display("Downloading", "C compiler (Mingw$1)" % $arch, priority = HighPriority)
  waitFor downloadFile(url, outputPath, options.disableSslCertCheck)
  return outputPath

proc getOfficialReleases*(options: Options): seq[Version] {.raises: [CatchableError].} =
  #Avoid reaching rate limits by caching the releases
  #Later on, this file will be moved to a new global cache file that we are going to
  #introduce when enabling the "enumerate all versions" feature
  let oficialReleasesCachedFile =
    options.nimbleDir.absolutePath() / "official-nim-releases.json"
  if oficialReleasesCachedFile.fileExists():
    if options.offline:
      # In offline mode, use cache regardless of age
      return oficialReleasesCachedFile.parseFile().to(seq[Version])
    #We only store the file for a day.
    let fileCreation = getTime() - getFileInfo(oficialReleasesCachedFile).lastWriteTime
    if fileCreation.inDays <= 1:
      return oficialReleasesCachedFile.parseFile().to(seq[Version])
  if options.offline:
    # No cache available in offline mode - return empty list
    # System nim will be added by getAllNimReleases if available
    return @[]
  var parsedContents: JsonNode
  try:
    let rawContents = waitFor retrieveUrl(releasesJsonUrl, options.disableSslCertCheck)
    parsedContents = parseJson(rawContents)
  except CatchableError:
    display(
      "Warning", "Error getting official releases from nim-lang.org", Warning, HighPriority
    )
    #Fallback list of known releases when the endpoint is unavailable
    return
      @[
        newVersion("2.2.6"),
        newVersion("2.2.4"),
        newVersion("2.2.2"),
        newVersion("2.2.0"),
        newVersion("2.0.16"),
        newVersion("2.0.14"),
        newVersion("2.0.12"),
        newVersion("2.0.10"),
        newVersion("2.0.8"),
        newVersion("2.0.6"),
        newVersion("2.0.4"),
        newVersion("2.0.2"),
        newVersion("2.0.0"),
        newVersion("1.6.20"),
        newVersion("1.6.18"),
        newVersion("1.6.16"),
        newVersion("1.6.14"),
        newVersion("1.6.12"),
        newVersion("1.6.10"),
        newVersion("1.6.8"),
        newVersion("1.6.6"),
        newVersion("1.6.4"),
        newVersion("1.6.2"),
        newVersion("1.6.0"),
        newVersion("1.4.8"),
        newVersion("1.4.6"),
        newVersion("1.4.4"),
        newVersion("1.4.2"),
        newVersion("1.4.0"),
        newVersion("1.2.18"),
        newVersion("1.2.16"),
        newVersion("1.2.14"),
        newVersion("1.2.12"),
        newVersion("1.2.10"),
        newVersion("1.2.8"),
      ]

  # Parse releases.json - it has version numbers as keys
  var releases: seq[Version] = @[]
  for versionKey in parsedContents.keys:
    try:
      let version = newVersion(versionKey)
      releases.add(version)
    except CatchableError:
      # Skip invalid version strings
      discard

  createDir(oficialReleasesCachedFile.parentDir)
  writeFile(oficialReleasesCachedFile, releases.toJson().pretty())
  return releases

template isDevel*(version: Version): bool =
  $version in ["#head", "#devel"]

proc gitUpdate*(version: Version, extractDir: string, options: Options): bool =
  if version.isDevel(): # and options.latest:
    let git = findExe("git")
    if git.len != 0 and fileExists(extractDir / ".git" / "config"):
      result = true

      let lastDir = getCurrentDir()
      setCurrentDir(extractDir)
      defer:
        setCurrentDir(lastDir)

      display("Fetching", "latest changes", priority = HighPriority)
      for cmd in [" fetch --all", " reset --hard origin/devel"]:
        var (outp, errC) = execCmdEx(git.quoteShell & cmd)
        if errC != QuitSuccess:
          display(
            "Warning:",
            "git" & cmd & " failed: " & outp,
            Warning,
            priority = HighPriority,
          )
          return false

proc gitInit*(version: Version, extractDir: string, options: Options) =
  createDir(extractDir / ".git")
  if version.isDevel():
    let git = findExe("git")
    if git.len != 0:
      let lastDir = getCurrentDir()
      setCurrentDir(extractDir)
      defer:
        setCurrentDir(lastDir)

      var init = true
      display("Setting", "up git repository", priority = HighPriority)
      for cmd in [" init", " remote add origin https://github.com/nim-lang/nim"]:
        var (outp, errC) = execCmdEx(git.quoteShell & cmd)
        if errC != QuitSuccess:
          display(
            "Warning:",
            "git" & cmd & " failed: " & outp,
            Warning,
            priority = HighPriority,
          )
          init = false
          break

      if init:
        discard gitUpdate(version, extractDir, options)

proc extract*(path: string, extractDir: string) =
  display("Extracting", path.extractFilename(), priority = HighPriority)

  if path.splitFile().ext == ".xz":
    when defined(windows):
      # We don't ship with `unxz` on Windows, instead assume that we get
      # a .zip on this platform.
      raise newException(
        NimbleError, "Unable to extract. Tar.xz files are not supported on Windows."
      )
    else:
      # NOTE: these checks must stay a runtime `if`, not a `when` `elif`, so that
      # `findExe` resolves on the user's machine rather than being folded at
      # compile time (which also breaks compilation on targets where the VM
      # cannot evaluate `findExe`).
      if findExe("unxz") != "":
        let tarFile = path.changeFileExt("")
        removeFile(tarFile) # just in case it exists, if it does `unxz` fails.
        doCmdRaw("unxz " & quoteShell(path))
        extract(tarFile, extractDir) # We remove the .xz extension
        return
      elif findExe("tar") == "":
        # No `unxz` (not shipped on macOS) and no libarchive-based `tar` to fall
        # back on, so we cannot decompress the .xz at all.
        raise newException(
          NimbleError,
          "Unable to extract. Need `unxz` or a libarchive-based `tar` to extract " &
            ".tar.xz file. See https://github.com/dom96/choosenim/issues/290.",
        )
      # else: `tar` is available (bsdtar/libarchive on macOS, GNU tar with xz on
      # Linux can both read .xz directly), so fall through to the case below.

  let tempDir = getTempDir() / "choosenim-extraction"
  removeDir(tempDir)

  try:
    case path.splitFile.ext
    of ".zip":
      zippy_zips.extractAll(path, tempDir)
    of ".tar", ".gz", ".xz":
      if findExe("tar") != "":
        # TODO: Workaround for high mem usage of zippy (https://github.com/guzba/zippy/issues/31).
        createDir(tempDir)
        doCmdRaw("tar xf " & quoteShell(path) & " -C " & quoteShell(tempDir))
      else:
        zippy_tarballs.extractAll(path, tempDir)
    else:
      raise newException(ValueError, "Unsupported format for extraction: " & path)
  except CatchableError as exc:
    raise newException(NimbleError, "Unable to extract. Error was '$1'." % exc.msg)

  # Skip outer directory.
  # Same as: https://github.com/dom96/untar/blob/d21f7229b/src/untar.nim
  #
  # Determine which directory to copy.
  var srcDir = tempDir
  let contents = toSeq(walkDir(srcDir))
  if contents.len == 1:
    # Skip the outer directory.
    srcDir = contents[0][1]

  # Finally copy the directory to what the user specified.
  copyDirWithPermissions(srcDir, extractDir)

proc getNimInstallationDir*(options: Options, version: Version): string =
  return getNimBinariesDir(options) / ("nim-$1" % $version)

proc isNimDirProperlyExtracted*(extractDir: string): bool =
  let folders = @["lib", "bin"]
  for folder in folders:
    if not (extractDir / folder).dirExists():
      return false
  true

proc extractNimIfNeeded*(
    path, extractDir: string, options: Options, attempts: int = 0
): bool =
  if isNimDirProperlyExtracted(extractDir):
    return true
  # Dir doesn't exist or is incomplete. Extract from scratch.
  if attempts > 5:
    display(
      "Warning",
      "Failed to extract Nim to $1 after multiple attempts" % extractDir,
      Warning,
      HighPriority,
    )
    return false
  removeDir(extractDir)
  extract(path, extractDir)
  when defined(windows):
    #beforeInstall
    let buildAll = extractDir / "build_all.bat"
    if not buildAll.fileExists():
      writeFile(buildAll, "echo hello;")
  return extractNimIfNeeded(path, extractDir, options, attempts + 1)

proc saveNimMetaData(extractDir: string) =
  ## Save metadata for nim binaries installation with the canonical URL.
  ## This ensures lock files can reference nim properly.
  let metaDataFile = extractDir / packageMetaDataFileName
  if not metaDataFile.fileExists:
    var metaData = initPackageMetaData()
    metaData.url = "https://github.com/nim-lang/Nim.git"
    saveMetaData(metaData, extractDir, changeRoots = false)

proc downloadAndExtractNim*(
    version: Version, options: Options
): Future[Option[string]] {.async.} =
  try:
    let extractDir = options.getNimInstallationDir(version)
    # Check if already properly installed (with working binary)
    let nimBin = extractDir / "bin" / "nim".addFileExt(ExeExt)
    if extractDir.dirExists() and nimBin.fileExists:
      display("Info:", "Nim $1 already installed" % $version)
      saveNimMetaData(extractDir)
      return some extractDir
    let path = await downloadNim(version, options)
    let extracted = extractNimIfNeeded(path, extractDir, options)
    if extracted:
      # Compile if no binary exists (e.g., source tarballs from GitHub)
      let nimBin = extractDir / "bin" / "nim".addFileExt(ExeExt)
      if not nimBin.fileExists:
        display("Info:", "Compiling Nim $1 from source" % $version, priority = HighPriority)
        compileNim(options, extractDir, version.toVersionRange)
      saveNimMetaData(extractDir)
      return some extractDir
    else:
      return none(string)
  except CatchableError as exc:
    # Surface the underlying reason instead of swallowing it; otherwise the
    # caller only reports the generic "Failed to install nim".
    displayWarning("Could not download and extract Nim $1: $2" % [$version, exc.msg])
    return none(string)

proc downloadAndExtractNimMatchedVersion*(
    ver: VersionRange, options: Options
): Future[Option[string]] {.async.} =
  if options.offline:
    raise nimbleError("Cannot download Nim in offline mode.")
  # Handle special versions like #devel, #head, etc.
  if ver.kind == verSpecial:
    return await downloadAndExtractNim(newVersion($ver), options)
  let releases = getOfficialReleases(options)
    #TODO Use the cached make sure the order is correct
  for releaseVer in releases:
    if releaseVer.withinRange(ver):
      return await downloadAndExtractNim(releaseVer, options)
  return none(string)

type NimInstalled* = tuple[dir: string, ver: Version]
proc getNimVersion(nimDir: string): Option[Version] =
  let ver = getNimVersionFromBin(nimDir / "bin" / "nim".addFileExt(ExeExt))
  if ver.isSome():
    return ver

proc installNimFromBinariesDir*(
    require: PkgTuple, options: Options
): Option[NimInstalled] =
  if options.disableNimBinaries:
    return none(NimInstalled)
  # Check if already installed
  let nimBininstalledPkgs = getInstalledPkgsMin(options.nimBinariesDir, options)
  var pkg = initPackageInfo()
  if findPkg(nimBininstalledPkgs, require, pkg) and
      isNimDirProperlyExtracted(pkg.getRealDir):
    let ver = getNimVersion(pkg.getRealDir)
    if ver.isSome():
      # Don't warn for special versions like #devel - they won't match the binary version
      if not pkg.basicInfo.version.isSpecial and pkg.basicInfo.version != ver.get():
        displayWarning("Nim binary version doesn't match the package info version for Nim located at: " & pkg.getRealDir)
      saveNimMetaData(pkg.getRealDir)
      return some (pkg.getRealDir, ver.get())

  # Download if allowed
  if not options.offline and
      options.prompt("No nim version matching $1. Download it now?" % $require.ver):
    let extractedDir = downloadAndExtractNimMatchedVersion(require.ver, options)
    if extractedDir.isSome():
      # Try using downloaded version
      let ver = getNimVersion(extractedDir.get)
      if ver.isSome():
        return some (extractedDir.get, ver.get)

      # Rebuild if necessary
      displayInfo "There is no nim binary in the downloaded directory or it is corrupted. Rebuilding it"
      compileNim(options, extractedDir.get, require.ver)
      let rebuiltVer = getNimVersion(extractedDir.get)
      if rebuiltVer.isSome():
        return some (extractedDir.get, rebuiltVer.get)

  return none(NimInstalled)
