# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import os, strutils, std/sha1, algorithm, strformat
import common, tools

type
  ChecksumError* = object of NimbleError

proc raiseChecksumError*(name, version, vcsRevision,
                         checksum, expectedChecksum: string) =
  var error = newException(ChecksumError,
fmt"""
Downloaded package checksum does not correspond to that in the lock file:
  Package:           {name}@v{version}@r{vcsRevision}
  Checksum:          {checksum}
  Expected checksum: {expectedChecksum}
""")
  raise error

proc extractFileList(consoleOutput: string): seq[string] =
  result = consoleOutput.splitLines()
  discard result.pop()

proc getPackageFileListFromGit(): seq[string] =
  let output = tryDoCmdEx("git ls-files")
  extractFileList(output)

proc getPackageFileListFromMercurial(): seq[string] =
  let output = tryDoCmdEx("hg manifest")
  extractFileList(output)

proc getPackageFileListWithoutScm(): seq[string] =
  for file in walkDirRec(".", relative = true):
    result.add(file)

proc getPackageFileList(): seq[string] =
  if dirExists(".git"):
    result = getPackageFileListFromGit()
  elif dirExists(".hg"):
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
    var bytesRead = readChars(file, buffer)
    if bytesRead == 0: break
    checksum.update(buffer[0..<bytesRead])

proc calculatePackageSha1Checksum*(dir: string): string =
  cd dir:
    let packageFiles = getPackageFileList()
    var checksum = newSha1State()
    for file in packageFiles:
      updateSha1Checksum(checksum, file)
    result = $SecureHash(checksum.finalize())
