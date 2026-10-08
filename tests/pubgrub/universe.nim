# Copyright (C) the Nimble contributors. All rights reserved.
# BSD License. Look at license.txt for more info.

import std/[tables, options]
import nimblepkg/version
import nimblepkg/packageinfotypes

proc sv*(spe: string, semver = ""): Version =
  ## A special version, optionally carrying the semantic version it resolved
  ## to after download (`speSemanticVersion`).
  result = newVersion(spe)
  doAssert result.isSpecial
  if semver.len > 0:
    result.speSemanticVersion = some(semver)

proc addPkg*(t: var Table[string, PackageVersions], name, version: string,
             requires: openArray[string] = [], isRoot = false) =
  ## Declares one package version, its requirements written exactly as they
  ## would be in a .nimble file.
  var mi = PackageMinimalInfo(name: name, version: newVersion(version),
                              isRoot: isRoot)
  for r in requires:
    mi.requires.add parseRequires(r)
  t.mgetOrPut(name, PackageVersions(pkgName: name)).versions.add mi

proc addPkg*(t: var Table[string, PackageVersions], name: string,
             version: Version, requires: openArray[string] = []) =
  var mi = PackageMinimalInfo(name: name, version: version)
  for r in requires:
    mi.requires.add parseRequires(r)
  t.mgetOrPut(name, PackageVersions(pkgName: name)).versions.add mi
