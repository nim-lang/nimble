# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import json, os, strformat
import common, options, jsonhelpers, version, cli

type
  NimbleDataJsonKeys* = enum
    ndjkVersion = "version"
    ndjkRevDep = "reverseDeps"
    ndjkRevDepName = "name"
    ndjkRevDepVersion = "version"
    ndjkRevDepChecksum = "checksum"
    ndjkRevDepPath = "path"

const
  nimbleDataFileName* = "nimbledata2.json"
  nimbleDataFileVersion = 1

var isNimbleDataFileLoaded = false

proc saveNimbleData(filePath: string, nimbleData: JsonNode) =
  # TODO: This file should probably be locked.
  if isNimbleDataFileLoaded:
    writeFile(filePath, nimbleData.pretty)
    displayInfo(&"Nimble data file \"{filePath}\" has been saved.", LowPriority)

proc saveNimbleDataToDir(nimbleDir: string, nimbleData: JsonNode) =
  saveNimbleData(nimbleDir / nimbleDataFileName, nimbleData)

proc saveNimbleData*(options: Options) =
  # Save nimbledata for the main nimbleDir only - fallback dirs must be read-only.
  saveNimbleDataToDir(options.getNimbleDir(), options.getNimbleData())

proc newNimbleDataNode*(): JsonNode =
  %{ $ndjkVersion: %nimbleDataFileVersion, $ndjkRevDep: newJObject() }

proc removeDeadDevelopReverseDeps*(options: var Options) =
  template revDeps: var JsonNode = options.getNimbleData()[$ndjkRevDep]
  var hasDeleted = false
  for name, versions in revDeps:
    for version, hashSums in versions:
      for hashSum, dependencies in hashSums:
        for dep in dependencies:
          if dep.hasKey($ndjkRevDepPath) and
             not dep[$ndjkRevDepPath].str.dirExists:
            dep.delete($ndjkRevDepPath)
            hasDeleted = true
  if hasDeleted:
    options.getNimbleData()[$ndjkRevDep] = cleanUpEmptyObjects(revDeps)

proc loadNimbleData*(options: var Options) =
  for nimbleDir in options.nimbleDirs:
    let fileName = nimbleDir / nimbleDataFileName

    if fileExists(fileName):
      options.nimbleData.add(parseFile(fileName))
      displayInfo(&"Nimble data file \"{fileName}\" has been loaded.",
                  LowPriority)
    else:
      displayWarning(&"Nimble data file \"{fileName}\" is not found.",
                     LowPriority)
      options.nimbleData.add(newNimbleDataNode())

  removeDeadDevelopReverseDeps(options)
  isNimbleDataFileLoaded = true
