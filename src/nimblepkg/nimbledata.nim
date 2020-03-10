# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import json, os

type
  NimbleDataJsonKeys* = enum
    ndjkVersion = "version"
    ndjkRevDep = "reverseDeps"
    ndjkRevDepName = "name"
    ndjkRevDepVersion = "version"
    ndjkRevDepChecksum = "checksum"

const
  nimbleDataFile = (name: "nimbledata.json", version: "0.1.0")

proc saveNimbleData*(filePath: string, nimbleData: JsonNode) =
  # TODO: This file should probably be locked.
  writeFile(filePath, nimbleData.pretty)

proc saveNimbleDataToDir*(nimbleDir: string, nimbleData: JsonNode) =
  saveNimbleData(nimbleDir / nimbleDataFile.name, nimbleData)

proc newNimbleDataNode*(): JsonNode =
  %{ $ndjkVersion: %nimbleDataFile.version, $ndjkRevDep: newJObject() }

proc convertToTheNewFormat(nimbleData: JsonNode) =
  nimbleData.add($ndjkVersion, %nimbleDataFile.version)
  for name, versions in nimbleData[$ndjkRevDep]:
    for version, dependencies in versions:
      for dependency in dependencies:
        dependency.add($ndjkRevDepChecksum, %"")
      versions[version] = %{ "": dependencies }

proc parseNimbleData*(fileName: string): JsonNode =
  if fileExists(fileName):
    result = parseFile(fileName)
    if not result.hasKey($ndjkVersion):
      convertToTheNewFormat(result)
  else:
    result = newNimbleDataNode()

proc parseNimbleDataFromDir*(dir: string): JsonNode =
  parseNimbleData(dir / nimbleDataFile.name)
