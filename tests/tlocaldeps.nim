# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, osproc, strutils, strformat
import testscommon
from nimblepkg/common import cd, NimbleError
import nimblepkg/[options, config]

suite "flag parsing":
  test "a valueless flag rejects a value (#1037)":
    # `-l`/`--localdeps` is a boolean flag. Giving it a value (users type
    # `-l:-static` expecting a linker flag) must error, not silently enable
    # localdeps mode and drop the value.
    var opts = initOptions()
    expect NimbleError:
      parseFlag("localdeps", "foo", opts)
    expect NimbleError:
      parseFlag("l", "-static", opts)

    # control: a genuine value flag is unaffected
    parseFlag("nimbledir", "/tmp/x", opts)
    check opts.nimbleDir == "/tmp/x"

    # control: a short flag that legitimately takes a value in its action context
    # (`nimble develop -n:<name>` = remove by name) must still work — the guard
    # must not break overloaded flags.
    opts.action = Action(typ: actionDevelop)
    parseFlag("n", "somepkg", opts)
    check opts.action.devActions.len == 1

suite "project local deps mode":
  setup:
    # which messes up this test sometime
    delEnv("NIMBLE_DIR")

  test "NIMBLE_DIR set to nimbledeps uses global pkgcache (issue #1610)":
    ## When `nimble shell -l` runs, it sets NIMBLE_DIR to the local nimbledeps
    ## directory. A nested nimble process picks up NIMBLE_DIR and should still
    ## use the global pkgcache (~/.nimble/pkgcache), not nimbledeps/pkgcache.
    cd "localdeps":
      cleanDir("nimbledeps")
      createDir("nimbledeps")
      let nimbledepsAbs = expandFilename("nimbledeps")
      # Simulate what `nimble shell` does: set NIMBLE_DIR to nimbledeps
      putEnv("NIMBLE_DIR", nimbledepsAbs)
      defer: delEnv("NIMBLE_DIR")

      var options = initOptions()
      options.config = parseConfig()
      options.action = Action(typ: actionInstall)
      options.setNimbleDir()

      # nimbleDir should be the nimbledeps path (from NIMBLE_DIR env)
      check options.nimbleDir == nimbledepsAbs
      # pkgCachePath should use the GLOBAL config dir, not nimbledeps
      let globalPkgCache = expandTilde(options.config.nimbleDir).absolutePath() / "pkgcache"
      check options.pkgCachePath == globalPkgCache
      check options.pkgCachePath.find("nimbledeps") == -1

  test "nimbledeps exists":
    cd "localdeps":
      removeFile("localdeps")

      # TEMPORARY: Added for global-by-default. To revert to local-by-default, remove this createDir line:
      createDir("nimbledeps")
      let (_, exitCode) = execCmdEx(nimblePath & " install -y")
      check exitCode == QuitSuccess
      check dirExists("nimbledeps")

  test "--localdeps flag":
    cd "localdeps":
      removeFile("localdeps")
      cleanDir("nimbledeps")
      let (_, exitCode) = execCmdEx(nimblePath & " install -y -l")
      check exitCode == QuitSuccess
      check dirExists("nimbledeps")

  test "localdeps develop":
    # With no host project, `develop <pkg>` clones the package as the root (./packagea).
    # `--localdeps` installs its dependencies into the package's own nimbledeps,
    # not into a vendor dir and not into the current directory.
    cleanDir("nimbledeps")
    cleanDir("packagea")
    cleanDir(defaultDevelopPath)
    let (_, exitCode) = execCmdEx(nimblePath &
      &" develop {pkgAUrl} --localdeps -y")
    check exitCode == QuitSuccess
    check dirExists("packagea" / "nimbledeps")
    check not dirExists("nimbledeps")
    check not dirExists(defaultDevelopPath)
