# Copyright (C) Andreas Rumpf. All rights reserved.
# BSD License. Look at license.txt for more info.

## Implements 'nimble publish' to create a pull request against
## nim-lang/packages automatically.

import system except TResult
import httpclient, base64, strutils, rdstdin, json, os, browsers, times, uri
import tools, common, cli

type
  Auth = object
    user: string
    pw: string
    token: string  ## base64 encoding of user:pw

proc userAborted() =
  raise newException(NimbleError, "User aborted the process.")

proc createHeaders(a: Auth): string =
  (("Authorization: token $1\c\L" % a.token) &
          "Content-Type: application/x-www-form-urlencoded\c\L" &
          "Accept: */*\c\L")

proc getGithubAuth(): Auth =
  display("Info:", "Please create a new personal access token on Github in" &
         " order to allow Nimble to fork the packages repository.",
         priority = HighPriority)
  display("Hint:", "Make sure to give the access token access to public repos" &
          " (public_repo scope)!", Warning, HighPriority)
  sleep(5000)
  display("Info:", "Your default browser should open with the following URL: " &
          "https://github.com/settings/tokens/new", priority = HighPriority)
  sleep(3000)
  openDefaultBrowser("https://github.com/settings/tokens/new")
  result.token = promptCustom("Personal access token?", "").strip()
  let resp = getContent("https://api.github.com/user",
        extraHeaders=createHeaders(result)).parseJson()

  result.user = resp["login"].str
  display("Success:", "Verified as " & result.user, Success, HighPriority)

proc isCorrectFork(j: JsonNode): bool =
  # Check whether this is a fork of the nimble packages repo.
  result = false
  if j{"fork"}.getBVal():
    result = j{"parent"}{"full_name"}.getStr() == "nim-lang/packages"

proc forkExists(a: Auth): bool =
  try:
    let x = getContent("https://api.github.com/repos/" & a.user & "/packages",
        extraHeaders=createHeaders(a))
    let j = parseJson(x)
    result = isCorrectFork(j)
  except JsonParsingError, IOError:
    result = false

proc createFork(a: Auth) =
  try:
    discard postContent("https://api.github.com/repos/nim-lang/packages/forks",
        extraHeaders=createHeaders(a))
  except HttpRequestError:
    raise newException(NimbleError, "Unable to create fork. Access token" &
                       " might not have enough permissions.")

proc createPullRequest(a: Auth, packageName, branch: string) =
  display("Info", "Creating PR", priority = HighPriority)
  discard postContent("https://api.github.com/repos/nim-lang/packages/pulls",
      extraHeaders=createHeaders(a),
      body="""{"title": "Add package $1", "head": "$2:$3",
               "base": "master"}""" % [packageName, a.user, branch])

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
  contents.add(%{
    "name": %p.name,
    "url": %url,
    "method": %downloadMethod,
    "tags": %tags.split(),
    "description": %p.description,
    "license": %p.license,
    "web": %url})
  writeFile("packages.json", contents.pretty.cleanupWhitespace)

proc getPackageOriginUrl(a: Auth): string =
  ## Adds 'user:pw' to the URL so that the user is not asked *again* for it.
  ## We need this for 'git push'.
  let (output, exitCode) = doCmdEx("git ls-remote --get-url")
  result = "origin"
  if exitCode == 0:
    result = output.string.strip
    if result.endsWith(".git"): result.setLen(result.len - 4)
    if result.startsWith("https://"):
      result = "https://" & a.user & ':' & a.pw & '@' &
          result["https://".len .. ^1]

proc publish*(p: PackageInfo) =
  ## Publishes the package p.
  let auth = getGithubAuth()
  var pkgsDir = getTempDir() / "nimble-packages-fork"
  if not forkExists(auth):
    createFork(auth)
    display("Info:", "Waiting 10s to let Github create a fork",
            priority = HighPriority)
    os.sleep(10_000)

    display("Info:", "Finished waiting", priority = LowPriority)
  if dirExists(pkgsDir):
    display("Removing", "old packages fork git directory.",
            priority = LowPriority)
    removeDir(pkgsDir)
  display("Cloning", "packages into: " & pkgsDir, priority = HighPriority)
  doCmd("git clone git@github.com:" & auth.user & "/packages " & pkgsDir)
  # Make sure to update the clone.
  display("Updating", "the fork", priority = HighPriority)
  cd pkgsDir:
    doCmd("git pull https://github.com/nim-lang/packages.git master")
    doCmd("git push origin master")

  if not dirExists(pkgsDir):
    raise newException(NimbleError,
        "Cannot find nimble-packages-fork git repository. Cloning failed.")

  if not fileExists(pkgsDir / "packages.json"):
    raise newException(NimbleError,
        "No packages file found in cloned fork.")

  # We need to do this **before** the cd:
  # Determine what type of repo this is.
  var url = ""
  var downloadMethod = ""
  if dirExists(os.getCurrentDir() / ".git"):
    let (output, exitCode) = doCmdEx("git config --get remote.origin.url")
    if exitCode == 0:
      url = output.string.strip
      if url.endsWith(".git"): url.setLen(url.len - 4)
      downloadMethod = "git"
    let parsed = parseUri(url)
    if parsed.scheme == "":
      # Assuming that we got an ssh write/read URL.
      let sshUrl = parseUri("ssh://" & url)
      url = "https://github.com/" & sshUrl.port & sshUrl.path
  elif dirExists(os.getCurrentDir() / ".hg"):
    downloadMethod = "hg"
    # TODO: Retrieve URL from hg.
  else:
    raise newException(NimbleError,
         "No .git nor .hg directory found. Stopping.")

  if url.len == 0:
    url = promptCustom("Github URL of " & p.name & "?", "")
    if url.len == 0: userAborted()

  let tags = promptCustom("Whitespace separated list of tags?", "")

  cd pkgsDir:
    editJson(p, url, tags, downloadMethod)
    let branchName = "add-" & p.name & getTime().getGMTime().format("HHmm")
    doCmd("git checkout -B " & branchName)
    doCmd("git commit packages.json -m \"Added package " & p.name & "\"")
    display("Pushing", "to remote of fork.", priority = HighPriority)
    doCmd("git push " & getPackageOriginUrl(auth) & " " & branchName)
    createPullRequest(auth, p.name, branchName)
  display("Success:", "Pull request successful.", Success, HighPriority)

when isMainModule:
  import packageinfo
  var p = getPkgInfo(getCurrentDir())
  publish(p)
