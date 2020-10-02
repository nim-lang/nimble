# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import json, os, strformat
import common, packageinfotypes, cli, tools

type
  MetaDataError* = object of NimbleError

  PackageMetaDataJsonKeys = enum
    pmdjkVersion = "version"
    pmdjkMetaData = "metaData"

const
  packageMetaDataFileName* = "nimblemeta.json"
  packageMetaDataFileVersion = "0.1.0"

proc metaDataError(msg: string): ref MetaDataError =
  newNimbleError[MetaDataError](msg)

proc saveMetaData*(metaData: PackageMetaData, dirName: string) =
  ## Saves some important data to file in the package installation directory.
  var metaDataWithChangedPaths = to(metaData, PackageMetaDataV2)
  for i, file in metaData.files:
    metaDataWithChangedPaths.files[i] = changeRoot(dirName, "", file)
  let json = %{
    $pmdjkVersion: %packageMetaDataFileVersion,
    $pmdjkMetaData: %metaDataWithChangedPaths }
  writeFile(dirName / packageMetaDataFileName, json.pretty)

proc loadMetaData*(dirName: string, raiseIfNotFound: bool): PackageMetaData =
  ## Returns package meta data read from file in package installation directory
  let fileName = dirName / packageMetaDataFileName
  if fileExists(fileName):
    let json = parseFile(fileName)
    if not json.hasKey($pmdjkVersion):
      result = to(json.to(PackageMetaDataV1), PackageMetaData)
      let (_, specialVersion, _) = getNameVersionChecksum(dirName)
      result.specialVersion = specialVersion
    else:
      result = to(json[$pmdjkMetaData].to(PackageMetaDataV2), PackageMetaData)
  elif raiseIfNotFound:
    raise metaDataError(&"No {packageMetaDataFileName} file found in {dirName}")
  else:
    displayWarning(&"No {packageMetaDataFileName} file found in {dirName}")

proc fillMetaData*(packageInfo: var PackageInfo, dirName: string,
                   raiseIfNotFound: bool) =
  packageInfo.metaData = loadMetaData(dirName, raiseIfNotFound)
