# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import json, sets, os, hashes, unicode

import options, version, download, jsonhelpers, nimbledatafile,
       packageinfotypes, packageinfo, packageparser

type
  ReverseDependencyKind* = enum
    rdkInstalled,
    rdkDevelop,

  ReverseDependency* = object
    ## Represents a reverse dependency info containing name, version and
    ## checksum for the installed packages or the path to the package directory
    ## for the reverse dependencies.
    case kind*: ReverseDependencyKind
    of rdkInstalled:
      pkgInfo*: PackageBasicInfo
    of rdkDevelop:
      pkgPath*: string

proc hash*(revDep: ReverseDependency): Hash =
  case revDep.kind
  of rdkInstalled:
    result = revDep.pkgInfo.getCacheDir.hash
  of rdkDevelop:
    result = revDep.pkgPath.hash

proc `==`*(lhs, rhs: ReverseDependency): bool =
  if lhs.kind != rhs.kind:
    return false
  case lhs.kind:
  of rdkInstalled:
    return lhs.pkgInfo == rhs.pkgInfo
  of rdkDevelop:
    return lhs.pkgPath == rhs.pkgPath

proc `$`*(revDep: ReverseDependency): string =
  case revDep.kind
  of rdkInstalled:
    result = revDep.pkgInfo.getCacheDir
  of rdkDevelop:
    result = revDep.pkgPath

proc addRevDep*(nimbleData: JsonNode, dep: PackageBasicInfo,
                pkg: PackageInfo) =
  # Add a record which specifies that `pkg` has a dependency on `dep`, i.e.
  # the reverse dependency of `dep` is `pkg`.

  let dependencies = nimbleData.addIfNotExist(
    $ndjkRevDep,
    dep.name.toLower,
    dep.version,
    dep.checksum,
    newJArray())

  var dependency: JsonNode
  if not pkg.isLink:
    dependency = %{
      $ndjkRevDepName: %pkg.name.toLower,
      $ndjkRevDepVersion: %pkg.version,
      $ndjkRevDepChecksum: %pkg.checksum}
  else:
    dependency = %{ $ndjkRevDepPath: %pkg.getNimbleFileDir().absolutePath }

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
            # If the reverse dependency is different than the package which we
            # currently deleting, it will be kept.
            if rd.hasKey($ndjkRevDepPath):
              # This is a develop mode reverse dependency.
              if rd[$ndjkRevDepPath].str != pkg.getNimbleFileDir:
                # It is compared by its directory path.
                newVal.add rd
            elif rd[$ndjkRevDepChecksum].str != pkg.checksum:
              # For the reverse dependencies added since the introduction of the
              # new format comparison of the checksums is specific enough.
              newVal.add rd
            else:
              # But if the both checksums are not present, those are converted
              # from the old format packages and they must be compared by the
              # `name` and `specialVersion` fields.
              if rd[$ndjkRevDepChecksum].str.len == 0 and pkg.checksum.len == 0:
                if rd[$ndjkRevDepName].str != pkg.name.toLower or
                   rd[$ndjkRevDepVersion].str != pkg.specialVersion:
                  newVal.add rd
          revDepsForVersion[checksum] = newVal

  let reverseDependencies = nimbleData[$ndjkRevDep]

  for depTup in pkg.requires:
    if depTup.name.isURL():
      # We sadly must go through everything in this case...
      for key, val in reverseDependencies:
        remove(pkg, depTup, val)
    else:
      let thisDep = nimbleData{$ndjkRevDep, depTup.name.toLower}
      if thisDep.isNil: continue
      remove(pkg, depTup, thisDep)

  nimbleData[$ndjkRevDep] = cleanUpEmptyObjects(reverseDependencies)

proc getRevDeps*(nimbleData: JsonNode, pkg: ReverseDependency):
    HashSet[ReverseDependency] =
  ## Returns a list of *currently installed* or *develop mode* reverse
  ## dependencies for `pkg`.

  if pkg.kind == rdkDevelop:
    return

  let reverseDependencies = nimbleData[$ndjkRevDep]{
    pkg.pkgInfo.name.toLower}{pkg.pkgInfo.version}{pkg.pkgInfo.checksum}

  if reverseDependencies.isNil:
    return

  for revDep in reverseDependencies:
    if revDep.hasKey($ndjkRevDepPath):
      # This is a develop mode package.
      let path = revDep[$ndjkRevDepPath].str
      result.incl ReverseDependency(kind: rdkDevelop, pkgPath: path)
    else:
      # This is an installed package.
      let pkgBasicInfo = (name: revDep[$ndjkRevDepName].str,
                          version: revDep[$ndjkRevDepVersion].str,
                          checksum: revDep[$ndjkRevDepChecksum].str)
      result.incl ReverseDependency(kind: rdkInstalled, pkgInfo: pkgBasicInfo)

proc toPkgInfo*(revDep: ReverseDependency, options: Options): PackageInfo =
  case revDep.kind
  of rdkInstalled:
    let pkgDir = revDep.pkgInfo.getPkgDest(options)
    result = getPkgInfo(pkgDir, options)
  of rdkDevelop:
    result = getPkgInfo(revDep.pkgPath, options)

proc toRevDep*(pkg: PackageInfo): ReverseDependency =
  if not pkg.isLink:
    result = ReverseDependency(
      kind: rdkInstalled,
      pkgInfo: (pkg.name, pkg.version, pkg.checksum))
  else:
    result = ReverseDependency(
      kind: rdkDevelop,
      pkgPath: pkg.getNimbleFileDir)

proc getAllRevDeps*(nimbleData: JsonNode, pkg: ReverseDependency,
                    result: var HashSet[ReverseDependency]) =
  result.incl pkg
  let revDeps = getRevDeps(nimbleData, pkg)
  for revDep in revDeps:
    if revDep in result: continue
    getAllRevDeps(nimbleData, revDep, result)

when isMainModule:
  import unittest

  let
    nimforum1 = PackageInfo(
      basicInfo:
        ("nimforum", "0.1.0", "46A96C3F2B0ECB3D3F7BD71E12200ED401E9B9F2"),
      requires: @[("jester", parseVersionRange("0.1.0")),
                  ("captcha", parseVersionRange("1.0.0")),
                  ("auth", parseVersionRange("#head"))])

    nimforum1RevDep = nimforum1.toRevDep

    nimforum2 = PackageInfo(basicInfo:
      ("nimforum", "0.2.0", "B60044137CEA185F287346EBEAB6B3E0895BDA4D"))

    nimforum2RevDep = nimforum2.toRevDep

    play = PackageInfo(
      basicInfo: ("play", "2.0.1", "8A54CCA572977ED0CC73B9BF783E9DFA6B6F2BF9"))

    nimforumDevelop = PackageInfo(
      myPath: "/some/absolute/system/path/nimforum/nimforum.nimble",
      metaData: PackageMetaData(isLink: true),
      requires: @[("captcha", parseVersionRange("1.0.0"))])

    nimforumDevelopRevDep = nimforumDevelop.toRevDep

    jester = PackageInfo(basicInfo:
      ("jester", "0.1.0", "1B629F98B23614DF292F176A1681FA439DCC05E2"))
    
    jesterWithoutSha1 = PackageInfo(basicInfo: ("jester", "0.1.0", ""))

    captcha = PackageInfo(basicInfo:
      ("captcha", "1.0.0", "CE128561B06DD106A83638AD415A2A52548F388E"))

    captchaRevDep = captcha.toRevDep
    
    auth = PackageInfo(
      basicInfo: ("auth", "#head", "C81545DF8A559E3DA7D38D125E0EAF2B4478CD01"))

    authRevDep = auth.toRevDep

  suite "reverse dependencies":
    setup:
      var nimbleData = newNimbleDataNode()
      nimbleData.addRevDep(jester.basicInfo, nimforum1)
      nimbleData.addRevDep(jesterWithoutSha1.basicInfo, play)
      nimbleData.addRevDep(captcha.basicInfo, nimforum1)
      nimbleData.addRevDep(captcha.basicInfo, nimforum2)
      nimbleData.addRevDep(captcha.basicInfo, nimforumDevelop)
      nimbleData.addRevDep(auth.basicInfo, nimforum1)
      nimbleData.addRevDep(auth.basicInfo, nimforum2)
      nimbleData.addRevDep(auth.basicInfo, captcha)

    test "addRevDep":
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
                    "version": "2.0.1",
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
                  },
                  {
                    "path": "/some/absolute/system/path/nimforum"
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
                  },
                  {
                    "name": "captcha",
                    "version": "1.0.0",
                    "checksum": "CE128561B06DD106A83638AD415A2A52548F388E"
                  }
                ]
              }
            }
          }
        }""".parseJson()

      check nimbleData == expectedResult

    test "removeRevDep":
      let expectedResult = """{
          "version": "0.1.0",
          "reverseDeps": {
            "jester": {
              "0.1.0": {
                "": [
                  {
                    "name": "play",
                    "version": "2.0.1",
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
                  },
                  {
                    "name": "captcha",
                    "version": "1.0.0",
                    "checksum": "CE128561B06DD106A83638AD415A2A52548F388E"
                  }
                ]
              }
            }
          }
        }""".parseJson()

      nimbleData.removeRevDep(nimforum1)
      nimbleData.removeRevDep(nimforumDevelop)
      check nimbleData == expectedResult

    test "getRevDeps":
      check nimbleData.getRevDeps(nimforumDevelopRevDep) ==
            HashSet[ReverseDependency]()
      check nimbleData.getRevDeps(captchaRevDep) ==
            [nimforum1RevDep, nimforum2RevDep, nimforumDevelopRevDep].toHashSet

    test "getAllRevDeps":
      var revDeps: HashSet[ReverseDependency]
      nimbleData.getAllRevDeps(authRevDep, revDeps)
      check revDeps == [authRevDep, nimforum1RevDep, nimforum2RevDep,
                        nimforumDevelopRevDep, captchaRevDep].toHashSet
  