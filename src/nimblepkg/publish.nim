# Copyright (C) Andreas Rumpf. All rights reserved.
# BSD License. Look at license.txt for more info.

## Implements 'nimble publish' to create a pull request against
## nim-lang/packages automatically.

import system except TResult
import httpclient, strutils, json, os, browsers, times, uri
import common, tools, cli, config, options, packageinfotypes, vcstools, sha1hashes, version, download
import strformat, sequtils, pegs, sets, tables, algorithm
{.warning[UnusedImport]: off.}
from net import SslCVerifyMode, newContext

type
  Auth = object
    user: string
    token: string  ## GitHub access token
    http: HttpClient ## http client for doing API requests

const
  ApiKeyFile = "github_api_token"
  ApiTokenEnvironmentVariable = "NIMBLE_GITHUB_API_TOKEN"
  ReposUrl = "https://api.github.com/repos/"
  defaultBranch = "master" # Default branch on https://github.com/nim-lang/packages

proc userAborted() =
  raise nimbleError("User aborted the process.")

proc createHeaders(a: Auth) =
  a.http.headers = newHttpHeaders({
    "Authorization": "token $1" % a.token,
    "Content-Type": "application/x-www-form-urlencoded",
    "Accept": "*/*"
  })

proc requestNewToken(cfg: Config): string =
  display("Info:", "Please create a new personal access token on GitHub in" &
          " order to allow Nimble to fork the packages repository.",
          priority = HighPriority)
  display("Hint:", "Make sure to give the access token access to public repos" &
          " (public_repo scope)!", Warning, HighPriority)
  sleep(5000)
  display("Info:", "Your default browser should open with the following URL: " &
          "https://github.com/settings/tokens/new", priority = HighPriority)
  sleep(3000)
  openDefaultBrowser("https://github.com/settings/tokens/new")
  let token = promptCustom("Personal access token?", "").strip()
  # inform the user that their token will be written to disk
  let tokenWritePath = cfg.nimbleDir / ApiKeyFile
  display("Info:", "Writing access token to file:" & tokenWritePath,
          priority = HighPriority)
  writeFile(tokenWritePath, token)
  sleep(3000)
  return token

proc getGithubAuth(o: Options): Auth =
  let cfg = o.config
  let ctx = newSSLContext(o.disableSslCertCheck)
  result.http = newHttpClient(proxy = getProxy(o), sslContext = ctx)
  # always prefer the environment variable to asking for a new one
  if existsEnv(ApiTokenEnvironmentVariable):
    result.token = getEnv(ApiTokenEnvironmentVariable)
    display("Info:", "Using the '" & ApiTokenEnvironmentVariable &
            "' environment variable for the GitHub API Token.",
            priority = HighPriority)
  else:
    # try to read from disk, if it cannot be found write a new one
    try:
      let apiTokenFilePath = cfg.nimbleDir / ApiKeyFile
      result.token = readFile(apiTokenFilePath).strip()
      display("Info:", "Using GitHub API Token in file: " & apiTokenFilePath,
              priority = HighPriority)
    except IOError:
      result.token = requestNewToken(cfg)
  createHeaders(result)
  let resp = result.http.getContent("https://api.github.com/user").parseJson()

  result.user = resp["login"].str
  display("Success:", "Verified as " & result.user, Success, HighPriority)

proc isCorrectFork(j: JsonNode): bool =
  # Check whether this is a fork of the nimble packages repo.
  result = false
  if j{"fork"}.getBool():
    result = j{"parent"}{"full_name"}.getStr() == "nim-lang/packages"

proc forkExists(a: Auth): bool =
  try:
    let x = a.http.getContent(ReposUrl & a.user & "/packages")
    let j = parseJson(x)
    result = isCorrectFork(j)
  except JsonParsingError, IOError:
    result = false

proc createFork(a: Auth) =
  try:
    discard a.http.postContent(ReposUrl & "nim-lang/packages/forks")
  except HttpRequestError:
    raise nimbleError("Unable to create fork. Access token" &
                       " might not have enough permissions.")

proc createPullRequest(a: Auth, pkg: PackageInfo, url, branch: string): string =
  display("Info", "Creating PR", priority = HighPriority)
  let payload = %* {
      "title": &"Add package {pkg.basicInfo.name}",
      "head": &"{a.user}:{branch}",
      "base": defaultBranch,
      "body": &"{pkg.description}\n\n{url}"
  }
  var body = a.http.postContent(ReposUrl & "nim-lang/packages/pulls", $payload)
  var pr = parseJson(body)
  return pr{"html_url"}.getStr()

proc `%`(s: openArray[string]): JsonNode =
  result = newJArray()
  for x in s: result.add(%x)

proc cleanupWhitespace(s: string): string =
  ## Removes trailing whitespace and normalizes line endings to LF.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == ' ':
      var j = i+1
      while s[j] == ' ': inc j
      if s[j] == '\c':
        inc j
        if s[j] == '\L': inc j
        result.add '\L'
        i = j
      elif s[j] == '\L':
        result.add '\L'
        i = j+1
      else:
        result.add ' '
        inc i
    elif s[i] == '\c':
      inc i
      if s[i] == '\L': inc i
      result.add '\L'
    elif s[i] == '\L':
      result.add '\L'
      inc i
    else:
      result.add s[i]
      inc i
  if result[^1] != '\L':
    result.add '\L'

proc editJson(p: PackageInfo; url, tags, downloadMethod: string) =
  var contents = parseFile("packages.json")
  doAssert contents.kind == JArray
  contents.add(%*{
    "name": p.basicInfo.name,
    "url": url,
    "method": downloadMethod,
    "tags": tags.splitWhitespace(),
    "description": p.description,
    "license": p.license,
    "web": url
  })
  writeFile("packages.json", contents.pretty.cleanupWhitespace)

proc publish*(p: PackageInfo, o: Options) =
  ## Publishes the package p.
  let auth = getGithubAuth(o)
  var pkgsDir = getNimbleUserTempDir() / "nimble-packages-fork"
  if not forkExists(auth):
    createFork(auth)
    display("Info:", "Waiting 10s to let GitHub create a fork",
            priority = HighPriority)
    os.sleep(10_000)

    display("Info:", "Finished waiting", priority = LowPriority)
  if dirExists(pkgsDir):
    display("Removing", "old packages fork git directory.",
            priority = LowPriority)
    removeDir(pkgsDir)
  createDir(pkgsDir)
  cd pkgsDir:
    # Avoid git clone to prevent token from being stored in repo
    # https://github.com/blog/1270-easier-builds-and-deployments-using-git-over-https-and-oauth
    display("Copying", "packages fork into: " & pkgsDir, priority = HighPriority)
    doCmd("git init")
    # The repo will have 0 branches created at this point. So the
    # below command will always work.
    doCmd("git checkout -b " & defaultBranch)
    doCmd("git pull https://github.com/" & auth.user & "/packages")
    # Make sure to update the fork
    display("Updating", "the fork", priority = HighPriority)
    doCmd("git pull https://github.com/nim-lang/packages.git " & defaultBranch)
    doCmd("git push https://" & auth.token & "@github.com/" & auth.user & "/packages " & defaultBranch)

  if not dirExists(pkgsDir):
    raise nimbleError(
        "Cannot find nimble-packages-fork git repository. Cloning failed.")

  if not fileExists(pkgsDir / "packages.json"):
    raise nimbleError(
        "No packages file found in cloned fork.")

  # We need to do this **before** the cd:
  # Determine what type of repo this is.
  var url = ""
  var downloadMethod = ""
  if dirExists(os.getCurrentDir() / ".git"):
    let (output, exitCode) = doCmdEx("git ls-remote --get-url")
    if exitCode == 0:
      url = output.strip
      if url.endsWith(".git"): url.setLen(url.len - 4)
      downloadMethod = "git"
    let parsed = parseUri(url)

    if parsed.scheme == "":
      # Assuming that we got an ssh write/read URL.
      let sshUrl = parseUri("ssh://" & url)
      url = "https://" & sshUrl.hostname & "/" & sshUrl.port & sshUrl.path
    elif parsed.username != "" or parsed.password != "":
      # check for any confidential information
      # TODO: Use raiseNimbleError(msg, hintMsg) here
      raise nimbleError(
        "Cannot publish the repository URL because it contains username " &
        "and/or password. Fix the remote URL. Hint: \"git remote -v\"")

  elif dirExists(os.getCurrentDir() / ".hg"):
    downloadMethod = "hg"
    # TODO: Retrieve URL from hg.
  else:
    raise nimbleError(
         "No .git nor .hg directory found. Stopping.")

  if url.len == 0:
    url = promptCustom("GitHub URL of " & p.basicInfo.name & "?", "")
    if url.len == 0: userAborted()

  let tags = promptCustom(
    "Whitespace separated list of tags? (For example: web library wrapper)",
    ""
  )

  cd pkgsDir:
    editJson(p, url, tags, downloadMethod)
    let branchName = "add-" & p.basicInfo.name & getTime().utc.format("HHmm")
    doCmd("git checkout -B " & branchName)
    doCmd("git commit packages.json -m \"Added package " & p.basicInfo.name & "\"")
    display("Pushing", "to remote of fork.", priority = HighPriority)
    doCmd("git push https://" & auth.token & "@github.com/" & auth.user & "/packages " & branchName)
    let prUrl = createPullRequest(auth, p, url, branchName)
    display("Success:", "Pull request successful, check at " & prUrl , Success, HighPriority)

proc createTag*(tag: string, commit: Sha1Hash, message, repoDir, nimbleFile: string, downloadMethod: DownloadMethod): bool =
  case downloadMethod:
    of DownloadMethod.git:
      let (output, code) = doCmdEx(&"git -C {repoDir} tag -a {tag.quoteShell()} {commit} -m {message.quoteShell()}")
      result = code == QuitSuccess
      if not result:
        displayError(&"Failed to create tag {tag.quoteShell()} with error {output}")
    of DownloadMethod.hg:
      assert false, "hg not supported"
  
proc pushTags*(tags: seq[string], repoDir: string, downloadMethod: DownloadMethod): bool =
  case downloadMethod:
    of DownloadMethod.git:
      # git push origin tag experiment-0.8.1
      let tags = tags.mapIt(it.quoteShell()).join(" ")
      let (output, code) = doCmdEx(&"git -C {repoDir} push origin tag {tags} ")
      result = code == QuitSuccess
      if not result:
        displayError(&"Failed to push tag {tags} with error {output}")
    of DownloadMethod.hg:
      assert false, "hg not supported"
  
const TagVersionFmt = "v$1"

proc findVersions(commits: seq[(Sha1Hash, string)], projdir, nimbleFile: string, downloadMethod: DownloadMethod, options: Options) =
  ## parse the versions
  var
    versions: OrderedTable[Version, tuple[commit: Sha1Hash, message: string]]
    existingTags = gitTagCommits(projdir, downloadMethod)
    existingVers = existingTags.keys().toSeq().getVersionList()

  let currBranch = getCurrentBranch(projdir)
  if currBranch notin ["main", "master"]:
    displayWarning(&"Note runnig this command on a non-standard primary branch `{currBranch}` may have unintened consequences", HighPriority)

  for ver, tag in existingVers.pairs():
    let commit = existingTags[tag]
    displayInfo(&"Existing version {ver} with tag {tag} at commit {$commit} ", HighPriority)

  # adapted from @beef331's algorithm https://github.com/beef331/graffiti/blob/master/src/graffiti.nim
  block outer:
    for (commit, message) in commits:
      # echo "commit: ", commit
      let diffs = vcsDiff(commit, projdir, nimbleFile, downloadMethod)
      for line in diffs:
        var matches: array[0..MaxSubpatterns, string]
        if line.find(peg"'+version' \s* '=' \s* {[\34\39]} {@} $1", matches) > -1:
          let ver = newVersion(matches[1])
          if ver notin versions:
            if ver in existingVers:
              if options.action.allTags:
                displayWarning(&"Skipping historical version {ver} at commit {commit} that has an existing tag", HighPriority)
              else:
                break outer
            else:
              displayInfo(&"Found new version {ver} at {commit}", HighPriority)
              versions[ver] = (commit: commit, message: message)

  var nonMonotonicVers: Table[Version, Sha1Hash]
  if versions.len() >= 2:
    let versions = versions.pairs().toSeq()
    var monotonics: seq[Version]
    for idx in 1 ..< versions.len() - 1:
      let
        prev = versions[idx-1]
        (ver, info) = versions[idx]
        prevMonotonicsOk = monotonics.mapIt(ver < it).all(proc (x: bool): bool = x)

      if ver < prev[0] and prevMonotonicsOk:
        displayHint(&"Versions monotonic between tag {TagVersionFmt % $ver}@{info.commit} " &
                      &" and previous tag of {TagVersionFmt % $prev[0]}@{prev[1].commit}", MediumPriority)
      else:
        if prev[0] notin nonMonotonicVers:
          monotonics.add(prev[0]) # track last largest monotonic so we can check, e.g. 0.2, 3.0, 0.3 and not 0.2, 3.0, 0.2 
        nonMonotonicVers[ver] = info.commit
        displayError(&"Non-monotonic (decreasing) version found between tag {TagVersionFmt % $ver}@{info.commit}" &
                     &" and the previous tag {TagVersionFmt % $prev[0]}@{prev[1].commit}", HighPriority)
        displayWarning(&"Version {ver} will be skipped. Please tag it manually if the version is correct." , HighPriority)
        displayHint(&"Note that versions are checked from larget to smallest" , HighPriority)
        displayHint(&"Note smaller versions later in history are always peferred. Please manually review your tags before pushing." , HighPriority)

  var newTags: HashSet[string]
  if options.action.createTags:
    for (version, info) in versions.pairs:
      if version in nonMonotonicVers:
        displayWarning(&"Skipping creating tag for non-monotonic {version} at {info.commit}", HighPriority)
      else:
        let tag = TagVersionFmt % [$version]
        displayWarning(&"Creating tag for new version {version} at {info.commit}", HighPriority)
        let res = createTag(tag, info.commit, info.message, projdir, nimbleFile, downloadMethod)
        if not res:
          displayError(&"Unable to create tag {TagVersionFmt % $version}", HighPriority)
        else:
          newTags.incl(tag)

  if options.action.pushTags:
    let res = pushTags(newTags.toSeq(), projdir, downloadMethod)
    if not res:
      displayError(&"Error pushing tags", HighPriority)

proc publishVersions*(p: PackageInfo, options: Options) =
  displayInfo(&"Searcing for new tags for {$p.basicInfo.name} @{$p.basicInfo.version}", HighPriority)
  let (projdir, file, ext) = p.myPath.splitFile()
  let nimblefile = file & ext
  let dlmethod = p.metadata.downloadMethod
  let commits = vcsFindCommits(projdir, nimbleFile, dlmethod)

  findVersions(commits, projdir, nimbleFile, dlmethod, options)
