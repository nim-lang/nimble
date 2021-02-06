# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
#
# Various miscellaneous utility functions reside here.
import osproc, pegs, strutils, os, uri, sets, json, parseutils
import version, cli, options
from net import SslCVerifyMode, newContext, SslContext

proc extractBin(cmd: string): string =
  if cmd[0] == '"':
    return cmd.captureBetween('"')
  else:
    return cmd.split(' ')[0]

proc doCmd*(cmd: string) =
  let
    bin = extractBin(cmd)
    isNim = bin.extractFilename().startsWith("nim")
  if findExe(bin) == "":
    raise newException(NimbleError, "'" & bin & "' not in PATH.")

  # To keep output in sequence
  stdout.flushFile()
  stderr.flushFile()

  if isNim:
    # Show no command line and --hints:off output by default for calls
    # to Nim, command line and standard output with --verbose.
    display("Executing", cmd, priority = MediumPriority)
    let exitCode = execCmd(cmd)
    if exitCode != QuitSuccess:
      raise newException(NimbleError,
        "Execution failed with exit code $1\nCommand: $2" %
        [$exitCode, cmd])
  else:
    displayDebug("Executing", cmd)
    let (output, exitCode) = execCmdEx(cmd)
    displayDebug("Output", output)
    if exitCode != QuitSuccess:
      raise newException(NimbleError,
        "Execution failed with exit code $1\nCommand: $2\nOutput: $3" %
        [$exitCode, cmd, output])

{.warning[Deprecated]: off.}
proc doCmdEx*(cmd: string): tuple[output: TaintedString, exitCode: int] =
  let bin = extractBin(cmd)
  if findExe(bin) == "":
    raise newException(NimbleError, "'" & bin & "' not in PATH.")
  return execCmdEx(cmd)

template cd*(dir: string, body: untyped) =
  ## Sets the current dir to ``dir``, executes ``body`` and restores the
  ## previous working dir.
  let lastDir = getCurrentDir()
  setCurrentDir(dir)
  body
  setCurrentDir(lastDir)

proc getNimrodVersion*(options: Options): Version =
  let vOutput = doCmdEx(getNimBin(options).quoteShell & " -v").output
  var matches: array[0..MaxSubpatterns, string]
  if vOutput.find(peg"'Version'\s{(\d+\.)+\d+}", matches) == -1:
    raise newException(NimbleError, "Couldn't find Nim version.")
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

  ## The additional check of `path.samePaths(origRoot)` is necessary to prevent
  ## a regression, where by ending the `srcDir` defintion in a nimble file in a
  ## trailing separator would cause the `path.startsWith(origRoot)` evaluation to
  ## fail because of the value of `origRoot` would be longer than `path` due to
  ## the trailing separator. This would cause this method to throw during package
  ## installation.
  if path.startsWith(origRoot) or path.samePaths(origRoot):
    return newRoot / path.substr(origRoot.len, path.len-1)
  else:
    raise newException(ValueError,
      "Cannot change root of path: Path does not begin with original root.")

proc copyFileD*(fro, to: string): string =
  ## Returns the destination (``to``).
  display("Copying", "file $# to $#" % [fro, to], priority = LowPriority)
  copyFileWithPermissions(fro, to)
  result = to

proc copyDirD*(fro, to: string): seq[string] =
  ## Returns the filenames of the files in the directory that were copied.
  result = @[]
  display("Copying", "directory $# to $#" % [fro, to], priority = LowPriority)
  for path in walkDirRec(fro):
    createDir(changeRoot(fro, to, path.splitFile.dir))
    result.add copyFileD(path, changeRoot(fro, to, path))

proc createDirD*(dir: string) =
  display("Creating", "directory $#" % dir, priority = LowPriority)
  createDir(dir)

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

proc getNimbleTempDir*(): string =
  ## Returns a path to a temporary directory.
  ##
  ## The returned path will be the same for the duration of the process but
  ## different for different runs of it. You have to make sure to create it
  ## first. In release builds the directory will be removed when nimble finishes
  ## its work.
  result = getTempDir() / "nimble_" & $getCurrentProcessId()

proc getNimbleUserTempDir*(): string =
  ## Returns a path to a temporary directory.
  ##
  ## The returned path will be the same for the duration of the process but
  ## different for different runs of it. You have to make sure to create it
  ## first. In release builds the directory will be removed when nimble finishes
  ## its work.
  var tmpdir: string
  if existsEnv("TMPDIR") and existsEnv("USER"):
    tmpdir = joinPath(getEnv("TMPDIR"), getEnv("USER"))
  else:
    tmpdir = getTempDir()
  return tmpdir

proc newSSLContext*(disabled: bool): SslContext =
  var sslVerifyMode = CVerifyPeer
  if disabled:
    display("Warning:", "disabling SSL certificate checking", Warning)
    sslVerifyMode = CVerifyNone
  return newContext(verifyMode = sslVerifyMode)
