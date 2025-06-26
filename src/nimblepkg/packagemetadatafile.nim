# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import json, os, strformat, sets, sequtils
import common, version, packageinfotypes, cli, tools, sha1hashes, options

type
  MetaDataError* = object of NimbleError

  PackageMetaDataJsonKeys = enum
    pmdjkVersion = "version"
    pmdjkMetaData = "metaData"

const
  packageMetaDataFileName* = "nimblemeta.json"
  packageMetaDataFileVersion = 1

proc initPackageMetaData*(): PackageMetaData =
  result = PackageMetaData(
    vcsRevision: notSetSha1Hash)

proc metaDataError(msg: string): ref MetaDataError =
  newNimbleError[MetaDataError](msg)

proc `%`(specialVersions: HashSet[Version]): JsonNode =
  %specialVersions.toSeq

proc initFromJson(specialVersions: var HashSet[Version], jsonNode: JsonNode,
                  jsonPath: var string) =
  case jsonNode.kind
  of JArray:
    let originalJsonPathLen = jsonPath.len
    for i in 0 ..< jsonNode.len:
      jsonPath.add '['
      jsonPath.addInt i
      jsonPath.add ']'
      var version = newVersion("")
      initFromJson(version, jsonNode[i], jsonPath)
      specialVersions.incl version
      jsonPath.setLen originalJsonPathLen
  else:
    assert false, "The `jsonNode` must be of kind JArray."

proc saveMetaData*(metaData: PackageMetaData, dirName: string,
                   changeRoots = true) =
  ## Saves some important data to file in the package installation directory.
  var metaDataWithChangedPaths = metaData
  if changeRoots:
    for i, file in metaData.files:
      metaDataWithChangedPaths.files[i] = changeRoot(dirName, "", file)
  let json = %{
    $pmdjkVersion: %packageMetaDataFileVersion,
    $pmdjkMetaData: %metaDataWithChangedPaths}
  writeFile(dirName / packageMetaDataFileName, json.pretty)

proc loadMetaData*(dirName: string, raiseIfNotFound: bool, options: Options): PackageMetaData =
  ## Returns package meta data read from file in package installation directory
  result = initPackageMetaData()
  let fileName = dirName / packageMetaDataFileName
  if fileExists(fileName):
    {.warning[ProveInit]: off.}
    {.warning[UnsafeSetLen]: off.}
    result = parseFile(fileName)[$pmdjkMetaData].to(PackageMetaData)
    {.warning[UnsafeSetLen]: on.}
    {.warning[ProveInit]: on.}
  elif raiseIfNotFound:
    raise metaDataError(&"No {packageMetaDataFileName} file found in {dirName}")
  else:
    # Only show warning for installed packages (in pkgsDir) or Nim binaries dir
    # development packages don't need nimblemeta.json files
    if dirName.isSubdirOf(options.getPkgsDir()) and not dirName.isSubdirOf(options.nimBinariesDir):
      displayWarning(&"No {packageMetaDataFileName} file found in {dirName}")

proc fillMetaData*(packageInfo: var PackageInfo, dirName: string,
                   raiseIfNotFound: bool, options: Options) =
  packageInfo.metaData = loadMetaData(dirName, raiseIfNotFound, options)
