# Copyright (C) Andreas Rumpf. All rights reserved.
# BSD License. Look at license.txt for more info.

## Implements the new configuration system for Nimble. Uses Nim as a
## scripting language.

import common, version, options, packageinfo, cli
import hashes, json, os, strutils, strtabs, tables, times, osproc, sets, pegs

type
  Flags = TableRef[string, seq[string]]
  ExecutionResult*[T] = object
    success*: bool
    command*: string
    arguments*: seq[string]
    flags*: Flags
    retVal*: T

const
  internalCmd = "e"
  nimscriptApi = staticRead("nimscriptapi.nim")
  nimscriptHash = $nimscriptApi.hash().abs()

proc execNimscript(nimsFile, actionName: string, options: Options): tuple[output: string, exitCode: int] =
  let
    cmd = "nim e --verbosity:0 " & nimsFile.quoteShell & " " & actionName

  result = execCmdEx(cmd)

proc setupNimscript*(scriptName: string, options: Options): tuple[nimsFile, iniFile: string] =
  let
    cacheDir = getTempDir() / "nimblecache"
    shash = $(scriptName & nimscriptHash).hash().abs()
    prjCacheDir = cacheDir / scriptName.splitFile().name & "_" & shash
    nimsCacheFile = prjCacheDir / scriptName.extractFilename().changeFileExt ".nims"

  result.nimsFile = scriptName.parentDir() / scriptName.splitFile().name & "_" & shash & ".nims"
  result.iniFile = prjCacheDir / scriptName.extractFilename().changeFileExt ".ini"

  if not prjCacheDir.dirExists() or not nimsCacheFile.fileExists() or not result.iniFile.fileExists() or
    scriptName.getLastModificationTime() > nimsCacheFile.getLastModificationTime():
    createDir(prjCacheDir)
    writeFile(nimsCacheFile, nimscriptApi & scriptName.readFile() & "\nonExit()\n")
    discard tryRemoveFile(result.iniFile)

  if not result.nimsFile.fileExists():
    nimsCacheFile.copyFile(result.nimsFile)

  if not result.iniFile.fileExists():
    let
      (output, exitCode) = result.nimsFile.execNimscript("printPkgInfo", options)

    if exitCode == 0 and output.len != 0:
      result.iniFile.writeFile(output)
    else:
      raise newException(NimbleError, output & "\nprintPkgInfo() failed")

proc execScript*(scriptName, actionName: string, options: Options): ExecutionResult[bool] =
  let
    (nimsFile, iniFile) = setupNimscript(scriptName, options)

    (output, exitCode) = nimsFile.execNimscript(actionName, options)

  if exitCode != 0:
    raise newException(NimbleError, output)

  let
    lines = output.strip().splitLines()
    j =
      if lines.len != 0:
        parseJson(lines[^1])
      else:
        parseJson("{}")

  result.success = true
  if "command" in j:
    result.command = $j["command"]
  else:
    result.command = internalCmd
  if "project" in j:
    result.arguments.add $j["project"]
  if "retVal" in j:
    result.retVal = j["retVal"].getBool()
  result.flags = newTable[string, seq[string]]()

  if lines.len > 1:
    stdout.writeLine lines[0 .. ^2].join("\n")

  nimsFile.removeFile()

proc execTask*(scriptName, taskName: string,
    options: Options): ExecutionResult[bool] =
  ## Executes the specified task in the specified script.
  ##
  ## `scriptName` should be a filename pointing to the nimscript file.
  display("Executing",  "task $# in $#" % [taskName, scriptName],
          priority = HighPriority)

  result = execScript(scriptName, taskName, options)

proc execHook*(scriptName, actionName: string, before: bool,
    options: Options): ExecutionResult[bool] =
  ## Executes the specified action's hook. Depending on ``before``, either
  ## the "before" or the "after" hook.
  ##
  ## `scriptName` should be a filename pointing to the nimscript file.
  let hookName =
    if before: actionName.toLowerAscii & "Before"
    else: actionName.toLowerAscii & "After"
  display("Attempting", "to execute hook $# in $#" % [hookName, scriptName],
          priority = MediumPriority)

  result = execScript(scriptName, hookName, options)

proc hasTaskRequestedCommand*(execResult: ExecutionResult): bool =
  ## Determines whether the last executed task used ``setCommand``
  return execResult.command != internalCmd

proc listTasks*(scriptName: string, options: Options) =
  discard execScript(scriptName, "", options)
