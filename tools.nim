# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
#
# Various miscellaneous utility functions reside here.
import osproc, pegs, strutils, os, parseurl
import version, common, packageinfo

# TODO: Merge with common.nim?

proc doCmd*(cmd: string) =
  let exitCode = execCmd(cmd)
  if exitCode != QuitSuccess:
    raise newException(EBabel, "Execution failed with exit code " & $exitCode)

template cd*(dir: string, body: stmt) =
  ## Sets the current dir to ``dir``, executes ``body`` and restores the
  ## previous working dir.
  let lastDir = getCurrentDir()
  setCurrentDir(dir)
  body
  setCurrentDir(lastDir)

proc getNimrodVersion*: TVersion =
  let vOutput = execProcess("nimrod -v")
  var matches: array[0..MaxSubpatterns, string]
  if vOutput.find(peg"'Version'\s{(\d\.)+\d}", matches) == -1:
    quit("Couldn't find Nimrod version.", QuitFailure)
  newVersion(matches[0])

proc samePaths*(p1, p2: string): bool =
  ## Normalizes path (by adding a trailing slash) and compares.
  var cp1 = if not p1.endsWith("/"): p1 & "/" else: p1
  var cp2 = if not p2.endsWith("/"): p2 & "/" else: p2
  cp1 = cp1.replace('/', DirSep).replace('\\', DirSep)
  cp2 = cp2.replace('/', DirSep).replace('\\', DirSep)
  
  return cmpPaths(cp1, cp2) == 0

proc changeRoot*(origRoot, newRoot, path: string): string =
  ## origRoot: /home/dom/
  ## newRoot:  /home/test/
  ## path:     /home/dom/bar/blah/2/foo.txt
  ## Return value -> /home/test/bar/blah/2/foo.txt
  if path.startsWith(origRoot):
    return newRoot / path[origRoot.len .. -1]
  else:
    raise newException(EInvalidValue,
      "Cannot change root of path: Path does not begin with original root.")

proc getDownloadDirName*(url: string, verRange: PVersionRange): string =
  ## Creates a directory name based on the specified ``url``
  result = ""
  let purl = parseUrl(url)
  for i in purl.hostname:
    case i
    of strutils.Letters, strutils.Digits:
      result.add i
    else: nil
  result.add "_"
  for i in purl.path:
    case i
    of strutils.Letters, strutils.Digits:
      result.add i
    else: nil
  result.add "_"
  result.add getSimpleString(verRange)

proc getDownloadDirName*(pkg: TPackage, verRange: PVersionRange): string =
  result = pkg.name & "_" & verRange.getSimpleString