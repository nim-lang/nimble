import
  std/[
    httpclient, strutils, os, osproc, terminal, times, json, uri, sequtils, options,
    jsonutils,
  ]
import zippy/tarballs as zippy_tarballs
import zippy/ziparchives as zippy_zips

import common, options, packageinfo, nimenv

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

proc getProxy*(): Proxy =
  ## Returns ``nil`` if no proxy is specified.
  var url = ""
  try:
    if existsEnv("http_proxy"):
      url = getEnv("http_proxy")
    elif existsEnv("https_proxy"):
      url = getEnv("https_proxy")
  except ValueError:
    display(
      "Warning:",
      "Unable to parse proxy from environment: " & getCurrentExceptionMsg(),
      Warning,
      HighPriority,
    )

  if url.len > 0:
    var parsed = parseUri(url)
    if parsed.scheme.len == 0 or parsed.hostname.len == 0:
      parsed = parseUri("http://" & url)
    let auth =
      if parsed.username.len > 0:
        parsed.username & ":" & parsed.password
      else:
        ""
    return newProxy($parsed, auth)
  else:
    return nil

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
  let res = gorgeEx("sysctl -in sysctl.proc_translated")
  if res.exitCode == 0:
    return res.output.strip() == "1"
  return false

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
            # when choosenim become arm64 binary, isRosetta will be false. But we don't have nightlies for arm64 yet.
            # So, we should check if choosenim is compiled as x86_64 (nim's system.hostCPU returns amd64 even on Apple Silicon machines)
            if not isRosetta() and hostCPU == "amd64":
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
  githubTagReleasesUrl = "https://api.github.com/repos/nim-lang/Nim/tags"
  githubNightliesReleasesUrl =
    "https://api.github.com/repos/nim-lang/nightlies/releases"
  githubUrl = "https://github.com/nim-lang/Nim"
  websiteUrlXz = "https://nim-lang.org/download/nim-$1.tar.xz"
  websiteUrlGz = "https://nim-lang.org/download/nim-$1.tar.gz"
  csourcesUrl = "https://github.com/nim-lang/csources"
  dlArchive = "archive/$1.tar.gz"
  binaryUrl {.used.} =
    "https://nim-lang.org/download/nim-$1$2_x$3" & getBinArchiveFormat()
  userAgent = "nimble/" & nimbleVersion

const # Windows-only
  mingwUrl = "https://nim-lang.org/download/mingw$1.zip"
  dllsUrl = "https://nim-lang.org/download/dlls.zip"

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

proc addGithubAuthentication(url: string): string =
  let ghtoken = getEnv("GITHUB_TOKEN")
  if ghtoken == "":
    return url
  else:
    display(
      "Info:",
      "Using the 'GITHUB_TOKEN' environment variable for GitHub API Token.",
      priority = HighPriority,
    )
    return
      url.replace("https://api.github.com", "https://" & ghtoken & "@api.github.com")

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

proc downloadFileNim(url, outputPath: string) =
  displayDebug("Downloading using HttpClient")
  var client = newHttpClient(proxy = getProxy())

  var lastProgressPos = 0
  proc onProgressChanged(total, progress, speed: BiggestInt) {.closure, gcsafe.} =
    let fraction = progress.float / total.float
    if fraction == Inf:
      showIndeterminateBar(progress, speed, lastProgressPos)
    else:
      showBar(fraction, speed)

  client.onProgressChanged = onProgressChanged

  client.downloadFile(url, outputPath)

proc downloadFile*(url, outputPath: string) =
  # For debugging.
  display("GET:", url, priority = DebugPriority)

  # Create outputPath's directory if it doesn't exist already.
  createDir(outputPath.splitFile.dir)

  # Download to temporary file to prevent problems when choosenim crashes.
  let tempOutputPath = outputPath & "_temp"
  try:
    downloadFileNim(url, tempOutputPath)
  except HttpRequestError:
    echo("") # Skip line with progress bar.
    let msg =
      "Couldn't download file from $1.\nResponse was: $2" %
      [url, getCurrentExceptionMsg()]
    display("Info:", msg, Warning, MediumPriority)
    raise

  moveFile(tempOutputPath, outputPath)

  showBar(1, 0)
  echo("")

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

proc retrieveUrl*(url: string): string
proc downloadImpl(version: Version, options: Options): string =
  let arch = getGccArch(options)
  displayDebug("Detected", "arch as " & $arch & "bit")
  if version.isSpecial():
    var reference, url = ""
    if $version in ["#devel", "#head"]: # and not params.latest:
      # Install nightlies by default for devel channel
      try:
        let rawContents =
          retrieveUrl(githubNightliesReleasesUrl.addGithubAuthentication())
        let parsedContents = parseJson(rawContents)
        (url, reference) = getNightliesUrl(parsedContents, arch)
        if url.len == 0:
          display(
            "Warning",
            "Recent nightly release not found, installing latest devel commit.",
            Warning, HighPriority,
          )
        reference = if reference.len == 0: "devel" else: reference
      except HTTPRequestError:
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

    downloadFile(url, outputPath)
    result = outputPath
  else:
    display(
      "Downloading",
      "Nim $1 from $2" % [$version, "nim-lang.org"],
      priority = HighPriority,
    )

    var outputPath: string

    # Use binary builds for Windows and Linux
    when defined(Windows) or defined(linux):
      let os = when defined(linux): "-linux" else: ""
      let binUrl = binaryUrl % [$version, os, $arch]
      if not needsDownload(binUrl, outputPath, options):
        return outputPath
      try:
        downloadFile(binUrl, outputPath)
        return outputPath
      except HttpRequestError:
        display(
          "Info:",
          "Binary build unavailable, building from source",
          priority = HighPriority,
        )

    let hasUnxz = findExe("unxz") != ""
    let url = (if hasUnxz: websiteUrlXz else: websiteUrlGz) % $version
    #Note for macOs its using x86 we need to update the binaries and then the macos url
    if not needsDownload(url, outputPath, options):
      return outputPath
    echo "url: ", url
    downloadFile(url, outputPath)
    result = outputPath

proc downloadNim*(version: Version, options: Options): string =
  ## Returns the path of the downloaded .tar.(gz|xz) file.
  try:
    return downloadImpl(version, options)
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
  downloadFile(csourcesArchiveUrl, outputPath)
  return outputPath

proc downloadMingw*(options: Options): string =
  let
    arch = getCpuArch()
    url = mingwUrl % $arch
  var outputPath: string
  if not needsDownload(url, outputPath, options):
    return outputPath

  display("Downloading", "C compiler (Mingw$1)" % $arch, priority = HighPriority)
  downloadFile(url, outputPath)
  return outputPath

proc downloadDLLs*(options: Options): string =
  var outputPath: string
  if not needsDownload(dllsUrl, outputPath, options):
    return outputPath

  display("Downloading", "DLLs (openssl, pcre, ...)", priority = HighPriority)
  downloadFile(dllsUrl, outputPath)
  return outputPath

proc retrieveUrl*(url: string): string =
  display("Http", "Requesting " & url, priority = DebugPriority)
  var client = newHttpClient(proxy = getProxy(), userAgent = userAgent)
  return client.getContent(url)

proc getOfficialReleases*(options: Options): seq[Version] =
  #Avoid reaching github api limit
  #Later on, this file will be moved to a new global cache file that we are going to 
  #introduce when enabling the "enumerate all versions" feature
  let oficialReleasesCachedFile =
    options.nimbleDir.absolutePath() / "official-nim-releases.json"
  if oficialReleasesCachedFile.fileExists():
    return oficialReleasesCachedFile.readFile().parseJson().to(seq[Version])
  var parsedContents: JsonNode
  try:
    let rawContents = retrieveUrl(githubTagReleasesUrl.addGithubAuthentication())
    parsedContents = parseJson(rawContents)
  except CatchableError:
    display(
      "Warning", "Error getting official releases from github", Warning, HighPriority
    )
    #Avoid reaching github api limit when the file doesnt exists only expected to be reached in CI
    return
      @[
        newVersion("2.2.0"),
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
  let cutOffVersion = newVersion("0.16.0")

  var releases: seq[Version] = @[]
  for release in parsedContents:
    let name = release["name"].getStr().strip(true, false, {'v'})
    let version = name.newVersion
    if cutOffVersion <= version:
      releases.add(version)
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
      let tarFile = path.changeFileExt("")
      removeFile(tarFile) # just in case it exists, if it does `unxz` fails.
      if findExe("unxz") == "":
        raise newException(
          NimbleError,
          "Unable to extract. Need `unxz` to extract .tar.xz file. See https://github.com/dom96/choosenim/issues/290.",
        )
      doCmdRaw("unxz " & quoteShell(path))
      extract(tarFile, extractDir) # We remove the .xz extension
      return

  let tempDir = getTempDir() / "choosenim-extraction"
  removeDir(tempDir)

  try:
    case path.splitFile.ext
    of ".zip":
      zippy_zips.extractAll(path, tempDir)
    of ".tar", ".gz":
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
      display(
        "Warning",
        "Nim $1 is not properly extracted" % $extractDir,
        Warning,
        HighPriority,
      )
      return false
  true

proc extractNimIfNeeded*(
    path, extractDir: string, options: Options, attempts: int = 0
): bool =
  if isNimDirProperlyExtracted(extractDir):
    return true
  #dir exists but is not properly extracted. We need to wipe it out and extract from scratch
  if attempts > 5:
    return false
  removeDir(extractDir)
  extract(path, extractDir)
  when defined(windows):
    #beforeInstall 
    let buildAll = extractDir / "build_all.bat"
    if not buildAll.fileExists():
      writeFile(buildAll, "echo hello;")
  return extractNimIfNeeded(path, extractDir, options, attempts + 1)

proc downloadAndExtractNim*(version: Version, options: Options): Option[string] =
  try:
    let extractDir = options.getNimInstallationDir(version)
    if extractDir.dirExists() and isNimDirProperlyExtracted(extractDir):
      #TODO test if binary is valid?
      display("Info:", "Nim $1 already installed" % $version)
      return some extractDir
    let path = downloadNim(version, options)
    let extracted = extractNimIfNeeded(path, extractDir, options)
    if extracted:
      return some extractDir
    else:
      return none(string)
  except:
    return none(string)

proc downloadAndExtractNimMatchedVersion*(
    ver: VersionRange, options: Options
): Option[string] =
  let releases = getOfficialReleases(options)
    #TODO Use the cached make sure the order is correct
  for releaseVer in releases:
    if releaseVer.withinRange(ver):
      return downloadAndExtractNim(releaseVer, options)
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
