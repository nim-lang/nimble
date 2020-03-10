# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import json, sets

import common, options, version, download, jsonhelpers,
       packageinfotypes, packageinfo

proc addRevDep*(nimbleData: JsonNode, dep: PackageBasicInfo,
                pkg: PackageInfo) =
  # Add a record which specifies that `pkg` has a dependency on `dep`, i.e.
  # the reverse dependency of `dep` is `pkg`.

  let dependencies = nimbleData.addIfNotExist(
    $ndjkRevDep,
    dep.name,
    dep.version,
    dep.checksum,
    newJArray(),
    )

  let dependency = %{
    $ndjkRevDepName: %pkg.name,
    $ndjkRevDepVersion: %pkg.specialVersion,
    $ndjkRevDepChecksum: %pkg.checksum,
    }

  if dependency notin dependencies:
    dependencies.add(dependency)

proc removeRevDep*(nimbleData: JsonNode, pkg: PackageInfo) =
  ## Removes ``pkg`` from the reverse dependencies of every package.
  assert(not pkg.isMinimal)

  proc remove(pkg: PackageInfo, depTup: PkgTuple, thisDep: JsonNode) =
    for version, revDepsForVersion in thisDep:
      if version.newVersion in depTup.ver:
        for checksum, revDepsForChecksum in revDepsForVersion:
          var newVal = newJArray()
          for rd in revDepsForChecksum:
            # if the reverse dependency is different than the package which we
            # currently deleting, it will be kept.
            if rd[$ndjkRevDepName].str != pkg.name or
               rd[$ndjkRevDepVersion].str != pkg.specialVersion or
               rd[$ndjkRevDepChecksum].str != pkg.checksum:
              newVal.add rd
            revDepsForVersion[checksum] = newVal

  let reverseDependencies = nimbleData[$ndjkRevDep]

  for depTup in pkg.requires:
    if depTup.name.isURL():
      # We sadly must go through everything in this case...
      for key, val in reverseDependencies:
        remove(pkg, depTup, val)
    else:
      let thisDep = nimbleData{$ndjkRevDep, depTup.name}
      if thisDep.isNil: continue
      remove(pkg, depTup, thisDep)

  nimbleData[$ndjkRevDep] = cleanUpEmptyObjects(reverseDependencies)

proc getRevDepTups*(options: Options, pkg: PackageInfo): seq[PkgTuple] =
  ## Returns a list of *currently installed* reverse dependencies for `pkg`.
  result = @[]
  let thisPkgsDep = options.nimbleData[$ndjkRevDep]{
    pkg.name}{pkg.specialVersion}{pkg.checksum}
  if not thisPkgsDep.isNil:
    let pkgList = getInstalledPkgsMin(options.getPkgsDir(), options)
    for pkg in thisPkgsDep:
      let pkgTup = (
        name: pkg[$ndjkRevDepName].getStr(),
        ver: parseVersionRange(pkg[$ndjkRevDepVersion].getStr()),
        vcsRevision: ""
      )
      var pkgInfo: PackageInfo
      if not findPkg(pkgList, pkgTup, pkgInfo):
        continue

      result.add(pkgTup)

proc getRevDeps*(options: Options, pkg: PackageInfo): HashSet[PackageInfo] =
  result.init()
  let installedPkgs = getInstalledPkgsMin(options.getPkgsDir(), options)
  for rdepTup in getRevDepTups(options, pkg):
    for rdepInfo in findAllPkgs(installedPkgs, rdepTup):
      result.incl rdepInfo

proc getAllRevDeps*(options: Options, pkg: PackageInfo,
                    result: var HashSet[PackageInfo]) =
  if pkg in result:
    return

  let installedPkgs = getInstalledPkgsMin(options.getPkgsDir(), options)
  for rdepTup in getRevDepTups(options, pkg):
    for rdepInfo in findAllPkgs(installedPkgs, rdepTup):
      if rdepInfo in result:
        continue

      getAllRevDeps(options, rdepInfo, result)
  result.incl pkg

when isMainModule:

  import unittest
  import nimbledata

  let nimforum1 = PackageInfo(
    isMinimal: false,
    name: "nimforum",
    specialVersion: "0.1.0",
    requires: @[("jester", parseVersionRange("0.1.0"), ""),
                ("captcha", parseVersionRange("1.0.0"), ""),
                ("auth", parseVersionRange("#head"), "")],
    checksum: "46A96C3F2B0ECB3D3F7BD71E12200ED401E9B9F2",
    )

  let nimforum2 = PackageInfo(
    isMinimal: false,
    name: "nimforum",
    specialVersion: "0.2.0",
    checksum: "B60044137CEA185F287346EBEAB6B3E0895BDA4D",
    )

  let play = PackageInfo(
    isMinimal: false,
    name: "play",
    specialVersion: "#head",
    checksum: "8A54CCA572977ED0CC73B9BF783E9DFA6B6F2BF9"
    )

  proc setupNimbleData(): JsonNode =
    result = newNimbleDataNode()

    result.addRevDep(
      ("jester", "0.1.0", "1B629F98B23614DF292F176A1681FA439DCC05E2"),
      nimforum1)

    result.addRevDep(("jester", "0.1.0", ""), play)

    result.addRevDep(
      ("captcha", "1.0.0", "CE128561B06DD106A83638AD415A2A52548F388E"),
      nimforum1)

    result.addRevDep(
      ("auth", "#head", "C81545DF8A559E3DA7D38D125E0EAF2B4478CD01"),
      nimforum1)

    result.addRevDep(
      ("captcha", "1.0.0", "CE128561B06DD106A83638AD415A2A52548F388E"),
      nimforum2)

    result.addRevDep(
      ("auth", "#head", "C81545DF8A559E3DA7D38D125E0EAF2B4478CD01"),
      nimforum2)

  proc testAddRevDep() =

    let expectedResult = """{
        "version": "0.1.0",
        "reverseDeps": {
          "jester": {
            "0.1.0": {
              "1B629F98B23614DF292F176A1681FA439DCC05E2": [
                {
                  "name": "nimforum",
                  "version": "0.1.0",
                  "checksum": "46A96C3F2B0ECB3D3F7BD71E12200ED401E9B9F2"
                }
              ],
              "": [
                {
                  "name": "play",
                  "version": "#head",
                  "checksum": "8A54CCA572977ED0CC73B9BF783E9DFA6B6F2BF9"
                }
              ]
            }
          },
          "captcha": {
            "1.0.0": {
              "CE128561B06DD106A83638AD415A2A52548F388E": [
                {
                  "name": "nimforum",
                  "version": "0.1.0",
                  "checksum": "46A96C3F2B0ECB3D3F7BD71E12200ED401E9B9F2"
                },
                {
                  "name": "nimforum",
                  "version": "0.2.0",
                  "checksum": "B60044137CEA185F287346EBEAB6B3E0895BDA4D"
                }
              ]
            }
          },
          "auth": {
            "#head": {
              "C81545DF8A559E3DA7D38D125E0EAF2B4478CD01": [
                {
                  "name": "nimforum",
                  "version": "0.1.0",
                  "checksum": "46A96C3F2B0ECB3D3F7BD71E12200ED401E9B9F2"
                },
                {
                  "name": "nimforum",
                  "version": "0.2.0",
                  "checksum": "B60044137CEA185F287346EBEAB6B3E0895BDA4D"
                }
              ]
            }
          }
        }
      }""".parseJson()

    let nimbleData = setupNimbleData()
    check nimbleData == expectedResult

  proc testRemoveRevDep() =

    let expectedResult = """{
        "version": "0.1.0",
        "reverseDeps": {
          "jester": {
            "0.1.0": {
              "": [
                {
                  "name": "play",
                  "version": "#head",
                  "checksum": "8A54CCA572977ED0CC73B9BF783E9DFA6B6F2BF9"
                }
              ]
            }
          },
          "captcha": {
            "1.0.0": {
              "CE128561B06DD106A83638AD415A2A52548F388E": [
                {
                  "name": "nimforum",
                  "version": "0.2.0",
                  "checksum": "B60044137CEA185F287346EBEAB6B3E0895BDA4D"
                }
              ]
            }
          },
          "auth": {
            "#head": {
              "C81545DF8A559E3DA7D38D125E0EAF2B4478CD01": [
                {
                  "name": "nimforum",
                  "version": "0.2.0",
                  "checksum": "B60044137CEA185F287346EBEAB6B3E0895BDA4D"
                }
              ]
            }
          }
        }
      }""".parseJson()

    let nimbleData = setupNimbleData()
    nimbleData.removeRevDep(nimforum1)
    check nimbleData == expectedResult

  testAddRevDep()
  testRemoveRevDep()
  reportUnitTestSuccess()
