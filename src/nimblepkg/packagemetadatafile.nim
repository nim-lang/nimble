# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import os, strformat, sets, sequtils, tables
import common, version, packageinfotypes, cli, tools, sha1hashes, options
import compat/json

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

proc `%`(features: Table[string, seq[string]]): JsonNode =
  result = newJObject()
  for k, v in features:
    result[k] = %v

proc initFromJson(features: var Table[string, seq[string]], jsonNode: JsonNode,
                  jsonPath: var string) =
  features = initTable[string, seq[string]]()
  if jsonNode.kind == JObject:
    for k, v in jsonNode:
      var seqVal: seq[string]
      if v.kind == JArray:
        for item in v:
          if item.kind == JString:
            seqVal.add item.str
      features[k] = seqVal

proc initFromJson(dst: var PackageMetaData, jsonNode: JsonNode, jsonPath: var string) =
  ## Custom initFromJson that tolerates missing fields for backward compatibility.
  if jsonNode.kind != JObject: return
  for key, val in jsonNode:
    case key
    of "url": dst.url = val.getStr
    of "downloadMethod": 
      if val.kind == JString:
        case val.str
        of "git": dst.downloadMethod = git
        of "hg": dst.downloadMethod = hg
    of "vcsRevision": initFromJson(dst.vcsRevision, val, jsonPath)
    of "files":
      if val.kind == JArray:
        for item in val: dst.files.add item.getStr
    of "binaries":
      if val.kind == JArray:
        for item in val: dst.binaries.add item.getStr
    of "specialVersions": initFromJson(dst.specialVersions, val, jsonPath)
    of "requires":
      if val.kind == JArray:
        for item in val: dst.requires.add item.getStr
    of "features": initFromJson(dst.features, val, jsonPath)
    of "srcDir": dst.srcDir = val.getStr
    of "paths":
      if val.kind == JArray:
        for item in val: dst.paths.add item.getStr
    of "preHooks":
      if val.kind == JArray:
        for item in val: dst.preHooks.add item.getStr
    of "postHooks":
      if val.kind == JArray:
        for item in val: dst.postHooks.add item.getStr
    of "nestedRequires": dst.nestedRequires = val.getBool

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
      #dont show warning for global package install
      if findNimbleFile(dirName, error = false, options, warn = false) != "":
        displayWarning(&"No {packageMetaDataFileName} file found in {dirName}")

proc fillMetaData*(packageInfo: var PackageInfo, dirName: string,
                   raiseIfNotFound: bool, options: Options) =
  packageInfo.metaData = loadMetaData(dirName, raiseIfNotFound, options)
