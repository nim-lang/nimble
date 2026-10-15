# Copyright (C) the Nimble contributors. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, strformat, chronos
import nimblepkg/[common, download, options, packageinfotypes, tools, sha1hashes]

# URLs and refs come from package lists, lock files and other packages'
# requirements. Malicious inputs must not run commands or be read as options;
# legitimate paths containing spaces must still work.
suite "URLs and refs reach git and hg only as arguments":
  let
    tmpDir = getTempDir() / "nimble vcs arguments"
    marker = tmpDir / "ran"
    gitRepo = tmpDir / "gitrepo"

  setup:
    removeDir tmpDir
    createDir tmpDir
    tryDoCmdEx(&"git init -q {gitRepo.quoteShell}")
    writeFile(gitRepo / "pkg.nimble", "version = \"1.0.0\"\n")
    tryDoCmdEx(&"git -C {gitRepo.quoteShell} add pkg.nimble")
    tryDoCmdEx(&"git -c user.name=t -c user.email=t@t -C {gitRepo.quoteShell} " &
               "commit -q -m one")

  teardown:
    removeDir tmpDir

  test "a URL is not run by the shell when listing remote tags":
    let separator = when defined(windows): " & " else: "; "
    let url = tmpDir / "missing" & separator & "echo injected > " & marker.quoteShell
    expect NimbleError:
      discard getTagsListRemote(url, DownloadMethod.git)
    expect NimbleError:
      discard waitFor getTagsListRemoteAsync(url, DownloadMethod.git)
    check not fileExists(marker)

  test "a URL is not read as a git option":
    # git runs `--upload-pack` through a shell for the repository named next.
    let url = &"--upload-pack=echo injected > {marker.quoteShell};git-upload-pack"
    expect NimbleError:
      discard getRevision(url, gitRepo)
    # Read as an option, the clone would go to `gitrepo` in the current dir.
    createDir tmpDir / "work"
    cd tmpDir / "work":
      expect NimbleError:
        waitFor doCloneAsync(DownloadMethod.git, url, gitRepo,
                             options = initOptions())
    check not fileExists(marker)

  test "a URL is not read as an hg option":
    if findExe("hg") == "":
      skip()
    else:
      let url = &"--config=hooks.pre-clone=echo injected > {marker.quoteShell}"
      expect NimbleError:
        waitFor doCloneAsync(DownloadMethod.hg, url, tmpDir / "clone",
                             options = initOptions())
      check not fileExists(marker)

  test "a ref is not read as an hg option on checkout":
    if findExe("hg") == "":
      skip()
    else:
      let hgRepo = tmpDir / "hgrepo"
      tryDoCmdEx(&"hg init {hgRepo.quoteShell}")
      writeFile(hgRepo / "a", "")
      tryDoCmdEx(&"hg --cwd {hgRepo.quoteShell} commit -q -A -u t -m one")
      let options = initOptions()
      let reference = &"--config=hooks.preupdate=echo injected > {marker.quoteShell}"
      check not doCheckout(DownloadMethod.hg, hgRepo, reference, options)
      check not waitFor doCheckoutAsync(DownloadMethod.hg, hgRepo, reference, options)
      check not fileExists(marker)

  test "a tag is not read as a git option":
    # A remote can publish any tag name, and `git show --output` writes a file.
    check not isReleaseVersionTag("--output=/tmp/x/1.0")
    let shown = tmpDir / "shown"
    expect NimbleError:
      discard gitShowFile(gitRepo, "--output=" & shown, "pkg.nimble")
    expect NimbleError:
      discard waitFor gitShowFileAsync(gitRepo, "--output=" & shown, "pkg.nimble")
    check not fileExists(shown & ":pkg.nimble")

  test "an option-like ref is rejected when listing nimble files":
    expect NimbleError:
      discard gitListNimbleFilesInCommit(gitRepo, "--help")
    expect NimbleError:
      discard waitFor gitListNimbleFilesInCommitAsync(gitRepo, "--help")

  test "Git repositories with spaces still support tags, cloning and checkout":
    tryDoCmdEx(&"git -C {gitRepo.quoteShell} tag v1.0.0")
    let options = initOptions()
    check checkUrlType(gitRepo, options) == DownloadMethod.git
    check getTagsListRemote(gitRepo, DownloadMethod.git) == @["v1.0.0"]
    check waitFor(getTagsListRemoteAsync(gitRepo, DownloadMethod.git)) == @["v1.0.0"]
    let revision = getRevision(gitRepo, "v1.0.0")
    check revision != notSetSha1Hash
    let cloneDir = tmpDir / "git clone"
    waitFor cloneSpecificRevisionAsync(DownloadMethod.git, gitRepo, cloneDir, revision, options)
    check fileExists(cloneDir / "pkg.nimble")
    check doCheckout(DownloadMethod.git, gitRepo, "v1.0.0", options)
    check waitFor doCheckoutAsync(DownloadMethod.git, gitRepo, "v1.0.0", options)
    check gitShowFile(gitRepo, "v1.0.0", "pkg.nimble") == "version = \"1.0.0\"\n"
    check waitFor(gitShowFileAsync(gitRepo, "v1.0.0", "pkg.nimble")) == "version = \"1.0.0\"\n"
    check gitListNimbleFilesInCommit(gitRepo, "v1.0.0") == @["pkg.nimble"]
    check waitFor(gitListNimbleFilesInCommitAsync(gitRepo, "v1.0.0")) == @["pkg.nimble"]

  test "Mercurial repositories with spaces still support cloning and checkout":
    if findExe("hg") == "":
      skip()
    else:
      let hgRepo = tmpDir / "hg repo"
      tryDoCmdEx(&"hg init {hgRepo.quoteShell}")
      writeFile(hgRepo / "a", "content")
      tryDoCmdEx(&"hg --cwd {hgRepo.quoteShell} commit -q -A -u t -m one")
      let options = initOptions()
      check checkUrlType(hgRepo, options) == DownloadMethod.hg
      let cloneDir = tmpDir / "hg clone"
      waitFor doCloneAsync(DownloadMethod.hg, hgRepo, cloneDir, options = options)
      check readFile(cloneDir / "a") == "content"
      check doCheckout(DownloadMethod.hg, cloneDir, "tip", options)
      check waitFor doCheckoutAsync(DownloadMethod.hg, cloneDir, "tip", options)
