# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import parseutils, os, osproc, strutils, tables, pegs, uri
import packageinfo, packageparser, version, tools, common, options, cli
from algorithm import SortOrder, sorted
from sequtils import toSeq, filterIt, map

type
  DownloadMethod* {.pure.} = enum
    git = "git", hg = "hg"

proc getSpecificDir(meth: DownloadMethod): string {.used.} =
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
      doCmd("git submodule update --recursive --depth 1")
  of DownloadMethod.hg:
    cd downloadDir:
      doCmd("hg checkout " & branch)

proc doPull(meth: DownloadMethod, downloadDir: string) {.used.} =
  case meth
  of DownloadMethod.git:
    doCheckout(meth, downloadDir, "")
    cd downloadDir:
      doCmd("git pull")
      if fileExists(".gitmodules"):
        doCmd("git submodule update --recursive --depth 1")
  of DownloadMethod.hg:
    doCheckout(meth, downloadDir, "default")
    cd downloadDir:
      doCmd("hg pull")

proc doClone(meth: DownloadMethod, url, downloadDir: string, branch = "",
             onlyTip = true) =
  case meth
  of DownloadMethod.git:
    let
      depthArg = if onlyTip: "--depth 1 " else: ""
      branchArg = if branch == "": "" else: "-b " & branch & " "
    doCmd("git clone --recursive " & depthArg & branchArg &
          url & " " & downloadDir)
  of DownloadMethod.hg:
    let
      tipArg = if onlyTip: "-r tip " else: ""
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
    var (output, exitCode) = doCmdEx("git ls-remote --tags " & url.quoteShell())
    if exitCode != QuitSuccess:
      raise newException(OSError, "Unable to query remote tags for " & url &
          ". Git returned: " & output)
    for i in output.splitLines():
      let refStart = i.find("refs/tags/")
      # git outputs warnings, empty lines, etc
      if refStart == -1: continue
      let start = refStart+"refs/tags/".len
      let tag = i[start .. i.len-1]
      if not tag.endswith("^{}"): result.add(tag)

  of DownloadMethod.hg:
    # http://stackoverflow.com/questions/2039150/show-tags-for-remote-hg-repository
    raise newException(ValueError, "Hg doesn't support remote tag querying.")

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

proc getDownloadMethod*(meth: string): DownloadMethod =
  case meth
  of "git": return DownloadMethod.git
  of "hg", "mercurial": return DownloadMethod.hg
  else:
    raise newException(NimbleError, "Invalid download method: " & meth)

proc getHeadName*(meth: DownloadMethod): Version =
  ## Returns the name of the download method specific head. i.e. for git
  ## it's ``head`` for hg it's ``tip``.
  case meth
  of DownloadMethod.git: newVersion("#head")
  of DownloadMethod.hg: newVersion("#tip")

proc checkUrlType*(url: string): DownloadMethod =
  ## Determines the download method based on the URL.
  if doCmdEx("git ls-remote " & url.quoteShell()).exitCode == QuitSuccess:
    return DownloadMethod.git
  elif doCmdEx("hg identify " & url.quoteShell()).exitCode == QuitSuccess:
    return DownloadMethod.hg
  else:
    raise newException(NimbleError, "Unable to identify url: " & url)

proc getUrlData*(url: string): (string, Table[string, string]) =
  var uri = parseUri(url)
  # TODO: use uri.parseQuery once it lands... this code is quick and dirty.
  var subdir = ""
  if uri.query.startsWith("subdir="):
    subdir = uri.query[7 .. ^1]

  uri.query = ""
  return ($uri, {"subdir": subdir}.toTable())

proc isURL*(name: string): bool =
  name.startsWith(peg" @'://' ")

proc doDownload(url: string, downloadDir: string, verRange: VersionRange,
                 downMethod: DownloadMethod,
                 options: Options): Version =
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
      result = latest.ver

  removeDir(downloadDir)
  if verRange.kind == verSpecial:
    # We want a specific commit/branch/tag here.
    if verRange.spe == getHeadName(downMethod):
       # Grab HEAD.
      doClone(downMethod, url, downloadDir, onlyTip = not options.forceFullClone)
    else:
      # Grab the full repo.
      doClone(downMethod, url, downloadDir, onlyTip = false)
      # Then perform a checkout operation to get the specified branch/commit.
      # `spe` starts with '#', trim it.
      doAssert(($verRange.spe)[0] == '#')
      doCheckout(downMethod, downloadDir, substr($verRange.spe, 1))
    result = verRange.spe
  else:
    case downMethod
    of DownloadMethod.git:
      # For Git we have to query the repo remotely for its tags. This is
      # necessary as cloning with a --depth of 1 removes all tag info.
      result = getHeadName(downMethod)
      let versions = getTagsListRemote(url, downMethod).getVersionList()
      if versions.len > 0:
        getLatestByTag:
          display("Cloning", "latest tagged version: " & latest.tag,
                  priority = MediumPriority)
          doClone(downMethod, url, downloadDir, latest.tag,
                  onlyTip = not options.forceFullClone)
      else:
        # If no commits have been tagged on the repo we just clone HEAD.
        doClone(downMethod, url, downloadDir) # Grab HEAD.
    of DownloadMethod.hg:
      doClone(downMethod, url, downloadDir, onlyTip = not options.forceFullClone)
      result = getHeadName(downMethod)
      let versions = getTagsList(downloadDir, downMethod).getVersionList()

      if versions.len > 0:
        getLatestByTag:
          display("Switching", "to latest tagged version: " & latest.tag,
                  priority = MediumPriority)
          doCheckout(downMethod, downloadDir, latest.tag)

proc downloadPkg*(url: string, verRange: VersionRange,
                 downMethod: DownloadMethod,
                 subdir: string,
                 options: Options,
                 downloadPath = ""): (string, Version) =
  ## Downloads the repository as specified by ``url`` and ``verRange`` using
  ## the download method specified.
  ##
  ## If `downloadPath` isn't specified a location in /tmp/ will be used.
  ##
  ## Returns the directory where it was downloaded (subdir is appended) and
  ## the concrete version  which was downloaded.
  let downloadDir =
    if downloadPath == "":
      (getNimbleTempDir() / getDownloadDirName(url, verRange))
    else:
      downloadPath

  createDir(downloadDir)
  var modUrl =
    if url.startsWith("git://") and options.config.cloneUsingHttps:
      "https://" & url[6 .. ^1]
    else: url

  # Fixes issue #204
  # github + https + trailing url slash causes a
  # checkout/ls-remote to fail with Repository not found
  if modUrl.contains("github.com") and modUrl.endswith("/"):
    modUrl = modUrl[0 .. ^2]

  if subdir.len > 0:
    display("Downloading", "$1 using $2 (subdir is '$3')" %
                           [modUrl, $downMethod, subdir],
            priority = HighPriority)
  else:
    display("Downloading", "$1 using $2" % [modUrl, $downMethod],
            priority = HighPriority)
  result = (
    downloadDir / subdir,
    doDownload(modUrl, downloadDir, verRange, downMethod, options)
  )

  if verRange.kind != verSpecial:
    ## Makes sure that the downloaded package's version satisfies the requested
    ## version range.
    let pkginfo = getPkgInfo(result[0], options)
    if pkginfo.version.newVersion notin verRange:
      raise newException(NimbleError,
        "Downloaded package's version does not satisfy requested version " &
        "range: wanted $1 got $2." %
        [$verRange, $pkginfo.version])

proc echoPackageVersions*(pkg: Package) =
  let downMethod = pkg.downloadMethod.getDownloadMethod()
  case downMethod
  of DownloadMethod.git:
    try:
      let versions = getTagsListRemote(pkg.url, downMethod).getVersionList()
      if versions.len > 0:
        let sortedVersions = toSeq(values(versions))
        echo("  versions:    " & join(sortedVersions, ", "))
      else:
        echo("  versions:    (No versions tagged in the remote repository)")
    except OSError:
      echo(getCurrentExceptionMsg())
  of DownloadMethod.hg:
    echo("  versions:    (Remote tag retrieval not supported by " &
        pkg.downloadMethod & ")")

when isMainModule:
  # Test version sorting
  block:
    let data = @["v9.0.0-taeyeon", "v9.0.1-jessica", "v9.2.0-sunny",
                 "v9.4.0-tiffany", "v9.4.2-hyoyeon"]
    let expected = toOrderedTable[Version, string]({
      newVersion("9.4.2-hyoyeon"): "v9.4.2-hyoyeon",
      newVersion("9.4.0-tiffany"): "v9.4.0-tiffany",
      newVersion("9.2.0-sunny"): "v9.2.0-sunny",
      newVersion("9.0.1-jessica"): "v9.0.1-jessica",
      newVersion("9.0.0-taeyeon"): "v9.0.0-taeyeon"
    })
    doAssert expected == getVersionList(data)


  block:
    let data2 = @["v0.1.0", "v0.1.1", "v0.2.0",
                 "0.4.0", "v0.4.2"]
    let expected2 = toOrderedTable[Version, string]({
      newVersion("0.4.2"): "v0.4.2",
      newVersion("0.4.0"): "0.4.0",
      newVersion("0.2.0"): "v0.2.0",
      newVersion("0.1.1"): "v0.1.1",
      newVersion("0.1.0"): "v0.1.0",
    })
    doAssert expected2 == getVersionList(data2)

  echo("Everything works!")
