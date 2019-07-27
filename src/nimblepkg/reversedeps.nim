# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import os, json, sets

import options, common, version, download, packageinfo

proc saveNimbleData*(options: Options) =
  # TODO: This file should probably be locked.
  writeFile(options.getNimbleDir() / "nimbledata.json",
            pretty(options.nimbleData))

proc addRevDep*(nimbleData: JsonNode, dep: tuple[name, version: string],
                pkg: PackageInfo) =
  # Add a record which specifies that `pkg` has a dependency on `dep`, i.e.
  # the reverse dependency of `dep` is `pkg`.
  if not nimbleData["reverseDeps"].hasKey(dep.name):
    nimbleData["reverseDeps"][dep.name] = newJObject()
  if not nimbleData["reverseDeps"][dep.name].hasKey(dep.version):
    nimbleData["reverseDeps"][dep.name][dep.version] = newJArray()
  let revDep = %{ "name": %pkg.name, "version": %pkg.specialVersion}
  let thisDep = nimbleData["reverseDeps"][dep.name][dep.version]
  if revDep notin thisDep:
    thisDep.add revDep

proc removeRevDep*(nimbleData: JsonNode, pkg: PackageInfo) =
  ## Removes ``pkg`` from the reverse dependencies of every package.
  assert(not pkg.isMinimal)
  proc remove(pkg: PackageInfo, depTup: PkgTuple, thisDep: JsonNode) =
    for ver, val in thisDep:
      if ver.newVersion in depTup.ver:
        var newVal = newJArray()
        for revDep in val:
          if not (revDep["name"].str == pkg.name and
                  revDep["version"].str == pkg.specialVersion):
            newVal.add revDep
        thisDep[ver] = newVal

  for depTup in pkg.requires:
    if depTup.name.isURL():
      # We sadly must go through everything in this case...
      for key, val in nimbleData["reverseDeps"]:
        remove(pkg, depTup, val)
    else:
      let thisDep = nimbleData{"reverseDeps", depTup.name}
      if thisDep.isNil: continue
      remove(pkg, depTup, thisDep)

  # Clean up empty objects/arrays
  var newData = newJObject()
  for key, val in nimbleData["reverseDeps"]:
    if val.len != 0:
      var newVal = newJObject()
      for ver, elem in val:
        if elem.len != 0:
          newVal[ver] = elem
      if newVal.len != 0:
        newData[key] = newVal
  nimbleData["reverseDeps"] = newData

proc getRevDepTups*(options: Options, pkg: PackageInfo): seq[PkgTuple] =
  ## Returns a list of *currently installed* reverse dependencies for `pkg`.
  result = @[]
  let thisPkgsDep =
    options.nimbleData["reverseDeps"]{pkg.name}{pkg.specialVersion}
  if not thisPkgsDep.isNil:
    let pkgList = getInstalledPkgsMin(options.getPkgsDir(), options)
    for pkg in thisPkgsDep:
      let pkgTup = (
        name: pkg["name"].getStr(),
        ver: parseVersionRange(pkg["version"].getStr())
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

proc getAllRevDeps*(options: Options, pkg: PackageInfo, result: var HashSet[PackageInfo]) =
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
  var nimbleData = %{"reverseDeps": newJObject()}

  let nimforum1 = PackageInfo(
    isMinimal: false,
    name: "nimforum",
    specialVersion: "0.1.0",
    requires: @[("jester", parseVersionRange("0.1.0")),
                ("captcha", parseVersionRange("1.0.0")),
                ("auth", parseVersionRange("#head"))]
  )
  let nimforum2 = PackageInfo(isMinimal: false, name: "nimforum", specialVersion: "0.2.0")
  let play = PackageInfo(isMinimal: false, name: "play", specialVersion: "#head")

  nimbleData.addRevDep(("jester", "0.1.0"), nimforum1)
  nimbleData.addRevDep(("jester", "0.1.0"), play)
  nimbleData.addRevDep(("captcha", "1.0.0"), nimforum1)
  nimbleData.addRevDep(("auth", "#head"), nimforum1)
  nimbleData.addRevDep(("captcha", "1.0.0"), nimforum2)
  nimbleData.addRevDep(("auth", "#head"), nimforum2)

  doAssert nimbleData["reverseDeps"]["jester"]["0.1.0"].len == 2
  doAssert nimbleData["reverseDeps"]["captcha"]["1.0.0"].len == 2
  doAssert nimbleData["reverseDeps"]["auth"]["#head"].len == 2

  block:
    nimbleData.removeRevDep(nimforum1)
    let jester = nimbleData["reverseDeps"]["jester"]["0.1.0"][0]
    doAssert jester["name"].getStr() == play.name
    doAssert jester["version"].getStr() == play.specialVersion

    let captcha = nimbleData["reverseDeps"]["captcha"]["1.0.0"][0]
    doAssert captcha["name"].getStr() == nimforum2.name
    doAssert captcha["version"].getStr() == nimforum2.specialVersion

  echo("Everything works!")

