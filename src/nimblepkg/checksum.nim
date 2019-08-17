# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import os, strutils, std/sha1, algorithm
import tools

proc extractFileList(consoleOutput: string): seq[string] =
  result = consoleOutput.splitLines()
  discard result.pop()

proc getPackageFileListFromGit(): seq[string] =
  let output = tryDoCmdEx("git ls-files")
  extractFileList(string(output))

proc getPackageFileListFromMercurial(): seq[string] =
  let output = tryDoCmdEx("hg manifest")
  extractFileList(string(output))

proc getPackageFileListWithoutScm(): seq[string] =
  for file in walkDirRec(".", relative = true):
    result.add(file)

proc getPackageFileList(): seq[string] =
  if existsDir(".git"):
    result = getPackageFileListFromGit()
  elif existsDir(".hg"):
    result = getPackageFileListFromMercurial()
  else:
    result = getPackageFileListWithoutScm()
  result.sort()

proc updateSha1Checksum(checksum: var Sha1State, fileName: string) =
  checksum.update(fileName)
  let file = fileName.open(fmRead)
  defer: close(file)
  const bufferSize = 8192
  var buffer = newString(bufferSize)
  while true:
    var bytesRead = readChars(file, buffer, 0, bufferSize)
    if bytesRead == 0: break
    checksum.update(buffer[0..<bytesRead])

proc calculatePackageSha1Checksum*(dir: string): string =
  cd dir:
    let packageFiles = getPackageFileList()
    var checksum = newSha1State()
    for file in packageFiles:
      updateSha1Checksum(checksum, file)
    result = $SecureHash(checksum.finalize())
