# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
#
# Various miscellaneous utility functions reside here.
import osproc, pegs, strutils, os, uri, sets, json
import version, packageinfo, nimbletypes

proc doCmd*(cmd: string) =
  let bin = cmd.split(' ')[0]
  if findExe(bin) == "":
    raise newException(NimbleError, "'" & bin & "' not in PATH.")

  # To keep output in sequence
  stdout.flushFile()
  stderr.flushFile()

  let exitCode = execCmd(cmd)

  if exitCode != QuitSuccess:
    raise newException(NimbleError,
        "Execution failed with exit code " & $exitCode)

proc doCmdEx*(cmd: string): tuple[output: TaintedString, exitCode: int] =
  let bin = cmd.split(' ')[0]
  if findExe(bin) == "":
    raise newException(NimbleError, "'" & bin & "' not in PATH.")
  return execCmdEx(cmd)

template cd*(dir: string, body: stmt) =
  ## Sets the current dir to ``dir``, executes ``body`` and restores the
  ## previous working dir.
  let lastDir = getCurrentDir()
  setCurrentDir(dir)
  body
  setCurrentDir(lastDir)

proc getNimBin*: string =
  result = "nim"
  if findExe("nim") != "": result = findExe("nim")
  elif findExe("nimrod") != "": result = findExe("nimrod")

proc getNimrodVersion*: Version =
  let nimBin = getNimBin()
  let vOutput = doCmdEx(nimBin & " -v").output
  var matches: array[0..MaxSubpatterns, string]
  if vOutput.find(peg"'Version'\s{(\d+\.)+\d}", matches) == -1:
    quit("Couldn't find Nim version.", QuitFailure)
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
    return newRoot / path[origRoot.len .. path.len-1]
  else:
    raise newException(ValueError,
      "Cannot change root of path: Path does not begin with original root.")

proc copyFileD*(fro, to: string): string =
  ## Returns the destination (``to``).
  echo(fro, " -> ", to)
  copyFileWithPermissions(fro, to)
  result = to

proc copyDirD*(fro, to: string): seq[string] =
  ## Returns the filenames of the files in the directory that were copied.
  result = @[]
  echo("Copying directory: ", fro, " -> ", to)
  for path in walkDirRec(fro):
    createDir(changeRoot(fro, to, path.splitFile.dir))
    result.add copyFileD(path, changeRoot(fro, to, path))

proc getDownloadDirName*(uri: string, verRange: VersionRange): string =
  ## Creates a directory name based on the specified ``uri`` (url)
  result = ""
  let puri = parseUri(uri)
  for i in puri.hostname:
    case i
    of strutils.Letters, strutils.Digits:
      result.add i
    else: discard
  result.add "_"
  for i in puri.path:
    case i
    of strutils.Letters, strutils.Digits:
      result.add i
    else: discard

  let verSimple = getSimpleString(verRange)
  if verSimple != "":
    result.add "_"
    result.add verSimple

proc incl*(s: var HashSet[string], v: seq[string] | HashSet[string]) =
  for i in v:
    s.incl i

when not declared(json.contains):
  proc contains*(j: JsonNode, elem: JsonNode): bool =
    for i in j:
      if i == elem:
        return true

proc contains*(j: JsonNode, elem: tuple[key: string, val: JsonNode]): bool =
  for key, val in pairs(j):
    if key == elem.key and val == elem.val:
      return true
