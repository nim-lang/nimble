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

proc doClone(meth: TDownloadMethod, url, downloadDir: string) =
  case meth
  of TDownloadMethod.Git:
    doCmd("git clone --depth 1 " & url & " " & downloadDir)
  of TDownloadMethod.Hg:
    doCmd("hg clone " & url & " " & downloadDir)

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

proc getVersionList(dir: string,
                    meth: TDownloadMethod): TTable[TVersion, string] =
  # Returns: TTable of version -> git tag name
  result = initTable[TVersion, string]()
  let tags = getTagsList(dir, meth)
  for tag in tags:
    let i = skipUntil(tag, digits) # skip any chars before the version
    # TODO: Better checking, tags can have any names. Add warnings and such.
    result[newVersion(tag[i .. -1])] = tag

proc getDownloadMethod(meth: string): TDownloadMethod =
  case meth
  of "git": return TDownloadMethod.Git
  of "hg", "mercurial": return TDownloadMethod.Hg
  else:
    raise newException(EBabel, "Invalid download method: " & meth)

proc doDownload*(pkg: TPackage, downloadDir: string, verRange: PVersionRange) =
  let downMethod = pkg.downloadMethod.getDownloadMethod()
  echo "Executing ", downMethod, "..."
  
  if existsDir(downloadDir / getSpecificDir(downMethod)):
    doPull(downMethod, downloadDir)
  else:
    removeDir(downloadDir)
    doClone(downMethod, pkg.url, downloadDir)
  
  # TODO: Determine if version is a commit hash, if it is. Move the
  # git repo to ``babelDir/pkgs``, then babel can simply checkout
  # the correct hash instead of constantly cloning and copying.
  # N.B. This may still partly be required, as one lib may require hash A
  # whereas another lib requires hash B and they are both required by the
  # project you want to build.
  let versions = getVersionList(downloadDir, downMethod)
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
