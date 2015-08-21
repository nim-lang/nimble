# Copyright (C) Andreas Rumpf. All rights reserved.
# BSD License. Look at license.txt for more info.

## Implements 'nimble publish' to create a pull request against
## nim-lang/packages automatically.

import httpclient, base64, strutils, rdstdin, json, os, browsers
import tools, nimbletypes

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
  echo("Please create a new personal access token on Github in order to " &
      "allow Nimble to fork the packages repository.")
  sleep(5000)
  echo("Your default browser should open with the following URL: " &
      "https://github.com/settings/tokens/new")
  sleep(3000)
  openDefaultBrowser("https://github.com/settings/tokens/new")
  result.token = readLineFromStdin("Personal access token: ").strip()
  let resp = getContent("https://api.github.com/user",
        extraHeaders=createHeaders(result)).parseJson()

  result.user = resp["login"].str
  echo("Successfully verified as ", result.user)

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
  discard postContent("https://api.github.com/repos/nim-lang/packages/forks",
      extraHeaders=createHeaders(a))

proc createPullRequest(a: Auth; packageName: string) =
  echo("Creating PR")
  discard postContent("https://api.github.com/repos/nim-lang/packages/pulls",
      extraHeaders=createHeaders(a),
      body="""{"title": "Add package $#", "head": "$#:master",
               "base": "master"}""" % [packageName, a.user])

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
  let (output, exitCode) = doCmdEx("git config --get remote.origin.url")
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
  let parent = os.getCurrentDir().parentDir()
  var pkgsDir = parent / "nimble-packages-fork"
  if not forkExists(auth):
    createFork(auth)
    echo "waiting 10s to let Github create a fork ..."
    os.sleep(10_000)
    if dirExists(pkgsDir):
      pkgsDir = readLineFromStdin("Directory where to clone into: ")
      if pkgsDir.len == 0: userAborted()
    echo "... done; cloning packages into: ", pkgsDir
    cd parent:
      doCmd("git clone https://github.com/" & auth.user & "/packages " & pkgsDir)
      # Use SSH instead of HTTPS so that the user isn't bothered with the
      # password for 'git push':
      doCmd("git remote set-url origin git@github.com:$1/packages.git" %
           auth.user)
  elif not dirExists(pkgsDir):
    pkgsDir = readLineFromStdin("According to github, you already forked " &
                                "nim-lang/packages.\n" &
                                "Please give the path to it: ")
    if pkgsDir.len == 0: userAborted()
  if not dirExists(pkgsDir):
    raise newException(NimbleError,
         "Cannot find nimble-packages-fork git repository. Stopping.")

  # We need to do this **before** the cd:
  var url = ""
  var downloadMethod = ""
  if dirExists(os.getCurrentDir() / ".git"):
    let (output, exitCode) = doCmdEx("git config --get remote.origin.url")
    if exitCode == 0:
      url = output.string.strip
      if url.endsWith(".git"): url.setLen(url.len - 4)
      downloadMethod = "git"
  elif dirExists(os.getCurrentDir() / ".hg"):
    downloadMethod = "hg"
  else:
    raise newException(NimbleError,
         "No .git nor .hg directory found. Stopping.")

  if url.len == 0:
    url = readLineFromStdin("Github URL of " & p.name & ": ")
    if url.len == 0: userAborted()

  let tags = readLineFromStdin("Please enter a whitespace separated list of tags: ")

  cd pkgsDir:
    editJson(p, url, tags, downloadMethod)
    doCmd("git commit packages.json -m \"Added package " & p.name & "\"")
    echo pkgsDir, " git push origin master"
    doCmd("git push " & getPackageOriginUrl(auth) & " master")
    createPullRequest(auth, p.name)
  echo "Pull request successful."

when isMainModule:
  import packageinfo
  var p = getPkgInfo(getCurrentDir())
  publish(p)
