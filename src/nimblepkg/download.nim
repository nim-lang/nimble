# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import parseutils, os, strutils, tables, uri, strformat,
       httpclient, sequtils, urls, chronos

import compat/[json, osproc]
from algorithm import SortOrder, sorted

import packageinfotypes, packageparser, version, tools, common, options, cli,
       sha1hashes, vcstools, displaymessages, packageinfo, config, declarativeparser, packagemetadatafile

const userAgent = "nimble/" & nimbleVersion

type
  DownloadPkgResult* = tuple
    dir: string
    version: Version
    vcsRevision: Sha1Hash

proc updateSubmodules*(dir: string) =
  ## Updates git submodules in the given directory.
  ## Called during installation to ensure submodules are populated
  ## even if the package was cached without them during version discovery.
  discard tryDoCmdEx(
    &"git -C {dir.quoteShell} submodule update --init --recursive --depth 1")

proc tryDoCmdExAsync(cmd: string): Future[string] {.async.} =
  ## Async version of tryDoCmdEx. Executes command and raises error if it fails.
  let (output, exitCode) = await doCmdExAsync(cmd)
  if exitCode != QuitSuccess:
    let errorMsg = tryDoCmdExErrorMessage(cmd, output, exitCode)
    if isGitFatalError(exitCode):
      raise nimbleGitError(errorMsg)
    else:
      raise nimbleError(errorMsg)
  return output

proc updateSubmodulesAsync(dir: string): Future[void] {.async.} =
  ## Async version of updateSubmodules.
  discard await tryDoCmdExAsync(
    &"git -C {dir.quoteShell} submodule update --init --recursive --depth 1")

proc doCheckout*(meth: DownloadMethod, downloadDir, branch: string, options: Options): bool =
  ## Performs checkout and returns true if successful, false otherwise.
  case meth
  of DownloadMethod.git:
    # Force is used here because local changes may appear straight after a clone
    # has happened. Like in the case of git on Windows where it messes up the
    # damn line endings.
    let (_, exitCode) = doCmdEx(&"git -C {downloadDir.quoteShell} checkout --force {branch.quoteShell}")
    if exitCode != 0 and not branch.startsWith("v"):
      # Try with 'v' prefix as fallback (common convention for version tags)
      let (_, exitCode2) = doCmdEx(&"git -C {downloadDir.quoteShell} checkout --force v{branch.quoteShell}")
      if exitCode2 != 0:
        return false
    if not options.ignoreSubmodules:
      downloadDir.updateSubmodules
    return true
  of DownloadMethod.hg:
    let (_, exitCode) = doCmdEx(&"hg --cwd {downloadDir.quoteShell} checkout {branch.quoteShell}")
    return exitCode == 0

proc doCheckoutAsync*(meth: DownloadMethod, downloadDir, branch: string, options: Options): Future[bool] {.async.} =
  ## Async version of doCheckout that uses doCmdExAsync for non-blocking execution.
  ## Returns true if successful, false otherwise.
  case meth
  of DownloadMethod.git:
    # Force is used here because local changes may appear straight after a clone
    # has happened. Like in the case of git on Windows where it messes up the
    # damn line endings.
    let (_, exitCode) = await doCmdExAsync(&"git -C {downloadDir.quoteShell} checkout --force {branch.quoteShell}")
    if exitCode != 0 and not branch.startsWith("v"):
      # Try with 'v' prefix as fallback (common convention for version tags)
      let (_, exitCode2) = await doCmdExAsync(&"git -C {downloadDir.quoteShell} checkout --force v{branch.quoteShell}")
      if exitCode2 != 0:
        return false
    if not options.ignoreSubmodules:
      await downloadDir.updateSubmodulesAsync()
    return true
  of DownloadMethod.hg:
    let (_, exitCode) = await doCmdExAsync(&"hg --cwd {downloadDir.quoteShell} checkout {branch.quoteShell}")
    return exitCode == 0

proc doClone(meth: DownloadMethod, url, downloadDir: string, branch = "",
             onlyTip = true, options: Options) =
  case meth
  of DownloadMethod.git:
    let
      submoduleFlag = if not options.ignoreSubmodules: " --recurse-submodules" else: ""
      depthArg = if onlyTip: "--depth 1" else: ""
      branchArg = if branch == "": "" else: &"-b {branch.quoteShell}"
    discard tryDoCmdEx(
       "git clone --config core.autocrlf=false --config core.eol=lf " &
      &"{submoduleFlag} {depthArg} {branchArg} {url} {downloadDir.quoteShell}")
    if not options.ignoreSubmodules:
      downloadDir.updateSubmodules
  of DownloadMethod.hg:
    let
      tipArg = if onlyTip: "-r tip " else: ""
      branchArg = if branch == "": "" else: &"-b {branch.quoteShell}"
    discard tryDoCmdEx(&"hg clone {tipArg} {branchArg} {url} {downloadDir.quoteShell}")

proc doCloneAsync*(meth: DownloadMethod, url, downloadDir: string, branch = "",
                   onlyTip = true, options: Options): Future[void] {.async.} =
  ## Async version of doClone that uses doCmdExAsync for non-blocking execution.
  case meth
  of DownloadMethod.git:
    let
      submoduleFlag = if not options.ignoreSubmodules: " --recurse-submodules" else: ""
      depthArg = if onlyTip: "--depth 1" else: ""
      branchArg = if branch == "": "" else: &"-b {branch.quoteShell}"
    discard await tryDoCmdExAsync(
       "git clone --config core.autocrlf=false --config core.eol=lf " &
      &"{submoduleFlag} {depthArg} {branchArg} {url} {downloadDir.quoteShell}")
    if not options.ignoreSubmodules:
      await downloadDir.updateSubmodulesAsync()
  of DownloadMethod.hg:
    let
      tipArg = if onlyTip: "-r tip " else: ""
      branchArg = if branch == "": "" else: &"-b {branch.quoteShell}"
    discard await tryDoCmdExAsync(&"hg clone {tipArg} {branchArg} {url} {downloadDir.quoteShell}")

proc gitFetchTags*(repoDir: string, downloadMethod: DownloadMethod, options: Options) =
  case downloadMethod:
    of DownloadMethod.git:
      let submoduleFlag = if not options.ignoreSubmodules: " --recurse-submodules" else: ""
      tryDoCmdEx(&"git -C {repoDir} fetch --tags" & submoduleFlag)
    of DownloadMethod.hg:
      # In Mercurial, pulling updates also fetches all remote tags
      tryDoCmdEx(&"hg --cwd {repoDir} pull")

proc gitFetchTagsAsync*(repoDir: string, downloadMethod: DownloadMethod, options: Options): Future[void] {.async.} =
  ## Async version of gitFetchTags that uses doCmdExAsync for non-blocking execution.
  case downloadMethod:
    of DownloadMethod.git:
      let submoduleFlag = if not options.ignoreSubmodules: " --recurse-submodules" else: ""
      discard await tryDoCmdExAsync(&"git -C {repoDir} fetch --tags" & submoduleFlag)
    of DownloadMethod.hg:
      # In Mercurial, pulling updates also fetches all remote tags
      discard await tryDoCmdExAsync(&"hg --cwd {repoDir} pull")

proc getTagsList*(dir: string, meth: DownloadMethod): seq[string] =
  var output: string
  cd dir:
    case meth
    of DownloadMethod.git:
      output = tryDoCmdEx("git tag")
    of DownloadMethod.hg:
      output = tryDoCmdEx("hg tags")
  if output.len > 0:
    case meth
    of DownloadMethod.git:
      result = @[]
      for i in output.splitLines():
        if i == "": continue
        result.add(i)
    of DownloadMethod.hg:
      result = @[]
      for i in output.splitLines():
        if i == "": continue
        var tag = ""
        discard parseUntil(i, tag, ' ')
        if tag != "tip":
          result.add(tag)
  else:
    result = @[]

proc getTagsListAsync*(dir: string, meth: DownloadMethod): Future[seq[string]] {.async.} =
  ## Async version of getTagsList that uses doCmdExAsync for non-blocking execution.
  var output: string
  cd dir:
    case meth
    of DownloadMethod.git:
      output = await tryDoCmdExAsync("git tag")
    of DownloadMethod.hg:
      output = await tryDoCmdExAsync("hg tags")
  if output.len > 0:
    case meth
    of DownloadMethod.git:
      result = @[]
      for i in output.splitLines():
        if i == "": continue
        result.add(i)
    of DownloadMethod.hg:
      result = @[]
      for i in output.splitLines():
        if i == "": continue
        var tag = ""
        discard parseUntil(i, tag, ' ')
        if tag != "tip":
          result.add(tag)
  else:
    result = @[]

proc getTagsListRemote*(url: string, meth: DownloadMethod): seq[string] =
  result = @[]
  case meth
  of DownloadMethod.git:
    var (output, exitCode) = doCmdEx(&"git ls-remote --tags {url}")
    if exitCode != QuitSuccess:
      raise nimbleError("Unable to query remote tags for " & url &
                        " . Git returned: " & output)
    for i in output.splitLines():
      let refStart = i.find("refs/tags/")
      # git outputs warnings, empty lines, etc
      if refStart == -1: continue
      let start = refStart+"refs/tags/".len
      let tag = i[start .. i.len-1]
      if not tag.endswith("^{}"): result.add(tag)

  of DownloadMethod.hg:
    # http://stackoverflow.com/questions/2039150/show-tags-for-remote-hg-repository
    raise nimbleError("Hg doesn't support remote tag querying.")

proc getTagsListRemoteAsync*(url: string, meth: DownloadMethod): Future[seq[string]] {.async.} =
  ## Async version of getTagsListRemote that uses doCmdExAsync for non-blocking execution.
  result = @[]
  case meth
  of DownloadMethod.git:
    var (output, exitCode) = await doCmdExAsync(&"git ls-remote --tags {url}")
    if exitCode != QuitSuccess:
      raise nimbleError("Unable to query remote tags for " & url &
                        " . Git returned: " & output)
    for i in output.splitLines():
      let refStart = i.find("refs/tags/")
      # git outputs warnings, empty lines, etc
      if refStart == -1: continue
      let start = refStart+"refs/tags/".len
      let tag = i[start .. i.len-1]
      if not tag.endswith("^{}"): result.add(tag)

  of DownloadMethod.hg:
    # http://stackoverflow.com/questions/2039150/show-tags-for-remote-hg-repository
    raise nimbleError("Hg doesn't support remote tag querying.")

proc getVersionList*(tags: seq[string]): OrderedTable[Version, string] =
  ## Return an ordered table of Version -> git tag label.  Ordering is
  ## in descending order with the most recent version first.
  let taggedVers: seq[tuple[ver: Version, tag: string]] =
    tags
      .filterIt(it != "")
      .map(proc(s: string): tuple[ver: Version, tag: string] =
        # skip any chars before the version
        let i = skipUntil(s, Digits)
        # TODO: Better checking, tags can have any
        # names. Add warnings and such.
        result = (newVersion(s[i .. s.len-1]), s))
      .sorted(proc(a, b: (Version, string)): int = cmp(a[0], b[0]),
              SortOrder.Descending)
  result = toOrderedTable[Version, string](taggedVers)

proc getHeadName*(meth: DownloadMethod): Version =
  ## Returns the name of the download method specific head. i.e. for git
  ## it's ``head`` for hg it's ``tip``.
  case meth
  of DownloadMethod.git: newVersion("#head")
  of DownloadMethod.hg: newVersion("#tip")

proc checkUrlType*(url: string, options: Options): DownloadMethod =
  ## Determines the download method based on the URL.
  if options.offline:
    raise nimbleError("Cannot check URL type in offline mode: " & url)
  if doCmdEx("git ls-remote " & url.quoteShell()).exitCode == QuitSuccess:
    return DownloadMethod.git
  elif doCmdEx("hg identify " & url.quoteShell()).exitCode == QuitSuccess:
    return DownloadMethod.hg
  else:
    raise nimbleError("Unable to identify url: " & url)

proc getUrlData*(url: string): (string, Table[string, string]) =
  var uri = parseUri(url)
  # TODO: use uri.parseQuery once it lands... this code is quick and dirty.
  var subdir = ""
  if uri.query.startsWith("subdir="):
    subdir = uri.query[7 .. ^1]

  uri.query = ""
  return ($uri, {"subdir": subdir}.toTable())

proc cloneSpecificRevision(downloadMethod: DownloadMethod,
                           url, downloadDir: string,
                           vcsRevision: Sha1Hash, options: Options) =
  assert vcsRevision != notSetSha1Hash

  display("Cloning", "revision: " & $vcsRevision, priority = MediumPriority)
  case downloadMethod
  of DownloadMethod.git:
    let downloadDir = downloadDir.quoteShell
    createDir(downloadDir)
    discard tryDoCmdEx(&"git -C {downloadDir.quoteShell} init")
    discard tryDoCmdEx(&"git -C {downloadDir.quoteShell} config core.autocrlf false")
    discard tryDoCmdEx(&"git -C {downloadDir.quoteShell} remote add origin {url}")
    discard tryDoCmdEx(
      &"git -C {downloadDir.quoteShell} fetch --depth 1 origin {($vcsRevision).quoteShell}")
    discard tryDoCmdEx(&"git -C {downloadDir.quoteShell} reset --hard FETCH_HEAD")
    if not options.ignoreSubmodules:
      downloadDir.updateSubmodules
  of DownloadMethod.hg:
    discard tryDoCmdEx(&"hg clone {url} -r {($vcsRevision).quoteShell}")

proc cloneSpecificRevisionAsync*(downloadMethod: DownloadMethod,
                                  url, downloadDir: string,
                                  vcsRevision: Sha1Hash, options: Options): Future[void] {.async.} =
  ## Async version of cloneSpecificRevision that uses doCmdExAsync for non-blocking execution.
  assert vcsRevision != notSetSha1Hash

  display("Cloning", "revision: " & $vcsRevision, priority = MediumPriority)
  case downloadMethod
  of DownloadMethod.git:
    let downloadDir = downloadDir.quoteShell
    createDir(downloadDir)
    discard await tryDoCmdExAsync(&"git -C {downloadDir.quoteShell} init")
    discard await tryDoCmdExAsync(&"git -C {downloadDir.quoteShell} config core.autocrlf false")
    discard await tryDoCmdExAsync(&"git -C {downloadDir.quoteShell} remote add origin {url}")
    discard await tryDoCmdExAsync(
      &"git -C {downloadDir.quoteShell} fetch --depth 1 origin {($vcsRevision).quoteShell}")
    discard await tryDoCmdExAsync(&"git -C {downloadDir.quoteShell} reset --hard FETCH_HEAD")
    if not options.ignoreSubmodules:
      await downloadDir.updateSubmodulesAsync()
  of DownloadMethod.hg:
    discard await tryDoCmdExAsync(&"hg clone {url} -r {($vcsRevision).quoteShell}")

var tarExePathCache {.threadvar.}: string

proc getTarExePath: string =
  ## Returns path to `tar` executable.
  if tarExePathCache == "":
    tarExePathCache =
      when defined(Windows):
        # On Windows, prefer Git's tar which supports --force-local
        # Git for Windows includes tar at <GitRoot>/usr/bin/tar.exe
        let gitPath = findExe("git")
        if gitPath != "":
          # Navigate up from git.exe location to find Git root, then check usr/bin/tar.exe
          var currentDir = gitPath.splitPath.head
          var gitTar = ""
          # Search up to 3 levels up for usr/bin/tar.exe
          for i in 0..2:
            let candidateTar = currentDir / "usr" / "bin" / "tar.exe"
            if fileExists(candidateTar):
              gitTar = candidateTar
              break
            currentDir = currentDir.parentDir

          if gitTar != "":
            gitTar
          else:
            findExe("tar")
        else:
          findExe("tar")
      else:
        findExe("tar")
    tarExePathCache = tarExePathCache.quoteShell
  return tarExePathCache

proc hasTar: bool {.raises: [], gcsafe.} =
  ## Checks whether a `tar` external tool is available.
  var hasTar {.global.} = false
  once:
    try:
      # Try to execute `tar` to ensure that it is available.
      let (_, exitCode) = execCmdEx(getTarExePath() & " --version")
      hasTar = exitCode == QuitSuccess
    except OSError:
      discard
    except IOError:
      discard
  return hasTar

proc isGitHubRepo(url: string): bool =
  ## Determines whether the `url` points to a GitHub repository.
  url.contains("github.com")

proc downloadTarball(url: string, options: Options): bool =
  ## Determines whether to download the repository as a tarball.
  ## Tarballs don't include git submodules, so we must use git clone when submodules are needed.
  options.enableTarballs and
  not options.forceFullClone and
  url.isGitHubRepo and
  hasTar() and
  options.ignoreSubmodules  # Only use tarballs when ignoring submodules

proc removeTrailingGitString*(url: string): string =
  ## Removes ".git" from an URL.
  ##
  ## For example:
  ## "https://github.com/nim-lang/nimble.git" -> "https://github.com/nim-lang/nimble"
  if url.len > 4 and url.endsWith(".git"): url[0..^5] else: url

proc getTarballDownloadLink(url, version: string): string =
  ## Returns the package tarball download link for given repository URL and
  ## version.
  removeTrailingGitString(url) & "/tarball/" & version

proc seemsLikeRevision(version: string): bool =
  ## Checks whether the given `version` string seems like part of sha1 hash
  ## value.
  assert version.len > 0, "version must not be an empty string"
  for c in version:
    if c notin HexDigits:
      return false
  return true

proc extractOwnerAndRepo(url: string): string =
  ## Extracts owner and repository string from an URL to GitHub repository.
  ##
  ## For example:
  ## "https://github.com/nim-lang/nimble.git" -> "nim-lang/nimble"
  assert url.isGitHubRepo, "Only GitHub URLs are supported."
  let url = removeTrailingGitString(url)
  var slashPosition = url.rfind('/')
  slashPosition = url.rfind('/', last = slashPosition - 1)
  return url[slashPosition + 1 .. ^1]

proc getGitHubApiUrl(url, commit: string): string =
  ## By given URL to GitHub repository and part of a commit hash constructs
  ## an URL for the GitHub REST API query for the full commit hash.
  &"https://api.github.com/repos/{extractOwnerAndRepo(url)}/commits/{commit}"

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

proc retrieveUrl*(url: string): string =
  display("Http", "Requesting " & url, priority = DebugPriority)
  {.cast(raises: [CatchableError]).}:
    var client = newHttpClient(proxy = getProxy(), userAgent = userAgent)
    return client.getContent(url)

{.warning[ProveInit]: off.}
proc getFullRevisionFromGitHubApi(url, version: string): Sha1Hash =
  ## By given a commit short hash and an URL to a GitHub repository retrieves
  ## the full hash of the commit by using GitHub REST API.
  try:
    let gitHubApiUrl = getGitHubApiUrl(url, version)
    display("Get", gitHubApiUrl);
    let content = retrieveUrl(gitHubApiUrl)
    let json = parseJson(content)
    if json.hasKey("sha"):
      return json["sha"].str.initSha1Hash
    else:
      raise nimbleError(json["message"].str)
  except CatchableError as error:
    raise nimbleError(&"Cannot get revision for version \"{version}\" " &
                      &"of package at \"{url}\".", details = error)
{.warning[ProveInit]: on.}

proc parseRevision(lsRemoteOutput: string): Sha1Hash =
  ## Parses the output from `git ls-remote` call to extract the returned sha1
  ## hash value. Even when successful the first line of the command's output
  ## can be a redirection warning.
  let lines = lsRemoteOutput.splitLines
  for line in lines:
    if line.len >= 40:
      try:
        return line[0..39].initSha1Hash
      except InvalidSha1HashError:
        discard
  return notSetSha1Hash

proc getRevision*(url, version: string): Sha1Hash =
  ## Returns the commit hash corresponding to the given `version` of the package
  ## in repository at `url`.
  let output = tryDoCmdEx(&"git ls-remote {url} {version}")
  result = parseRevision(output)
  if result == notSetSha1Hash:
    if version.seemsLikeRevision:
      result = getFullRevisionFromGitHubApi(url, version)
    else:
      raise nimbleError(&"Cannot get revision for version \"{version}\" " &
                        &"of package at \"{url}\".")

proc getRevisionAsync(url, version: string): Future[Sha1Hash] {.async.} =
  ## Async version of getRevision that uses doCmdExAsync.
  let output = await tryDoCmdExAsync(&"git ls-remote {url} {version}")
  result = parseRevision(output)
  if result == notSetSha1Hash:
    if version.seemsLikeRevision:
      result = getFullRevisionFromGitHubApi(url, version)
    else:
      raise nimbleError(&"Cannot get revision for version \"{version}\" " &
                        &"of package at \"{url}\".")

proc getTarCmdLine(downloadDir, filePath: string): string {.gcsafe.} =
  ## Returns an OS specific command and arguments for extracting the downloaded
  ## tarball.
  when defined(Windows):
    let downloadDir = downloadDir.replace('\\', '/')
    let filePath = filePath.replace('\\', '/')
    &"{getTarExePath()} -C {downloadDir.quoteShell} -xf {filePath} --strip-components 1 " &
     "--force-local"
  else:
    &"tar -C {downloadDir.quoteShell} -xf {filePath} --strip-components 1"

proc doDownloadTarball(url, downloadDir, version: string, queryRevision: bool):
    Sha1Hash =
  ## Downloads package tarball from GitHub. Returns the commit hash of the
  ## downloaded package in the case `queryRevision` is `true`.

  let downloadLink = getTarballDownloadLink(url, version)
  display("Downloading", downloadLink)
  let data = retrieveUrl(downloadLink)
  display("Completed", "downloading " & downloadLink)

  let filePath = downloadDir / "tarball.tar.gz"
  display("Saving", filePath)
  downloadDir.createDir
  writeFile(filePath, data)
  display("Completed", "saving " & filePath)

  display("Unpacking", filePath)
  let cmd = getTarCmdLine(downloadDir, filePath)
  let (output, exitCode) = doCmdEx(cmd)
  if exitCode != QuitSuccess and not output.contains("Cannot create symlink to"):
    # If the command fails for reason different then unable establishing a
    # sym-link raise an exception. This reason for failure is common on Windows
    # and the `tar` tool does not provide suitable option for avoiding it on
    # unpack time. If this error occurs the files were previously extracted
    # successfully and it should not be treated as error.
    raise nimbleError(tryDoCmdExErrorMessage(cmd, output, exitCode))
  display("Completed", "unpacking " & filePath)

  when defined(windows):
    # On Windows symbolic link files are not being extracted properly by the
    # `tar` command. They are extracted as empty files, but when cloning the
    # repository with Git they are extracted as ordinary files with the link
    # path in them. For that reason here we parse the tar file content to
    # extract the symbolic links and add their paths manually to the content of
    # their files.
    let listCmd = &"{getTarExePath()} -ztvf {filePath} --force-local"
    let (cmdOutput, cmdExitCode) = doCmdEx(listCmd)
    if cmdExitCode != QuitSuccess:
      raise nimbleError(tryDoCmdExErrorMessage(listCmd, cmdOutput, cmdExitCode))
    for line in cmdOutput.splitLines():
      if line.contains(" -> "):
        let parts = line.split
        let linkPath = parts[^1]
        let linkNameParts = parts[^3].split('/')
        let linkName = linkNameParts[1 .. ^1].foldl(a / b)
        writeFile(downloadDir / linkName, linkPath)

  filePath.removeFile
  return if queryRevision: getRevision(url, version) else: notSetSha1Hash

proc doDownloadTarballAsync*(url, downloadDir, version: string, queryRevision: bool): Future[Sha1Hash] {.async.} =
  ## Async version of doDownloadTarball that uses doCmdExAsync for tar extraction.
  ## Note: HTTP download is still synchronous, but tar extraction is async.
  let downloadLink = getTarballDownloadLink(url, version)
  display("Downloading", downloadLink)
  let data = retrieveUrl(downloadLink)
  display("Completed", "downloading " & downloadLink)

  let filePath = downloadDir / "tarball.tar.gz"
  display("Saving", filePath)
  downloadDir.createDir
  writeFile(filePath, data)
  display("Completed", "saving " & filePath)

  display("Unpacking", filePath)
  let cmd = getTarCmdLine(downloadDir, filePath)
  let (output, exitCode) = await doCmdExAsync(cmd)
  if exitCode != QuitSuccess and not output.contains("Cannot create symlink to"):
    raise nimbleError(tryDoCmdExErrorMessage(cmd, output, exitCode))
  display("Completed", "unpacking " & filePath)

  when defined(windows):
    let listCmd = &"{getTarExePath()} -ztvf {filePath} --force-local"
    let (cmdOutput, cmdExitCode) = await doCmdExAsync(listCmd)
    if cmdExitCode != QuitSuccess:
      raise nimbleError(tryDoCmdExErrorMessage(listCmd, cmdOutput, cmdExitCode))
    for line in cmdOutput.splitLines():
      if line.contains(" -> "):
        let parts = line.split
        let linkPath = parts[^1]
        let linkNameParts = parts[^3].split('/')
        let linkName = linkNameParts[1 .. ^1].foldl(a / b)
        writeFile(downloadDir / linkName, linkPath)

  filePath.removeFile
  return if queryRevision: await getRevisionAsync(url, version) else: notSetSha1Hash

{.warning[ProveInit]: off.}
proc doDownload(url, downloadDir: string, verRange: VersionRange,
                downMethod: DownloadMethod, options: Options,
                vcsRevision: Sha1Hash):
    tuple[version: Version, vcsRevision: Sha1Hash] =
  ## Downloads the repository specified by ``url`` using the specified download
  ## method.
  ##
  ## Returns the version of the repository which has been downloaded.
  template getLatestByTag(meth: untyped) {.dirty.} =
    # Find latest version that fits our ``verRange``.
    var latest = findLatest(verRange, versions)
    ## Note: HEAD is not used when verRange.kind is verAny. This is
    ## intended behaviour, the latest tagged version will be used in this case.

    # If no tagged versions satisfy our range latest.tag will be "".
    # We still clone in that scenario because we want to try HEAD in that case.
    # https://github.com/nim-lang/nimble/issues/22
    meth
    if $latest.ver != "":
      result.version = latest.ver

  result.vcsRevision = notSetSha1Hash

  removeDir(downloadDir)
  if vcsRevision != notSetSha1Hash:
    if downloadTarball(url, options):
      discard doDownloadTarball(url, downloadDir, $vcsRevision, false)
    else:
      cloneSpecificRevision(downMethod, url, downloadDir, vcsRevision, options)
    result.vcsRevision = vcsRevision
  elif verRange.kind == verSpecial:
    # We want a specific commit/branch/tag here.
    if verRange.spe == getHeadName(downMethod):
       # Grab HEAD.
      if downloadTarball(url, options):
        result.vcsRevision = doDownloadTarball(url, downloadDir, "HEAD", true)
      else:
        doClone(downMethod, url, downloadDir,
                onlyTip = not options.forceFullClone, options = options)
    else:
      assert ($verRange.spe)[0] == '#',
             "The special version must start with '#'."
      let specialVersion = substr($verRange.spe, 1)
      if downloadTarball(url, options):
        result.vcsRevision = doDownloadTarball(
          url, downloadDir, specialVersion, true)
      else:
        # Try normal clone + checkout first (works for branches, tags, and reachable commits)
        doClone(downMethod, url, downloadDir, onlyTip = false, options = options)
        let checkoutSuccess = doCheckout(downMethod, downloadDir, specialVersion, options = options)
        if not checkoutSuccess:
          # Checkout failed - likely a commit hash not reachable from default branch.
          # Fall back to cloneSpecificRevision which fetches the specific commit directly.
          removeDir(downloadDir)
          cloneSpecificRevision(downMethod, url, downloadDir, initSha1Hash(specialVersion), options)
          result.vcsRevision = initSha1Hash(specialVersion)
    result.version = verRange.spe
  else:
    case downMethod
    of DownloadMethod.git:
      # For Git we have to query the repo remotely for its tags. This is
      # necessary as cloning with a --depth of 1 removes all tag info.
      result.version = getHeadName(downMethod)
      let versions = getTagsListRemote(url, downMethod).getVersionList()
      if versions.len > 0:
        getLatestByTag:
          if downloadTarball(url, options):
            let versionToDownload =
              if latest.tag.len > 0: latest.tag else: "HEAD"
            result.vcsRevision = doDownloadTarball(
              url, downloadDir, versionToDownload, true)
          else:
            display("Cloning", "latest tagged version: " & latest.tag,
                    priority = MediumPriority)
            doClone(downMethod, url, downloadDir, latest.tag,
                    onlyTip = not options.forceFullClone, options = options)
      else:
        display("Warning:", &"The package {url} has no tagged releases, downloading HEAD instead.", Warning,
                priority = HighPriority)
        if downloadTarball(url, options):
          result.vcsRevision = doDownloadTarball(url, downloadDir, "HEAD", true)
        else:
          # If no commits have been tagged on the repo we just clone HEAD.
          doClone(downMethod, url, downloadDir, onlyTip = not options.forceFullClone, options = options) # Grab HEAD.
    of DownloadMethod.hg:
      doClone(downMethod, url, downloadDir,
              onlyTip = not options.forceFullClone, options = options)
      result.version = getHeadName(downMethod)
      let versions = getTagsList(downloadDir, downMethod).getVersionList()

      if versions.len > 0:
        getLatestByTag:
          display("Switching", "to latest tagged version: " & latest.tag,
                  priority = MediumPriority)
          discard doCheckout(downMethod, downloadDir, latest.tag, options = options)
      else:
        display("Warning:", &"The package {url} has no tagged releases, downloading HEAD instead.", Warning,
                  priority = HighPriority)

  if result.vcsRevision == notSetSha1Hash:
    # In the case the package in not downloaded as tarball we must query its
    # VCS revision from its download directory.
    result.vcsRevision = downloadDir.getVcsRevision
{.warning[ProveInit]: on.}

proc doDownloadAsync(url, downloadDir: string, verRange: VersionRange,
                     downMethod: DownloadMethod, options: Options,
                     vcsRevision: Sha1Hash):
    Future[tuple[version: Version, vcsRevision: Sha1Hash]] {.async.} =
  ## Async version of doDownload that uses async operations for clone, checkout, and tarball downloads.
  template getLatestByTag(meth: untyped) {.dirty.} =
    # Find latest version that fits our ``verRange``.
    var latest = findLatest(verRange, versions)
    ## Note: HEAD is not used when verRange.kind is verAny. This is
    ## intended behaviour, the latest tagged version will be used in this case.

    # If no tagged versions satisfy our range latest.tag will be "".
    # We still clone in that scenario because we want to try HEAD in that case.
    # https://github.com/nim-lang/nimble/issues/22
    meth
    if $latest.ver != "":
      result.version = latest.ver

  result.vcsRevision = notSetSha1Hash

  removeDir(downloadDir)
  if vcsRevision != notSetSha1Hash:
    if downloadTarball(url, options):
      discard await doDownloadTarballAsync(url, downloadDir, $vcsRevision, false)
    else:
      await cloneSpecificRevisionAsync(downMethod, url, downloadDir, vcsRevision, options)
    result.vcsRevision = vcsRevision
  elif verRange.kind == verSpecial:
    # We want a specific commit/branch/tag here.
    if verRange.spe == getHeadName(downMethod):
       # Grab HEAD.
      if downloadTarball(url, options):
        result.vcsRevision = await doDownloadTarballAsync(url, downloadDir, "HEAD", true)
      else:
        await doCloneAsync(downMethod, url, downloadDir,
                onlyTip = not options.forceFullClone, options = options)
    else:
      assert ($verRange.spe)[0] == '#',
             "The special version must start with '#'."
      let specialVersion = substr($verRange.spe, 1)
      if downloadTarball(url, options):
        result.vcsRevision = await doDownloadTarballAsync(
          url, downloadDir, specialVersion, true)
      else:
        # Try normal clone + checkout first (works for branches, tags, and reachable commits)
        await doCloneAsync(downMethod, url, downloadDir, onlyTip = false, options = options)
        let checkoutSuccess = await doCheckoutAsync(downMethod, downloadDir, specialVersion, options = options)
        if not checkoutSuccess:
          # Checkout failed - likely a commit hash not reachable from default branch.
          # Fall back to cloneSpecificRevision which fetches the specific commit directly.
          removeDir(downloadDir)
          await cloneSpecificRevisionAsync(downMethod, url, downloadDir, initSha1Hash(specialVersion), options)
          result.vcsRevision = initSha1Hash(specialVersion)
    result.version = verRange.spe
  else:
    case downMethod
    of DownloadMethod.git:
      # For Git we have to query the repo remotely for its tags. This is
      # necessary as cloning with a --depth of 1 removes all tag info.
      result.version = getHeadName(downMethod)
      let versions = (await getTagsListRemoteAsync(url, downMethod)).getVersionList()
      if versions.len > 0:
        getLatestByTag:
          if downloadTarball(url, options):
            let versionToDownload =
              if latest.tag.len > 0: latest.tag else: "HEAD"
            result.vcsRevision = await doDownloadTarballAsync(
              url, downloadDir, versionToDownload, true)
          else:
            display("Cloning", "latest tagged version: " & latest.tag,
                    priority = MediumPriority)
            await doCloneAsync(downMethod, url, downloadDir, latest.tag,
                    onlyTip = not options.forceFullClone, options = options)
      else:
        display("Warning:", &"The package {url} has no tagged releases, downloading HEAD instead.", Warning,
                priority = HighPriority)
        if downloadTarball(url, options):
          result.vcsRevision = await doDownloadTarballAsync(url, downloadDir, "HEAD", true)
        else:
          # If no commits have been tagged on the repo we just clone HEAD.
          await doCloneAsync(downMethod, url, downloadDir, onlyTip = not options.forceFullClone, options = options) # Grab HEAD.
    of DownloadMethod.hg:
      await doCloneAsync(downMethod, url, downloadDir,
              onlyTip = not options.forceFullClone, options = options)
      result.version = getHeadName(downMethod)
      let versions = getTagsList(downloadDir, downMethod).getVersionList()

      if versions.len > 0:
        getLatestByTag:
          display("Switching", "to latest tagged version: " & latest.tag,
                  priority = MediumPriority)
          discard doCheckout(downMethod, downloadDir, latest.tag, options = options)
      else:
        display("Warning:", &"The package {url} has no tagged releases, downloading HEAD instead.", Warning,
                  priority = HighPriority)

  if result.vcsRevision == notSetSha1Hash:
    # In the case the package in not downloaded as tarball we must query its
    # VCS revision from its download directory.
    result.vcsRevision = downloadDir.getVcsRevision

proc pkgDirHasNimble*(dir: string, options: Options): bool =
  try:
    discard findNimbleFile(dir, true, options)
    return true
  except NimbleError: 
    #Continue with the download
    discard

proc downloadPkgDir*(url: string,
                     verRange: VersionRange,
                     subdir: string,
                     options: Options,
                     vcsRevision: Sha1Hash = notSetSha1Hash,
                     downloadPath: string = ""
): (string, string) =
  let downloadDir =
    if downloadPath == "":
      (getNimbleTempDir() / getDownloadDirName(url, verRange, vcsRevision))
    else:
      downloadPath

  createDir(downloadDir)

  result = (downloadDir, downloadDir / subdir)

proc downloadPkg*(url: string, verRange: VersionRange,
                  downMethod: DownloadMethod,
                  subdir: string,
                  options: Options,
                  downloadPath: string,
                  vcsRevision: Sha1Hash,
                  nimBin: string,
                  validateRange = true): DownloadPkgResult =
  ## Downloads the repository as specified by ``url`` and ``verRange`` using
  ## the download method specified.
  ##
  ## If `downloadPath` isn't specified a location in /tmp/ will be used.
  ##
  ## Returns the directory where it was downloaded (subdir is appended) and
  ## the concrete version  which was downloaded.
  ##
  ## ``vcsRevision``
  ##   If specified this parameter will cause specific VCS revision to be
  ##   checked out.

  let (downloadDir, pkgDir) = downloadPkgDir(url, verRange, subdir, options, vcsRevision, downloadPath)
  result.dir = pkgDir

  #when using a persistent download dir we can skip the download if it's already done
  if pkgDirHasNimble(result.dir, options):
    return # already downloaded, skipping

  if options.offline:
    raise nimbleError("Cannot download in offline mode.")

  let modUrl = modifyUrl(url, options.config.cloneUsingHttps)

  let downloadMethod = if downloadTarball(modUrl, options):
    "http" else: $downMethod

  if subdir.len > 0:
    display("Downloading", "$1 using $2 (subdir is '$3')" %
                           [modUrl, downloadMethod, subdir],
            priority = HighPriority)
  else:
    display("Downloading", "$1 using $2" % [modUrl, downloadMethod],
            priority = HighPriority)

  (result.version, result.vcsRevision) = doDownload(
    modUrl, downloadDir, verRange, downMethod, options, vcsRevision)
  
  var metaData = initPackageMetaData()
  metaData.url = modUrl
  metaData.vcsRevision = result.vcsRevision
  saveMetaData(metaData, result.dir)

  var pkgInfo: PackageInfo
  if validateRange and verRange.kind notin {verSpecial, verAny} or not options.isLegacy:
    ## Makes sure that the downloaded package's version satisfies the requested
    ## version range.
    pkginfo = if options.satResult.pass == satNimSelection: #TODO later when in vnext we should just use this code path and fallback inside the toRequires if we can
      getPkgInfoFromDirWithDeclarativeParser(result.dir, options, nimBin)
    else:
      getPkgInfo(result.dir, options, nimBin)
    if pkginfo.basicInfo.version notin verRange:
      raise nimbleError(
        "Downloaded package's version does not satisfy requested version " &
        "range: wanted $1 got $2." %
        [$verRange, $pkginfo.basicInfo.version])

    #TODO rework the pkgcache to handle this better
    #ideally we should be able to know the version we are downloading upfront 
    #as for the constraints we need a way to invalidate the cache entry so it doesnt get outdated
    # if options.isVNext:
    #   # Rename the download directory to use actual version if it's different from the version range
    #   # as constraints shouldnt be stored in the download cache but the actual package version
    #   # theorically this means that subsequent downloads of unconstraines packages will be re-download
    #   # but this shouldnt be an issue since when a package is installed we dont reach this point anymore
    #   let newDownloadDir = options.pkgCachePath / getDownloadDirName(url, pkginfo.basicInfo.version.toVersionRange(), notSetSha1Hash)
    #   if downloadDir != newDownloadDir:
    #     if dirExists(newDownloadDir):
    #       removeDir(newDownloadDir)  
    #     moveDir(downloadDir, newDownloadDir)
    #     result.dir = newDownloadDir / subdir

proc downloadPkgAsync*(url: string, verRange: VersionRange,
                       downMethod: DownloadMethod,
                       subdir: string,
                       options: Options,
                       downloadPath: string,
                       vcsRevision: Sha1Hash,
                       nimBin: string,
                       validateRange = true): Future[DownloadPkgResult] {.async.} =
  ## Async version of downloadPkg that uses async operations for cloning and downloading.
  ## Downloads the repository as specified by ``url`` and ``verRange`` using
  ## the download method specified.
  ##
  ## If `downloadPath` isn't specified a location in /tmp/ will be used.
  ##
  ## Returns the directory where it was downloaded (subdir is appended) and
  ## the concrete version  which was downloaded.
  ##
  ## ``vcsRevision``
  ##   If specified this parameter will cause specific VCS revision to be
  ##   checked out.

  let (downloadDir, pkgDir) = downloadPkgDir(url, verRange, subdir, options, vcsRevision, downloadPath)
  result.dir = pkgDir

  #when using a persistent download dir we can skip the download if it's already done
  if pkgDirHasNimble(result.dir, options):
    return # already downloaded, skipping

  if options.offline:
    raise nimbleError("Cannot download in offline mode.")

  let modUrl = modifyUrl(url, options.config.cloneUsingHttps)

  let downloadMethod = if downloadTarball(modUrl, options):
    "http" else: $downMethod

  if subdir.len > 0:
    display("Downloading", "$1 using $2 (subdir is '$3')" %
                           [modUrl, downloadMethod, subdir],
            priority = HighPriority)
  else:
    display("Downloading", "$1 using $2" % [modUrl, downloadMethod],
            priority = HighPriority)

  (result.version, result.vcsRevision) = await doDownloadAsync(
    modUrl, downloadDir, verRange, downMethod, options, vcsRevision)

  var metaData = initPackageMetaData()
  metaData.url = modUrl
  metaData.vcsRevision = result.vcsRevision
  saveMetaData(metaData, result.dir)

  var pkgInfo: PackageInfo
  if validateRange and verRange.kind notin {verSpecial, verAny} or not options.isLegacy:
    ## Makes sure that the downloaded package's version satisfies the requested
    ## version range.
    pkginfo = if options.satResult.pass == satNimSelection: #TODO later when in vnext we should just use this code path and fallback inside the toRequires if we can
      getPkgInfoFromDirWithDeclarativeParser(result.dir, options, nimBin)
    else:
      getPkgInfo(result.dir, options, nimBin)
  if pkginfo.basicInfo.version notin verRange:
    raise nimbleError(
      "Downloaded package's version does not satisfy requested version " &
      "range: wanted $1 got $2." %
      [$verRange, $pkginfo.basicInfo.version])

    #TODO rework the pkgcache to handle this better
    #ideally we should be able to know the version we are downloading upfront
    #as for the constraints we need a way to invalidate the cache entry so it doesnt get outdated
    # if options.isVNext:
    #   # Rename the download directory to use actual version if it's different from the version range
    #   # as constraints shouldnt be stored in the download cache but the actual package version
    #   # theorically this means that subsequent downloads of unconstraines packages will be re-download
    #   # but this shouldnt be an issue since when a package is installed we dont reach this point anymore
    #   let newDownloadDir = options.pkgCachePath / getDownloadDirName(url, pkginfo.basicInfo.version.toVersionRange(), notSetSha1Hash)
    #   if downloadDir != newDownloadDir:
    #     if dirExists(newDownloadDir):
    #       removeDir(newDownloadDir)
    #     moveDir(downloadDir, newDownloadDir)
    #     result.dir = newDownloadDir / subdir

proc echoPackageVersions*(pkg: Package) =
  let downMethod = pkg.downloadMethod
  case downMethod
  of DownloadMethod.git:
    try:
      let versions = getTagsListRemote(pkg.url, downMethod).getVersionList()
      if versions.len > 0:
        let sortedVersions = toSeq(values(versions))
        displayInfoLine("  versions:    ", join(sortedVersions, ", "))
      else:
        displayInfoLine("  versions:    ", "(No versions tagged in the remote repository)")
    except CatchableError:
      displayFormatted(DisplayType.Error, "  Error: ")
      displayFormatted(DisplayType.Error, getCurrentExceptionMsg())
      displayFormatted(Hint, "\n")
  of DownloadMethod.hg:
    displayInfoLine("  versions:    ", "(Remote tag retrieval not supported by " &
                                        $pkg.downloadMethod & ")")

proc removeTrailingSlash(s: string): string =
  s.strip(chars = {'/'}, leading = false)

proc getDevelopDownloadDir*(url, subdir: string, options: Options): string =
  ## Returns the download dir for a develop mode dependency.
  assert isURL(url), &"The string \"{url}\" is not a URL."

  let url = url.removeTrailingSlash
  let subdir = subdir.removeTrailingSlash

  let downloadDirName =
    if subdir.len == 0:
      parseUri(url).path.splitFile.name
    else:
      subdir.splitFile.name

  result =
    if options.action.path.isAbsolute:
      options.action.path / downloadDirName
    else:
      getCurrentDir() / options.action.path / downloadDirName

proc refresh*(options: Options) =
  ## Downloads the package list from the specified URL.
  ##
  ## If the download is not successful, an exception is raised.
  if options.offline:
    raise nimbleError("Cannot refresh package list in offline mode.")

  let parameter =
    if options.action.typ == actionRefresh:
      options.action.optionalURL
    else:
      ""

  if parameter.len > 0:
    if parameter.isUrl:
      let cmdLine = PackageList(name: "commandline", urls: @[parameter])
      fetchList(cmdLine, options)
    else:
      if parameter notin options.config.packageLists:
        let msg = "Package list with the specified name not found."
        raise nimbleError(msg)

      fetchList(options.config.packageLists[parameter], options)
  else:
    # Try each package list in config
    for name, list in options.config.packageLists:
      fetchList(list, options)

proc getDownloadInfo*(
    pv: PkgTuple, options: Options,
    doPrompt: bool,
    ignorePackageCache = false,
): (DownloadMethod, string, Table[string, string]) =

  # echo "getDownloadInfo:pv.name: ", $pv.name
  var pkg = initPackage()
  if getPackage(pv.name, options, pkg, ignorePackageCache):
    let (url, metadata) = getUrlData(pkg.url)
    result = (pkg.downloadMethod, url, metadata)
    # echo "getDownloadInfo:getPackage: ", $result
    return
  elif pv.name.isURL:
    # echo "getDownloadInfo:isURL:name: ", $pv.name
    # echo "getDownloadInfo:isURL:options.nimbleData: ", $options.nimbleData
    let (url, urlmeta) = getUrlData(pv.name)
    var metadata = urlmeta
    metadata["urlOnly"] = "true"
    result = (checkUrlType(url, options), url, metadata)
    # echo "getDownloadInfo:isURL: ", $result
    return
  else:
    # If package is not found give the user a chance to refresh
    # package.json
    if doPrompt and not options.offline and
        options.prompt(pv.name & " not found in any local packages.json, " &
                        "check internet for updated packages?"):
      refresh(options)

      # Once we've refreshed, try again, but don't prompt if not found
      # (as we've already refreshed and a failure means it really
      # isn't there)
      # Also ignore the package cache so the old info isn't used
      return getDownloadInfo(pv, options, false, true)
    else:
      raise newNimbleError[PackageNotFoundError](pkgNotFoundMsg(pv))

when isMainModule:
  import unittest

  suite "version sorting":
    test "pre-release versions":
      let data = @["v9.0.0-taeyeon", "v9.0.1-jessica", "v9.2.0-sunny",
                   "v9.4.0-tiffany", "v9.4.2-hyoyeon"]
      let expected = toOrderedTable[Version, string]({
        newVersion("9.4.2-hyoyeon"): "v9.4.2-hyoyeon",
        newVersion("9.4.0-tiffany"): "v9.4.0-tiffany",
        newVersion("9.2.0-sunny"): "v9.2.0-sunny",
        newVersion("9.0.1-jessica"): "v9.0.1-jessica",
        newVersion("9.0.0-taeyeon"): "v9.0.0-taeyeon"})
      check getVersionList(data) == expected

    test "release versions":
      let data = @["v0.1.0", "v0.1.1", "v0.2.0",
                   "0.4.0", "v0.4.2"]
      let expected = toOrderedTable[Version, string]({
        newVersion("0.4.2"): "v0.4.2",
        newVersion("0.4.0"): "0.4.0",
        newVersion("0.2.0"): "v0.2.0",
        newVersion("0.1.1"): "v0.1.1",
        newVersion("0.1.0"): "v0.1.0",})
      check getVersionList(data) == expected

  suite "getDevelopDownloadDir":
    let dummyOptionsWithoutPath = Options(action: Action(typ: actionDevelop))
    let dummyOptionsWithAbsolutePath = Options(
      action: Action(typ: actionDevelop, path: "/some/dir/"))
    let dummyOptionsWithRelativePath = Options(
      action: Action(typ: actionDevelop, path: "some/dir/"))

    test "without subdir and without path":
      check getDevelopDownloadDir(
        "https://github.com/nimble-test/packagea/", "",
        dummyOptionsWithoutPath) == getCurrentDir() / "packagea"

    test "without subdir and with absolute path":
      check getDevelopDownloadDir(
        "https://github.com/nimble-test/packagea", "",
        dummyOptionsWithAbsolutePath) == "/some/dir/packagea".normalizedPath

    test "without subdir and with relative path":
      check getDevelopDownloadDir(
        "https://github.com/nimble-test/packagea/", "",
        dummyOptionsWithRelativePath) == getCurrentDir() / "some/dir/packagea"

    test "with subdir and without path":
      check getDevelopDownloadDir(
        "https://github.com/nimble-test/multi", "beta",
        dummyOptionsWithoutPath) == getCurrentDir() / "beta"

    test "with subdir and with absolute path":
      check getDevelopDownloadDir(
        "https://github.com/nimble-test/multi/", "alpha/",
        dummyOptionsWithAbsolutePath) == "/some/dir/alpha".normalizedPath

    test "with subdir and with relative path":
      check getDevelopDownloadDir(
        "https://github.com/nimble-test/multi", "alpha/",
        dummyOptionsWithRelativePath) == getCurrentDir() / "some/dir/alpha"

export urls
