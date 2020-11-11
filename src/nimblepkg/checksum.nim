# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import os, strutils, std/sha1, algorithm, strformat
import common, tools, sha1hashes

type
  ChecksumError* = object of NimbleError

proc checksumError*(name, version: string,
                    vcsRevision, checksum, expectedChecksum: Sha1Hash):
    ref ChecksumError =
  result = newNimbleError[ChecksumError](&"""
Downloaded package checksum does not correspond to that in the lock file:
  Package:           {name}@v.{version}@r.{vcsRevision}
  Checksum:          {checksum}
  Expected checksum: {expectedChecksum}
""")

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
  if not fileName.fileExists:
    # In some cases a file name returned by `git ls-files` or `hg manifest`
    # could be an empty directory name and if so trying to open it will result
    # in a crash. This happens for example in the case of a git sub module
    # directory from which no files are being installed.
    return
  let file = fileName.open(fmRead)
  defer: close(file)
  const bufferSize = 8192
  var buffer = newString(bufferSize)
  while true:
    var bytesRead = readChars(file, buffer)
    if bytesRead == 0: break
    checksum.update(buffer[0..<bytesRead])

proc calculatePackageSha1Checksum*(dir: string): Sha1Hash =
  cd dir:
    let packageFiles = getPackageFileList()
    var checksum = newSha1State()
    for file in packageFiles:
      updateSha1Checksum(checksum, file)
    result = initSha1Hash($SecureHash(checksum.finalize()))
