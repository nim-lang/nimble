# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import parseutils, os, osproc, strutils, tables

import packageinfo, common, version, tools

type  
  TDownloadMethod {.pure.} = enum
    Git = "git", Hg = "hg"

proc getSpecificDir(meth: TDownloadMethod): string =
  case meth
  of TDownloadMethod.Git:
    ".git"
  of TDownloadMethod.Hg:
    ".hg"

proc doCheckout(meth: TDownloadMethod, downloadDir, branch: string) =
  case meth
  of TDownloadMethod.Git:
    cd downloadDir:
      doCmd("git checkout " & branch)
  of TDownloadMethod.Hg:
    cd downloadDir:
      doCmd("hg checkout " & branch)

proc doPull(meth: TDownloadMethod, downloadDir: string) =
  case meth
  of TDownloadMethod.Git:
    doCheckout(meth, downloadDir, "master")
    cd downloadDir:
      doCmd("git pull")
  of TDownloadMethod.Hg:
    doCheckout(meth, downloadDir, "default")
    cd downloadDir:
      doCmd("hg pull")

proc doClone(meth: TDownloadMethod, url, downloadDir: string, branch = "") =
  let branchArg = if branch == "": "" else: "-b " & branch & " "
  case meth
  of TDownloadMethod.Git:
    # TODO: Get rid of the annoying 'detached HEAD' message somehow?
    doCmd("git clone --depth 1 " & branchArg & url & " " & downloadDir)
  of TDownloadMethod.Hg:
    doCmd("hg clone -r tip " & branchArg & url & " " & downloadDir)

proc getTagsList(dir: string, meth: TDownloadMethod): seq[string] =
  cd dir:
    var output = execProcess("git tag")
    case meth
    of TDownloadMethod.Git:
      output = execProcess("git tag")
    of TDownloadMethod.Hg:
      output = execProcess("hg tags")
  if output.len > 0:
    case meth
    of TDownloadMethod.Git:
      result = output.splitLines()
    of TDownloadMethod.Hg:
      result = @[]
      for i in output.splitLines():
        var tag = ""
        discard parseUntil(i, tag, ' ')
        if tag != "tip":
          result.add(tag)
  else:
    result = @[]

proc getTagsListRemote*(url: string, meth: TDownloadMethod): seq[string] =
  result = @[]
  case meth
  of TDownloadMethod.Git:
    var (output, exitCode) = execCmdEx("git ls-remote --tags " & url)
    if exitCode != QuitSuccess:
      raise newException(EOS, "Unable to query remote tags for " & url &
          ". Git returned: " & output)
    for i in output.splitLines():
      if i == "": continue
      let start = i.find("refs/tags/")+"refs/tags/".len
      let tag = i[start .. -1]
      if not tag.endswith("^{}"): result.add(tag)
    
  of TDownloadMethod.Hg:
    # http://stackoverflow.com/questions/2039150/show-tags-for-remote-hg-repository
    raise newException(EInvalidValue, "Hg doesn't support remote tag querying.")
  
proc getVersionList*(tags: seq[string]): TTable[TVersion, string] =
  # Returns: TTable of version -> git tag name
  result = initTable[TVersion, string]()
  for tag in tags:
    let i = skipUntil(tag, digits) # skip any chars before the version
    # TODO: Better checking, tags can have any names. Add warnings and such.
    result[newVersion(tag[i .. -1])] = tag

proc getDownloadMethod*(meth: string): TDownloadMethod =
  case meth
  of "git": return TDownloadMethod.Git
  of "hg", "mercurial": return TDownloadMethod.Hg
  else:
    raise newException(EBabel, "Invalid download method: " & meth)

proc doDownload*(pkg: TPackage, downloadDir: string, verRange: PVersionRange) =
  let downMethod = pkg.downloadMethod.getDownloadMethod()
  echo "Downloading ", pkg.name, " using ", downMethod, "..."
  
  case downMethod
  of TDownloadMethod.Git:
    # For Git we have to query the repo remotely for its tags. This is
    # necessary as cloning with a --depth of 1 removes all tag info.
    let versions = getTagsListRemote(pkg.url, downMethod).getVersionList()
    if versions.len > 0:
      echo("Found tags...")
      var latest = findLatest(verRange, versions)
      ## Note: HEAD is not used when verRange.kind is verAny. This is
      ## intended behaviour, the latest tagged version will be used in this case.
      if latest.tag != "":
        echo("Cloning latest tagged version: ", latest.tag)
        removeDir(downloadDir)
        doClone(downMethod, pkg.url, downloadDir, latest.tag)
    else:
      # If no commits have been tagged on the repo we just clone HEAD.
      removeDir(downloadDir)
      doClone(downMethod, pkg.url, downloadDir) # Grab HEAD.
      if verRange.kind != verAny:
        # Make sure that HEAD satisfies the requested version range.
        let pkginfo = getPkgInfo(downloadDir)
        if pkginfo.version.newVersion notin verRange:
          raise newException(EBabel,
                "No versions of " & pkg.name &
                " exist (this usually means that `git tag` returned nothing)." &
                "Git HEAD also does not satisfy version range: " & $verRange)
  of TDownloadMethod.Hg:
    removeDir(downloadDir)
    doClone(downMethod, pkg.url, downloadDir)
    let versions = getTagsList(downloadDir, downMethod).getVersionList()
  
    if versions.len > 0:
      echo("Found tags...")
      var latest = findLatest(verRange, versions)
      ## Note: HEAD is not used when verRange.kind is verAny. This is
      ## intended behaviour, the latest tagged version will be used in this case.
      if latest.tag != "":
        echo("Switching to latest tagged version: ", latest.tag)
        doCheckout(downMethod, downloadDir, latest.tag)
    elif verRange.kind != verAny:
      let pkginfo = getPkgInfo(downloadDir)
      if pkginfo.version.newVersion notin verRange:
        raise newException(EBabel,
              "No versions of " & pkg.name &
              " exist (this usually means that `git tag` returned nothing)." &
              "Git HEAD also does not satisfy version range: " & $verRange)
      # We use GIT HEAD if it satisfies our ver range

proc echoPackage*(pkg: TPackage) =
  echo(pkg.name & ":")
  echo("  url:         " & pkg.url & " (" & pkg.downloadMethod & ")")
  echo("  tags:        " & pkg.tags.join(", "))
  echo("  description: " & pkg.description)
  echo("  license:     " & pkg.license)
  if pkg.web.len > 0:
    echo("  website:     " & pkg.web)
  let downMethod = pkg.downloadMethod.getDownloadMethod()
  case downMethod
  of TDownloadMethod.Git:
    try:
      let versions = getTagsListRemote(pkg.url, downMethod).getVersionList()
      if versions.len > 0:
        echo("  versions:    ")
        for k, ver in versions:
          echo "    ", ver
      else:
        echo("  versions:    (No versions tagged in the remote repository)")
    except EOS:
      echo(getCurrentExceptionMsg())
  of TDownloadMethod.Hg:
    echo("  versions:    (Remote tag retrieval not supported by " & pkg.downloadMethod & ")")