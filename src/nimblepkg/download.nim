# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import parseutils, os, osproc, strutils, tables, pegs

import packageinfo, packageparser, version, tools, common, options

type
  DownloadMethod* {.pure.} = enum
    git = "git", hg = "hg"

proc getSpecificDir(meth: DownloadMethod): string =
  case meth
  of DownloadMethod.git:
    ".git"
  of DownloadMethod.hg:
    ".hg"

proc doCheckout(meth: DownloadMethod, downloadDir, branch: string) =
  case meth
  of DownloadMethod.git:
    cd downloadDir:
      # Force is used here because local changes may appear straight after a
      # clone has happened. Like in the case of git on Windows where it
      # messes up the damn line endings.
      doCmd("git checkout --force " & branch)
  of DownloadMethod.hg:
    cd downloadDir:
      doCmd("hg checkout " & branch)

proc doPull(meth: DownloadMethod, downloadDir: string) =
  case meth
  of DownloadMethod.git:
    doCheckout(meth, downloadDir, "")
    cd downloadDir:
      doCmd("git pull")
      if existsFile(".gitmodules"):
        doCmd("git submodule update")
  of DownloadMethod.hg:
    doCheckout(meth, downloadDir, "default")
    cd downloadDir:
      doCmd("hg pull")

proc doClone(meth: DownloadMethod, url, downloadDir: string, branch = "",
            tip = true) =
  case meth
  of DownloadMethod.git:
    let
      depthArg = if tip: "--depth 1 " else: ""
      branchArg = if branch == "": "" else: "-b " & branch & " "
    doCmd("git clone --recursive " & depthArg & branchArg & url &
          " " & downloadDir)
  of DownloadMethod.hg:
    let
      tipArg = if tip: "-r tip " else: ""
      branchArg = if branch == "": "" else: "-b " & branch & " "
    doCmd("hg clone " & tipArg & branchArg & url & " " & downloadDir)

proc getTagsList(dir: string, meth: DownloadMethod): seq[string] =
  cd dir:
    var output = execProcess("git tag")
    case meth
    of DownloadMethod.git:
      output = execProcess("git tag")
    of DownloadMethod.hg:
      output = execProcess("hg tags")
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
    var (output, exitCode) = doCmdEx("git ls-remote --tags " & url)
    if exitCode != QuitSuccess:
      raise newException(OSError, "Unable to query remote tags for " & url &
          ". Git returned: " & output)
    for i in output.splitLines():
      if i == "": continue
      let start = i.find("refs/tags/")+"refs/tags/".len
      let tag = i[start .. i.len-1]
      if not tag.endswith("^{}"): result.add(tag)

  of DownloadMethod.hg:
    # http://stackoverflow.com/questions/2039150/show-tags-for-remote-hg-repository
    raise newException(ValueError, "Hg doesn't support remote tag querying.")

proc getVersionList*(tags: seq[string]): Table[Version, string] =
  # Returns: TTable of version -> git tag name
  result = initTable[Version, string]()
  for tag in tags:
    if tag != "":
      let i = skipUntil(tag, Digits) # skip any chars before the version
      # TODO: Better checking, tags can have any names. Add warnings and such.
      result[newVersion(tag[i .. tag.len-1])] = tag

proc getDownloadMethod*(meth: string): DownloadMethod =
  case meth
  of "git": return DownloadMethod.git
  of "hg", "mercurial": return DownloadMethod.hg
  else:
    raise newException(NimbleError, "Invalid download method: " & meth)

proc getHeadName*(meth: DownloadMethod): string =
  ## Returns the name of the download method specific head. i.e. for git
  ## it's ``head`` for hg it's ``tip``.
  case meth
  of DownloadMethod.git: "head"
  of DownloadMethod.hg: "tip"

proc checkUrlType*(url: string): DownloadMethod =
  ## Determines the download method based on the URL.
  if doCmdEx("git ls-remote " & url).exitCode == QuitSuccess:
    return DownloadMethod.git
  elif doCmdEx("hg identify " & url).exitCode == QuitSuccess:
    return DownloadMethod.hg
  else:
    raise newException(NimbleError, "Unable to identify url.")

proc isURL*(name: string): bool =
  name.startsWith(peg" @'://' ")

proc doDownload*(url: string, downloadDir: string, verRange: VersionRange,
                 downMethod: DownloadMethod, options: Options): VersionRange =
  ## Downloads the repository specified by ``url`` using the specified download
  ## method.
  ##
  ## Returns the version of the repository which has been downloaded.
  template getLatestByTag(meth: stmt): stmt {.dirty, immediate.} =
    echo("Found tags...")
    # Find latest version that fits our ``verRange``.
    var latest = findLatest(verRange, versions)
    ## Note: HEAD is not used when verRange.kind is verAny. This is
    ## intended behaviour, the latest tagged version will be used in this case.

    # If no tagged versions satisfy our range latest.tag will be "".
    # We still clone in that scenario because we want to try HEAD in that case.
    # https://github.com/nimrod-code/nimble/issues/22
    meth
    if $latest.ver != "":
      result = parseVersionRange($latest.ver)
    else:
      # Result should already be set to #head here.
      assert(not result.isNil)

  proc verifyClone() =
    ## Makes sure that the downloaded package's version satisfies the requested
    ## version range.
    let pkginfo = getPkgInfo(downloadDir, options)
    if pkginfo.version.newVersion notin verRange:
      raise newException(NimbleError,
        "Downloaded package's version does not satisfy requested version " &
        "range: wanted $1 got $2." %
        [$verRange, $pkginfo.version])

  removeDir(downloadDir)
  if verRange.kind == verSpecial:
    # We want a specific commit/branch/tag here.
    if verRange.spe == newSpecial(getHeadName(downMethod)):
      doClone(downMethod, url, downloadDir) # Grab HEAD.
    else:
      # Grab the full repo.
      doClone(downMethod, url, downloadDir, tip = false)
      # Then perform a checkout operation to get the specified branch/commit.
      doCheckout(downMethod, downloadDir, $verRange.spe)
    result = verRange
  else:
    case downMethod
    of DownloadMethod.git:
      # For Git we have to query the repo remotely for its tags. This is
      # necessary as cloning with a --depth of 1 removes all tag info.
      result = parseVersionRange("#head")
      let versions = getTagsListRemote(url, downMethod).getVersionList()
      if versions.len > 0:
        getLatestByTag:
          echo("Cloning latest tagged version: ", latest.tag)
          doClone(downMethod, url, downloadDir, latest.tag)
      else:
        # If no commits have been tagged on the repo we just clone HEAD.
        doClone(downMethod, url, downloadDir) # Grab HEAD.

      verifyClone()
    of DownloadMethod.hg:
      doClone(downMethod, url, downloadDir)
      result = parseVersionRange("#tip")
      let versions = getTagsList(downloadDir, downMethod).getVersionList()

      if versions.len > 0:
        getLatestByTag:
          echo("Switching to latest tagged version: ", latest.tag)
          doCheckout(downMethod, downloadDir, latest.tag)

      verifyClone()

proc echoPackageVersions*(pkg: Package) =
  let downMethod = pkg.downloadMethod.getDownloadMethod()
  case downMethod
  of DownloadMethod.git:
    try:
      let versions = getTagsListRemote(pkg.url, downMethod).getVersionList()
      if versions.len > 0:
        var vstr = ""
        var i = 0
        for v in values(versions):
          if i != 0:
            vstr.add(", ")
          vstr.add(v)
          i.inc
        echo("  versions:    " & vstr)
      else:
        echo("  versions:    (No versions tagged in the remote repository)")
    except OSError:
      echo(getCurrentExceptionMsg())
  of DownloadMethod.hg:
    echo("  versions:    (Remote tag retrieval not supported by " &
        pkg.downloadMethod & ")")
