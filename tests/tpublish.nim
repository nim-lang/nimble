# Copyright (C) Andreas Rumpf. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}
import std/[unittest, os, osproc]
import nimblepkg/[publish, options, packageinfo, cli]

suite "publish":
  test "gatherPublishData resolves the repo URL from the local repo without any GitHub network access (#1738)":
    # The publish flow used to open the GitHub session *before* prompting the
    # user for tags, so a slow answer let the connection go stale. All the
    # information the user has to provide (repo URL + tags) is derived purely
    # from the local repository and the prompts, so it must be gatherable
    # without ever touching GitHub. This test constructs a local repo with a
    # bogus, unreachable remote to prove no network is required.
    let tmp = getTempDir() / "nimble_publish_1738"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    defer: removeDir(tmp)

    let q = quoteShell(tmp)
    check execCmd("git -C " & q & " init -q") == 0
    check execCmd("git -C " & q &
      " remote add origin https://github.com/nim-lang/testpkg.git") == 0

    var p = initPackageInfo()
    p.basicInfo.name = "testpkg"
    var options = initOptions()
    # Force prompts so the tags prompt returns its default instead of blocking
    # on stdin in a non-interactive test.
    options.forcePrompts = forcePromptYes

    let old = getCurrentDir()
    setCurrentDir(tmp)
    defer: setCurrentDir(old)

    let data = gatherPublishData(p, options)
    check data.downloadMethod == "git"
    check data.url == "https://github.com/nim-lang/testpkg"
