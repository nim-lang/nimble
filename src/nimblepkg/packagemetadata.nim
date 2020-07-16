# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import json, os, strformat
import common, packageinfotypes, cli, tools

type
  MetaDataError* = object of NimbleError

const
  packageMetaDataFileName* = "nimblemeta.json"

proc saveMetaData*(metaData: PackageMetaData, dirName: string) =
  ## Saves some important data to file in the package installation directory.
  var metaDataWithChangedPaths = metaData
  for i, file in metaData.files:
    metaDataWithChangedPaths.files[i] = changeRoot(dirName, "", file)
  let json = %metaDataWithChangedPaths
  writeFile(dirName / packageMetaDataFileName, json.pretty)

proc loadMetaData(dirName: string, raiseIfNotFound: bool): PackageMetaData =
  ## Returns package meta data read from file in package installation directory
  let fileName = dirName / packageMetaDataFileName
  if fileExists(fileName):
    let json = parseFile(fileName)
    result = json.to(result.typeof)
  elif raiseIfNotFound:
    raise newException(MetaDataError,
      &"No {packageMetaDataFileName} file found in {dirName}")
  else:
    display("Warning:", &"No {packageMetaDataFileName} file found in {dirName}",
             Warning, HighPriority)

proc fillMetaData*(packageInfo: var PackageInfo, dirName: string,
                   raiseIfNotFound: bool) =
  # Save the VCS revision possibly previously obtained in `initPackageInfo` from
  # the `.nimble` file directory to not be overridden from this read by meta
  # data file in the case the package is in develop mode.
  let vcsRevision = packageInfo.vcsRevision

  packageInfo.metaData = loadMetaData(dirName, raiseIfNotFound)

  if packageInfo.isLink:
    # If this is a linked package the real VCS revision from the `.nimble` file
    # directory obtained in `initPackageInfo` is the actual one, but not this
    # written in the package meta data in the time of the linking of the
    # package.
    packageInfo.vcsRevision = vcsRevision
