{.used.}

import std/[assertions, json, os, osproc, options, strutils, tables, tempfiles]
import chronos
import nimblepkg/[common, download, nimblesat, options, packageinfotypes, pubgrubexplain,
  sha1hashes, version, versiondiscovery]
import pubgrub

block parsing:
  let req = parseRequires("foo#master & >= #ABCD1234")
  doAssert req.name == "foo"
  doAssert $req.ver == "#master & >= #abcd1234"
  doAssert req.ver.spe.gitReference == "master"
  doAssert req.ver.spe.gitAncestor == "abcd1234"
  doAssert req.ver.spe.toDirectoryName == "master_since_abcd1234"
  doAssert parseRequires("foo#master&>=#abcd1234") == req
  doAssert parseRequires("foo #master & >= #abcd1234") == req
  let url = parseRequires("https://example.com/foo.git#master & >= #abcd1234")
  doAssert url.name == "https://example.com/foo.git"
  doAssert url.ver == req.ver
  for invalid in ["foo#master & > #abcd", "foo#master & >= #",
      "foo#master & >= #xyz", "foo#master & >= #abcd & < #ffff"]:
    doAssertRaises NimbleError:
      discard parseRequires(invalid)

block solver_identity:
  let req = parseRequires("foo#master & >= #abcd1234")
  let candidates = @[req.ver.spe, newVersion("#master"), newVersion("1.0.0")]
  let translated = toVersionSet(req.ver, candidates)
  for v in candidates:
    doAssert translated.contains(toTaggedVersion(v)) == satisfiesConstraint(v, req.ver)
  doAssert not satisfiesConstraint(newVersion("#master"), req.ver)
  doAssert not withinRange(newVersion("1.0.0"), req.ver)
  var universe: Table[string, PackageVersions]
  universe["app"] = PackageVersions(pkgName: "app", versions: @[
    PackageMinimalInfo(name: "app", version: newVersion("1.0"),
      isRoot: true, requires: @[req])])
  universe["foo"] = PackageVersions(pkgName: "foo", versions: @[
    PackageMinimalInfo(name: "foo", version: req.ver.spe)])
  doAssert explainSolveFailure(universe).foundSolution
  universe["foo"].versions.add PackageMinimalInfo(name: "foo", version: newVersion("#master"))
  var opts = initOptions()
  opts.lenient = true
  doAssertRaises NimbleError:
    normalizeSpecialVersions(universe, opts)
  doAssert getCacheDownloadDir("https://example.com/foo", req.ver, opts) !=
    getCacheDownloadDir("https://example.com/foo", parseVersionRange("#masterabcd1234"), opts)

proc failedFetch(pv: PkgTuple, opts: Options,
    nimBin: Option[string]): Future[seq[PackageMinimalInfo]] {.async.} =
  raise nimbleError("Ancestry check failed")

block preferred_package_does_not_prove_ancestry:
  let req = parseRequires("foo#master & >= #abcd1234")
  let preferred = @[PackageMinimalInfo(name: "foo", version: newVersion("1.0.0"))]
  doAssertRaises NimbleError:
    discard waitFor getMinimalFromPreferred(req, failedFetch, preferred,
      initOptions(), some("nim"))

proc git(repo, args: string): string =
  let (output, code) = execCmdEx("git -C " & repo.quoteShell & " " & args)
  doAssert code == 0, output
  output.strip

block git_downloads:
  let temp = createTempDir("nimble-ancestry-", "")
  try:
    let repo = temp / "source"
    createDir(repo)
    discard git(repo, "init -b master")
    discard git(repo, "config user.name Test")
    discard git(repo, "config user.email test@example.invalid")
    discard git(repo, "config commit.gpgsign false")
    writeFile(repo / "foo.nimble", "version = \"1.0.0\"\nauthor = \"Test\"\n" &
      "description = \"Ancestry fixture\"\nlicense = \"MIT\"\n")
    discard git(repo, "add foo.nimble")
    discard git(repo, "commit -m base")
    let base = git(repo, "rev-parse HEAD")
    discard git(repo, "commit --allow-empty -m tip")
    let tip = git(repo, "rev-parse HEAD")
    discard git(repo, "checkout -b other " & base)
    discard git(repo, "commit --allow-empty -m divergent")
    let other = git(repo, "rev-parse HEAD")
    discard git(repo, "checkout master")

    var opts = initOptions()
    opts.nimbleDir = temp / "nimble"
    opts.ignoreSubmodules = true
    opts.enableTarballs = true
    opts.satResult.pass = satSolving
    let url = when defined(windows): "file:///" & repo.replace('\\', '/')
      else: "file://" & repo
    for asyncMode in [false, true]:
      let suffix = if asyncMode: "async" else: "sync"
      for minimum in [base, tip, base[0..7]]:
        let req = parseRequires("foo#master & >= #" & minimum)
        let dest = temp / (suffix & minimum)
        let res = if asyncMode:
          waitFor downloadPkgAsync(url, req.ver, DownloadMethod.git, "", opts,
            dest, notSetSha1Hash, some("nim"))
        else:
          downloadPkg(url, req.ver, DownloadMethod.git, "", opts,
            dest, notSetSha1Hash, some("nim"))
        doAssert $res.vcsRevision == tip
        doAssert res.version == req.ver.spe
        doAssert git(dest, "rev-parse --is-shallow-repository") == "false"
        verifyGitAncestor(dest, req.ver.spe)
        # The cache must validate the selected checkout again.
        discard git(dest, "checkout " & base)
        if minimum == tip:
          doAssertRaises NimbleError:
            discard downloadPkg(url, req.ver, DownloadMethod.git, "", opts,
              dest, notSetSha1Hash, some("nim"))

      for minimum in [other, "0000000000000000000000000000000000000000"]:
        let req = parseRequires("foo#master & >= #" & minimum)
        let dest = temp / (suffix & "bad" & minimum)
        doAssertRaises NimbleError:
          if asyncMode:
            discard waitFor downloadPkgAsync(url, req.ver, DownloadMethod.git, "", opts,
              dest, notSetSha1Hash, some("nim"))
          else:
            discard downloadPkg(url, req.ver, DownloadMethod.git, "", opts,
              dest, notSetSha1Hash, some("nim"))
        # A failed download leaves files, but cannot become a valid cache hit.
        doAssertRaises NimbleError:
          discard downloadPkg(url, req.ver, DownloadMethod.git, "", opts,
            dest, notSetSha1Hash, some("nim"))

    let pinned = parseRequires("foo#master & >= #" & tip)
    doAssertRaises NimbleError:
      discard downloadPkg(url, pinned.ver, DownloadMethod.git, "", opts,
        temp / "old-lock", initSha1Hash(base), some("nim"))
    doAssertRaises NimbleError:
      discard downloadPkg(url, pinned.ver, DownloadMethod.hg, "", opts,
        temp / "hg", notSetSha1Hash, some("nim"))

    let binary = getEnv("NIMBLE_TEST_BINARY_PATH",
      currentSourcePath().parentDir.parentDir / "src" / "nimble")
    doAssert fileExists(binary), "Build src/nimble or set NIMBLE_TEST_BINARY_PATH"
    let app = temp / "app"
    createDir(app)
    createDir(opts.nimbleDir)
    writeFile(opts.nimbleDir / "packages_official.json", $(%*[
      {"name": "foo", "url": url, "method": "git", "license": "MIT", "tags": []}]))
    let appHeader = "version = \"1.0.0\"\nauthor = \"Test\"\n" &
      "description = \"Ancestry app\"\nlicense = \"MIT\"\n"
    writeFile(app / "app.nimble", appHeader &
      "requires \"foo#master & >= #" & base & "\"\n")
    discard git(app, "init")
    discard git(app, "add app.nimble")
    discard git(app, "-c user.name=Test -c user.email=test@example.invalid " &
      "-c commit.gpgsign=false commit -m initial")
    let command = binary.quoteShell & " --nimbleDir:" & opts.nimbleDir.quoteShell &
      " --useSystemNim --parser:declarative -y "
    let (lockOutput, lockCode) = execCmdEx(command & "lock", workingDir = app)
    doAssert lockCode == 0, lockOutput
    let locked = parseFile(app / "nimble.lock")["packages"]["foo"]
    doAssert locked["version"].getStr == "#master & >= #" & base
    doAssert locked["vcsRevision"].getStr == tip
    let (offlineOutput, offlineCode) = execCmdEx(command & "--offline setup", workingDir = app)
    doAssert offlineCode == 0, offlineOutput
    # Changing the bound must invalidate the old lock's version match.
    writeFile(app / "app.nimble", appHeader &
      "requires \"foo#master & >= #" & other & "\"\n")
    let (badOutput, badCode) = execCmdEx(command & "lock", workingDir = app)
    doAssert badCode != 0, badOutput
    # A merge makes a formerly divergent commit an ancestor through its second parent.
    discard git(repo, "merge --no-ff other -m merged")
    let merged = parseRequires("foo#master & >= #" & other)
    let mergedResult = waitFor downloadPkgAsync(url, merged.ver, DownloadMethod.git, "", opts,
      temp / "merged", notSetSha1Hash, some("nim"))
    doAssert $mergedResult.vcsRevision == git(repo, "rev-parse HEAD")
  finally:
    removeDir(temp)

echo "Git ancestry requirement tests passed"
