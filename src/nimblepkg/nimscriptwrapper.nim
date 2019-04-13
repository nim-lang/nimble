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

proc execNimscript(nimsFile, actionName: string, options: Options): tuple[output: string, exitCode: int] =
  let
    cmd = "nim e --verbosity:0 " & nimsFile.quoteShell & " " & actionName

  result = execCmdEx(cmd)

proc setupNimscript*(scriptName: string, options: Options): tuple[nimsFile, iniFile: string] =
  let
    cacheDir = getTempDir() / "nimblecache"
    shash = $scriptName.hash().abs()
    prjCacheDir = cacheDir / scriptName.splitFile().name & "_" & shash

  result.nimsFile = scriptName.parentDir() / scriptName.splitFile().name & "_" & shash & ".nims"
  result.iniFile = prjCacheDir / scriptName.extractFilename().changeFileExt ".ini"

  if not prjCacheDir.dirExists() or not result.nimsFile.fileExists() or not result.iniFile.fileExists() or
    scriptName.getLastModificationTime() > result.nimsFile.getLastModificationTime():
    createDir(prjCacheDir)
    writeFile(result.nimsFile, nimscriptApi & scriptName.readFile() & "\nonExit()\n")
    discard tryRemoveFile(result.iniFile)

    let
      (output, exitCode) = result.nimsFile.execNimscript("printPkgInfo", options)

    if exitCode == 0 and output.len != 0:
      result.iniFile.writeFile(output)
    else:
      raise newException(NimbleError, "printPkgInfo() failed")

proc execScript*(scriptName, actionName: string, options: Options): ExecutionResult[void] =
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
  if "project" in j:
    result.arguments.add $j["project"]
  result.flags = newTable[string, seq[string]]()

  if lines.len > 1:
    stdout.writeLine lines[0 .. ^2].join("\n")

proc execTask*(scriptName, taskName: string,
    options: Options): ExecutionResult[void] =
  ## Executes the specified task in the specified script.
  ##
  ## `scriptName` should be a filename pointing to the nimscript file.
  display("Executing",  "task $# in $#" % [taskName, scriptName],
          priority = HighPriority)

  result = execScript(scriptName, taskName, options)

proc execHook*(scriptName, actionName: string, before: bool,
    options: Options): ExecutionResult[void] =
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
