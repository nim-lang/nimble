# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, strutils, strformat, json
import testscommon

from nimblepkg/common import cd, cdNewDir
from nimblepkg/tools import tryDoCmdEx
from nimblepkg/packageinfotypes import DownloadMethod
from nimblepkg/options import defaultLockFileName

suite "nimble refresh":
  test "can refresh with default urls":
    let (output, exitCode) = execNimble(["refresh"])
    checkpoint(output)
    check exitCode == QuitSuccess

  test "can refresh with custom urls":
    testRefresh():
      writeFile(configFile, """
        [PackageList]
        name = "official"
        url = "https://google.com"
        url = "https://google.com/404"
        url = "https://irclogs.nim-lang.org/packages.json"
        url = "https://nim-lang.org/nimble/packages.json"
        url = "https://github.com/nim-lang/packages/raw/master/packages.json"
      """.unindent)

      let (output, exitCode) = execNimble(["refresh", "--verbose"])
      checkpoint(output)
      let lines = output.strip.processOutput()
      check exitCode == QuitSuccess
      check inLines(lines, "config file at")
      check inLines(lines, "official package list")
      check inLines(lines, "https://google.com")
      check inLines(lines, "packages.json file is invalid")
      check inLines(lines, "404")
      check inLines(lines, "Package list downloaded.")

  test "a mirror that cannot be reached does not abort the refresh (#1845)":
    # chronos raises HttpConnectionError for DNS/TCP/TLS-level failures. Nimble
    # used to re-raise it on the spot, claiming a certificate problem, so the
    # remaining mirrors were never tried. `.invalid` is reserved by RFC 2606 and
    # never resolves, which produces a connection-level failure - unlike the
    # 404/bad-JSON mirrors above, which fail at the HTTP level.
    testRefresh():
      writeFile(configFile, """
        [PackageList]
        name = "official"
        url = "https://nimble-1845.invalid/packages.json"
        url = "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"
      """.unindent)

      let (output, exitCode) = execNimble(["refresh", "--verbose"])
      checkpoint(output)
      let lines = output.strip.processOutput()
      check exitCode == QuitSuccess
      # The unreachable mirror is reported for what it is ...
      check not output.contains("Failed to verify the SSL certificate")
      # ... and the next one is still tried.
      check inLines(lines, "raw.githubusercontent.com/nim-lang/packages")
      check inLines(lines, "Package list downloaded.")

  test "can refresh with local package list":
    testRefresh():
      writeFile(configFile, """
        [PackageList]
        name = "local"
        path = "$1"
      """.unindent % (getCurrentDir() / "issue368" / "packages.json").replace(
        "\\", "\\\\"))
      let (output, exitCode) = execNimble(["refresh", "--verbose"])
      let lines = output.strip.processOutput()
      check inLines(lines, "config file at")
      check inLines(lines, "Copying")
      check inLines(lines, "Package list copied.")
      check exitCode == QuitSuccess

  test "missing package refreshes a fresh package list only once (#1793)":
    testRefresh():
      let
        tempNimbleDir = getTempDir() / "nimble_missing_package_refresh"
        packageList = getCurrentDir() / "issue368" / "packages.json"
      removeDir(tempNimbleDir)
      defer: removeDir(tempNimbleDir)

      writeFile(configFile, """
        [PackageList]
        name = "Official"
        path = "$1"
      """.unindent % packageList.replace("\\", "\\\\"))

      let (output, exitCode) = execNimble(
        "--nimbleDir:" & tempNimbleDir,
        "-y", "install", "definitely-not-a-nimble-package")
      checkpoint output
      check exitCode == QuitFailure
      check output.count("Copying Official package list") == 1
      check output.contains("Package definitely-not-a-nimble-package")

  test "package list source required":
    testRefresh():
      writeFile(configFile, """
        [PackageList]
        name = "local"
      """)
      let (output, exitCode) = execNimble(["refresh", "--verbose"])
      let lines = output.strip.processOutput()
      check inLines(lines, "config file at")
      check inLines(lines, "Package list 'local' requires either url or path")
      check exitCode == QuitFailure

  test "package list can only have one source":
    testRefresh():
      writeFile(configFile, """
        [PackageList]
        name = "local"
        path = "$1"
        url = "http://nim-lang.org/nimble/packages.json"
      """)
      let (output, exitCode) = execNimble(["refresh", "--verbose"])
      let lines = output.strip.processOutput()
      check inLines(lines, "config file at")
      check inLines(lines, "Attempted to specify `url` and `path` for the " &
                           "same package list 'local'")
      check exitCode == QuitFailure

suite "nimble refresh dependencies":
  ## `nimble refresh` inside a package also fetches the repos backing its
  ## (transitive) dependencies and reports what newer versions that made
  ## visible.
  type
    PackagesListFileRecord = object
      name: string
      url: string
      `method`: DownloadMethod
      tags: seq[string]
      description: string
      license: string

  const
    tempDir = getTempDir() / "trefreshdeps"
    originsDirPath = tempDir / "origins"
    pkgListFilePath = tempDir / "packages.json"
    mainPkgPath = tempDir / "main"
    depOriginPath = originsDirPath / "dep1"
    depClonePath = tempDir / "dep1"
    nimbleFileTemplate = """
version       = "$1"
author        = "John Doe"
description   = "A test package"
license       = "MIT"
"""

  proc configUserAndEmail() =
    tryDoCmdEx("git config user.name \"John Doe\"")
    tryDoCmdEx("git config user.email \"john.doe@example.com\"")

  proc initRepo() =
    tryDoCmdEx("git init")
    configUserAndEmail()

  proc commitAll(msg: string) =
    tryDoCmdEx("git add .")
    tryDoCmdEx("git commit -am " & msg.quoteShell)

  proc writeDepVersion(version: string, name = "dep1", requirement = "",
                       requirements: seq[string] = @[]) =
    ## Writes <name>.nimble at `version` in the cwd and tags it. `requirement`
    ## lets a new version raise its floor on another dependency.
    var content = nimbleFileTemplate % version
    if requirement.len > 0:
      content.add &"requires \"{requirement}\"\n"
    for req in requirements:
      content.add &"requires \"{req}\"\n"
    writeFile(&"{name}.nimble", content)
    commitAll(version)
    tryDoCmdEx(&"git tag v{version}")

  proc initDepOrigin(versions: seq[string], name = "dep1") =
    cdNewDir originsDirPath / name:
      initRepo()
      for v in versions:
        writeDepVersion(v, name)

  proc addDepVersion(version: string, name = "dep1", requirement = "") =
    cd originsDirPath / name:
      writeDepVersion(version, name, requirement)

  proc initMainPkg(requirement: string, underVcs = false) =
    createDir mainPkgPath
    cd mainPkgPath:
      writeFile("main.nimble",
        (nimbleFileTemplate % "0.1.0") & &"requires \"{requirement}\"\n")
      if underVcs:
        # Rewriting an existing lock file requires the project dir to be under
        # version control (creating one does not).
        initRepo()
        commitAll("main")

  proc writePkgListFile(names = @["dep1"]) =
    createDir tempDir
    var records: seq[PackagesListFileRecord]
    for name in names:
      records.add PackagesListFileRecord(
        name: name, url: originsDirPath / name, `method`: DownloadMethod.git,
        tags: @["test"], description: "A test package.", license: "MIT")
    writeFile(pkgListFilePath, (%records).pretty)

  template withCleanDirs(body: untyped) =
    removeDir tempDir
    removeDir installDir
    defer:
      removeDir tempDir
      removeDir installDir
    body

  template withDepProject(requirement: string, body: untyped) =
    ## dep1 origin at 0.1.0, a main package requiring it, and a warm cache
    ## (`nimble install` resolved dep1 once, so tagged_versions.json knows 0.1.0).
    withDepProject(requirement, false, body)

  template withDepProject(requirement: string, underVcs, body: untyped) =
    ## As the 2-arg overload, but with the main package's directory under git
    ## control so the lock file can be rewritten in place.
    withCleanDirs:
      writePkgListFile()
      usePackageListFile pkgListFilePath:
        initDepOrigin(@["0.1.0"])
        initMainPkg(requirement, underVcs)
        cd mainPkgPath:
          check execNimbleYes("install").exitCode == QuitSuccess
        body

  template withTwoDepProject(body: untyped) =
    ## dep1 and dep2 origins at 0.1.0 and a main package requiring both, under
    ## git so its lock file can be rewritten. Two deps are what make "only the
    ## named package moved" observable.
    withCleanDirs:
      writePkgListFile(@["dep1", "dep2"])
      usePackageListFile pkgListFilePath:
        initDepOrigin(@["0.1.0"], "dep1")
        initDepOrigin(@["0.1.0"], "dep2")
        createDir mainPkgPath
        cd mainPkgPath:
          writeFile("main.nimble", (nimbleFileTemplate % "0.1.0") &
            "requires \"dep1 >= 0.1.0\"\nrequires \"dep2 >= 0.1.0\"\n")
          initRepo()
          commitAll("main")
          check execNimbleYes("install").exitCode == QuitSuccess
        body

  proc lockedVersion(pkg: string): string =
    ## The version `pkg` is pinned to in the main package's lock file.
    let lock = parseJson(readFile(mainPkgPath / defaultLockFileName))
    for name, dep in lock["packages"].pairs:
      if name.cmpIgnoreCase(pkg) == 0:
        return dep["version"].getStr
    return ""

  template withSharedDepProject(body: untyped) =
    # json_rpc can keep the old chronos and websock. The newer websock needs
    # the newer chronos, while the old websock explicitly rules it out.
    withCleanDirs:
      writePkgListFile(@["chronos", "websock", "json_rpc"])
      testRefresh():
        # Override the official list, since these fixture names also exist in
        # the real registry. Every dependency must come from the local repos.
        writeFile(configFile, """
          [PackageList]
          name = "official"
          path = "$1"
        """.unindent % pkgListFilePath.replace("\\", "\\\\"))
        require execNimbleYes("refresh", "--packageListOnly").exitCode == QuitSuccess
        initDepOrigin(@["4.2.3"], "chronos")
        cdNewDir originsDirPath / "websock":
          initRepo()
          writeDepVersion("0.4.0", "websock", "chronos >= 4.2.0 & < 4.4.0")
        let rpcRequirements = @[
          "chronos >= 4.0.3 & < 5.0.0", "websock >= 0.2.1 & < 0.5.0"]
        cdNewDir originsDirPath / "json_rpc":
          initRepo()
          writeDepVersion("0.6.1", "json_rpc", requirements = rpcRequirements)
        initMainPkg("json_rpc >= 0.6.1", underVcs = true)
        cd mainPkgPath:
          require execNimbleYes("lock", "--useSystemNim").exitCode == QuitSuccess
        addDepVersion("4.4.1", "chronos")
        addDepVersion("0.4.1", "websock", "chronos >= 4.4.0 & < 5.0.0")
        cd originsDirPath / "json_rpc":
          writeDepVersion("0.7.0", "json_rpc", requirements = rpcRequirements)
        body

  test "refresh makes a newly published tag visible":
    withDepProject("dep1 >= 0.1.0"):
      addDepVersion("0.2.0")   # published after the cache was warmed
      cd mainPkgPath:
        let (output, exitCode) = execNimbleYes("refresh")
        check exitCode == QuitSuccess
        check output.contains("dep1 0.1.0 -> 0.2.0")
      # The new version is a real candidate for the next resolve.
      let cache = (installDir / "pkgcache" / "tagged_versions.json").readFile
      check cache.contains("0.2.0")

  test "install --refresh picks up a version the warm cache hides":
    withDepProject("dep1 >= 0.1.0"):
      addDepVersion("0.2.0")   # published after the cache was warmed
      cd mainPkgPath:
        # 0.1.0 is installed and satisfies the requirement, so resolving from
        # the cache never looks at the origin and never sees 0.2.0.
        check execNimbleYes("install").exitCode == QuitSuccess
        check getPackageDir(pkgsDir, "dep1-0.2.0") == ""

        check execNimbleYes("install", "--refresh").exitCode == QuitSuccess
        check getPackageDir(pkgsDir, "dep1-0.2.0") != ""

  test "refresh --packageListOnly leaves the dependency clones alone":
    withDepProject("dep1 >= 0.1.0"):
      addDepVersion("0.2.0")
      cd mainPkgPath:
        let (output, exitCode) = execNimbleYes("refresh", "--packageListOnly")
        check exitCode == QuitSuccess
        check not output.contains("Refreshed")
      let cache = (installDir / "pkgcache" / "tagged_versions.json").readFile
      check not cache.contains("0.2.0")

  test "refresh with nothing new is a no-op":
    withDepProject("dep1 >= 0.1.0"):
      cd mainPkgPath:
        check execNimbleYes("refresh").exitCode == QuitSuccess
        let (output, exitCode) = execNimbleYes("refresh")
        check exitCode == QuitSuccess
        check output.contains("Everything is up to date")
        # picks nothing, writes no lock file
        check not fileExists("nimble.lock")

  test "refresh -g refreshes every globally known package":
    withDepProject("dep1 >= 0.1.0"):
      addDepVersion("0.2.0")
      cd mainPkgPath:
        let (output, exitCode) = execNimbleYes("refresh", "-g")
        check exitCode == QuitSuccess
        # The global pass, not the project one.
        check output.contains("global packages")
        check not output.contains("dependencies of main")
        check output.contains("dep1 0.1.0 -> 0.2.0")

  test "refresh outside a package refreshes globally without -g":
    withDepProject("dep1 >= 0.1.0"):
      addDepVersion("0.2.0")
      # tempDir holds the fixtures but no nimble file, so there is no project
      # to scope the refresh to.
      cd tempDir:
        let (output, exitCode) = execNimbleYes("refresh")
        check exitCode == QuitSuccess
        check output.contains("global packages")
        check output.contains("dep1 0.1.0 -> 0.2.0")

  test "refresh inside a package stays scoped to it without -g":
    withDepProject("dep1 >= 0.1.0"):
      cd mainPkgPath:
        let (output, exitCode) = execNimbleYes("refresh")
        check exitCode == QuitSuccess
        check output.contains("dependencies of main")
        check not output.contains("global packages")

  test "refresh updates a clean develop dependency to its newest tag":
    withDepProject("dep1 >= 0.1.0"):
      tryDoCmdEx(&"git clone {depOriginPath} {depClonePath}")
      cd depClonePath:
        configUserAndEmail()
        tryDoCmdEx("git checkout v0.1.0")
      addDepVersion("0.2.0")
      cd mainPkgPath:
        writeDevelopFile("nimble.develop", @[], @[depClonePath])
        let (output, exitCode) = execNimbleYes("refresh")
        check exitCode == QuitSuccess
        check output.contains("Updated develop dependencies")
        check output.contains("dep1 0.1.0 -> 0.2.0")
      cd depClonePath:
        let tag = tryDoCmdEx("git describe --tags").strip
        check tag == "v0.2.0"

  test "refresh never touches a dirty develop dependency":
    withDepProject("dep1 >= 0.1.0"):
      tryDoCmdEx(&"git clone {depOriginPath} {depClonePath}")
      cd depClonePath:
        configUserAndEmail()
        tryDoCmdEx("git checkout v0.1.0")
      addDepVersion("0.2.0")
      # A tracked file with uncommitted changes; untracked files don't count
      # as dirty (see isWorkingCopyClean).
      let depNimbleFile = depClonePath / "dep1.nimble"
      writeFile(depNimbleFile, readFile(depNimbleFile) & "# local edit\n")
      cd mainPkgPath:
        writeDevelopFile("nimble.develop", @[], @[depClonePath])
        let (output, exitCode) = execNimbleYes("refresh")
        check exitCode == QuitSuccess
        check output.contains("Skipped (uncommitted changes)")
      cd depClonePath:
        let tag = tryDoCmdEx("git describe --tags").strip
        check tag == "v0.1.0"

  test "lock --refresh relocks to a newly published version":
    withDepProject("dep1 >= 0.1.0", true):
      cd mainPkgPath:
        # Lock first so the next publish has an existing pin to keep or move.
        check execNimbleYes("lock").exitCode == QuitSuccess
        check (defaultLockFileName.readFile).contains("0.1.0")
      addDepVersion("0.2.0")   # published after the lock was written
      cd mainPkgPath:
        # A plain `lock` keeps its pins; the newly published version is not used.
        check execNimbleYes("lock").exitCode == QuitSuccess
        check not (defaultLockFileName.readFile).contains("0.2.0")
        check (defaultLockFileName.readFile).contains("0.1.0")

        # `lock --refresh` ignores the pins and relocks to the newest.
        check execNimbleYes("lock", "--refresh").exitCode == QuitSuccess
        check (defaultLockFileName.readFile).contains("0.2.0")
        check not (defaultLockFileName.readFile).contains("0.1.0")

  test "upgrade still works and says it is deprecated":
    withDepProject("dep1 >= 0.1.0", true):
      cd mainPkgPath:
        # Lock first so `upgrade` relocks an existing pin rather than creating one.
        check execNimbleYes("lock").exitCode == QuitSuccess
        check (defaultLockFileName.readFile).contains("0.1.0")
      addDepVersion("0.2.0")   # published after the lock was written
      cd mainPkgPath:
        let (output, exitCode) = execNimbleYes("upgrade")
        check exitCode == QuitSuccess
        # `upgrade` is an alias of `lock --refresh`, so it fetches the remotes
        # and finds 0.2.0 the same way `lock --refresh` does.
        check output.contains("`nimble upgrade` is deprecated")
        check output.contains("nimble lock --refresh")
        check (defaultLockFileName.readFile).contains("0.2.0")
        check not (defaultLockFileName.readFile).contains("0.1.0")

  test "lock --refresh pkg relocks only that package":
    withTwoDepProject:
      cd mainPkgPath:
        check execNimbleYes("lock").exitCode == QuitSuccess
        check lockedVersion("dep1") == "0.1.0"
        check lockedVersion("dep2") == "0.1.0"
      addDepVersion("0.2.0", "dep1")
      addDepVersion("0.2.0", "dep2")
      cd mainPkgPath:
        check execNimbleYes("lock", "--refresh", "dep1").exitCode == QuitSuccess
        # Naming a package scopes the relock to it; dep2 keeps its pin even
        # though 0.2.0 is available for it too.
        check lockedVersion("dep1") == "0.2.0"
        check lockedVersion("dep2") == "0.1.0"

  test "lock --refresh preserves compatible transitive pins regardless of lock order (#1849)":
    withSharedDepProject:
      cd mainPkgPath:
        let original = defaultLockFileName.readFile.parseJson
        # Both orders describe exactly the same graph. Resolution must not
        # depend on whether a shared dependency is visited before its users.
        for order in [@["chronos", "websock", "json_rpc"],
                      @["json_rpc", "websock", "chronos"]]:
          var reordered = original.copy
          reordered["packages"] = newJObject()
          for name in order:
            reordered["packages"][name] = original["packages"][name]
          writeFile(defaultLockFileName, reordered.pretty)
          let (output, exitCode) = execNimbleYes("lock", "--refresh", "json_rpc", "--useSystemNim")
          checkpoint(output)
          check exitCode == QuitSuccess
          let updated = defaultLockFileName.readFile.parseJson
          check updated["packages"]["json_rpc"]["version"].getStr == "0.7.0"
          for name in ["chronos", "websock"]:
            check updated["packages"][name] == original["packages"][name]
          check not packageDirExists(pkgsDir, "chronos-4.4.1")
          check not packageDirExists(pkgsDir, "websock-0.4.1")

  test "lock --refresh upgrades an incompatible reverse dependency (#1849)":
    withSharedDepProject:
      cd mainPkgPath:
        let original = defaultLockFileName.readFile.parseJson
        let (output, exitCode) = execNimbleYes("lock", "--refresh", "chronos", "--useSystemNim")
        checkpoint(output)
        check exitCode == QuitSuccess
        let updated = defaultLockFileName.readFile.parseJson
        check lockedVersion("chronos") == "4.4.1"
        check lockedVersion("websock") == "0.4.1"
        check updated["packages"]["json_rpc"] == original["packages"]["json_rpc"]
        check not packageDirExists(pkgsDir, "json_rpc-0.7.0")
        let paths = readFile("nimble.paths")
        check paths.contains("chronos-4.4.1")
        check paths.contains("websock-0.4.1")
        check not paths.contains("websock-0.4.0")

  test "lock --refresh preserves pins whose packages are not installed (#1849)":
    withSharedDepProject:
      cd mainPkgPath:
        let original = defaultLockFileName.readFile.parseJson
        removeDir getPackageDir(pkgsDir, "chronos-4.2.3")
        removeDir getPackageDir(pkgsDir, "websock-0.4.0")
        let (output, exitCode) = execNimbleYes("lock", "--refresh", "json_rpc", "--useSystemNim")
        checkpoint(output)
        check exitCode == QuitSuccess
        let updated = defaultLockFileName.readFile.parseJson
        check lockedVersion("json_rpc") == "0.7.0"
        for name in ["chronos", "websock"]:
          check updated["packages"][name] == original["packages"][name]
        check packageDirExists(pkgsDir, "chronos-4.2.3")
        check packageDirExists(pkgsDir, "websock-0.4.0")

  test "lock pkg relocks from the cache without fetching":
    withTwoDepProject:
      cd mainPkgPath:
        check execNimbleYes("lock").exitCode == QuitSuccess
      addDepVersion("0.2.0", "dep1")
      cd mainPkgPath:
        # Without --refresh nothing is fetched, so the newly published 0.2.0 is
        # not visible yet and the pin stays put.
        check execNimbleYes("lock", "dep1").exitCode == QuitSuccess
        check lockedVersion("dep1") == "0.1.0"

        # Once discovery has seen it, naming the package moves it - and only it.
        check execNimbleYes("refresh").exitCode == QuitSuccess
        check execNimbleYes("lock", "dep1").exitCode == QuitSuccess
        check lockedVersion("dep1") == "0.2.0"
        check lockedVersion("dep2") == "0.1.0"

  test "lock --refresh pkg drags along the dependencies its new version needs":
    withTwoDepProject:
      cd mainPkgPath:
        check execNimbleYes("lock").exitCode == QuitSuccess
        check lockedVersion("dep1") == "0.1.0"
        check lockedVersion("dep2") == "0.1.0"
      # dep1 0.2.0 raises its floor on dep2. Moving dep1 alone would leave the
      # lock file contradicting dep1's own requirements.
      addDepVersion("0.2.0", "dep2")
      addDepVersion("0.2.0", "dep1", requirement = "dep2 >= 0.2.0")
      cd mainPkgPath:
        check execNimbleYes("lock", "--refresh", "dep1").exitCode == QuitSuccess
        check lockedVersion("dep1") == "0.2.0"
        check lockedVersion("dep2") == "0.2.0"

  test "lock --requires moves a pin the tightened constraint rules out":
    withTwoDepProject:
      addDepVersion("0.2.0", "dep2")
      cd mainPkgPath:
        check execNimbleYes("lock", "--refresh").exitCode == QuitSuccess
        check lockedVersion("dep2") == "0.2.0"
        # The constraint has to survive as far as the lock file: dep2 is pinned
        # at a version it forbids, so that pin cannot be carried over as-is.
        check execNimbleYes("lock", "dep1", "--requires: dep2 < 0.2.0")
          .exitCode == QuitSuccess
        check lockedVersion("dep2") == "0.1.0"
