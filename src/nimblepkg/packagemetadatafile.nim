# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import json, os, strformat
import common, version, packageinfotypes, cli, tools, sha1hashes

type
  MetaDataError* = object of NimbleError

  PackageMetaDataJsonKeys = enum
    pmdjkVersion = "version"
    pmdjkMetaData = "metaData"

const
  packageMetaDataFileName* = "nimblemeta.json"
  packageMetaDataFileVersion = "0.1.0"

proc initPackageMetaData*(): PackageMetaData =
  result = PackageMetaData(
    specialVersion: notSetVersion,
    vcsRevision: notSetSha1Hash)

proc metaDataError(msg: string): ref MetaDataError =
  newNimbleError[MetaDataError](msg)

proc saveMetaData*(metaData: PackageMetaData, dirName: string) =
  ## Saves some important data to file in the package installation directory.
  var metaDataWithChangedPaths = metaData
  for i, file in metaData.files:
    metaDataWithChangedPaths.files[i] = changeRoot(dirName, "", file)
  let json = %{
    $pmdjkVersion: %packageMetaDataFileVersion,
    $pmdjkMetaData: %metaDataWithChangedPaths }
  writeFile(dirName / packageMetaDataFileName, json.pretty)

proc loadMetaData*(dirName: string, raiseIfNotFound: bool): PackageMetaData =
  ## Returns package meta data read from file in package installation directory
  result = initPackageMetaData()
  let fileName = dirName / packageMetaDataFileName
  if fileExists(fileName):
    {.warning[ProveInit]: off.}
    result = parseFile(fileName)[$pmdjkMetaData].to(PackageMetaData)
    {.warning[ProveInit]: on.}
  elif raiseIfNotFound:
    raise metaDataError(&"No {packageMetaDataFileName} file found in {dirName}")
  else:
    displayWarning(&"No {packageMetaDataFileName} file found in {dirName}")

proc fillMetaData*(packageInfo: var PackageInfo, dirName: string,
                   raiseIfNotFound: bool) =
  packageInfo.metaData = loadMetaData(dirName, raiseIfNotFound)
