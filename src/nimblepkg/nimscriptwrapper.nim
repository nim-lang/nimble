# Copyright (C) Andreas Rumpf. All rights reserved.
# BSD License. Look at license.txt for more info.

## Implements the new configuration system for Nimble. Uses Nim as a
## scripting language.

import common, version, options, packageinfo, cli
import hashes, json, os, streams, strutils, strtabs,
  tables, times, osproc, sets, pegs

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

proc execNimscript(nimsFile, projectDir, actionName: string, options: Options,
  live = true): tuple[output: string, exitCode: int] =
  let
    shash = $projectDir.hash().abs()
    nimsFileCopied = projectDir / nimsFile.splitFile().name & "_" & shash & ".nims"

  let
    isScriptResultCopied =
      nimsFileCopied.fileExists() and
      nimsFileCopied.getLastModificationTime() >= nimsFile.getLastModificationTime()

  if not isScriptResultCopied:
    nimsFile.copyFile(nimsFileCopied)

  defer:
    nimsFileCopied.removeFile()

  let
    cmd = ("nim e --hints:off --verbosity:0 -p:" & (getTempDir() / "nimblecache").quoteShell &
      " " & nimsFileCopied.quoteShell & " " & actionName).strip()

  if live:
    result.exitCode = execCmd(cmd)
    let
      outFile = nimsFileCopied & ".out"
    if outFile.fileExists():
      result.output = outFile.readFile()
      discard outFile.tryRemoveFile()
  else:
    result = execCmdEx(cmd, options = {poUsePath, poStdErrToStdOut})

proc getNimsFile(scriptName: string, options: Options): string =
  let
    cacheDir = getTempDir() / "nimblecache"
    shash = $scriptName.parentDir().hash().abs()
    prjCacheDir = cacheDir / scriptName.splitFile().name & "_" & shash
    nimscriptApiFile = cacheDir / "nimscriptapi.nim"

  result = prjCacheDir / scriptName.extractFilename().changeFileExt ".nims"

  let
    iniFile = result.changeFileExt(".ini")

    isNimscriptApiCached =
      nimscriptApiFile.fileExists() and nimscriptApiFile.getLastModificationTime() > 
      getAppFilename().getLastModificationTime()
    
    isScriptResultCached =
      isNimscriptApiCached and result.fileExists() and result.getLastModificationTime() >
      scriptName.getLastModificationTime()

  if not isNimscriptApiCached:
    createDir(cacheDir)
    writeFile(nimscriptApiFile, nimscriptApi)

  if not isScriptResultCached:
    createDir(result.parentDir())
    writeFile(result, """
import system except getCommand, setCommand, switch, `--`,
  packageName, version, author, description, license, srcDir, binDir, backend,
  skipDirs, skipFiles, skipExt, installDirs, installFiles, installExt, bin, foreignDeps,
  requires, task, packageName
""" &
      "import nimscriptapi, strutils\n" & scriptName.readFile() & "\nonExit()\n")
    discard tryRemoveFile(iniFile)

proc getIniFile*(scriptName: string, options: Options): string =
  let
    nimsFile = getNimsFile(scriptName, options)

  result = nimsFile.changeFileExt(".ini")

  let
    isIniResultCached =
      result.fileExists() and result.getLastModificationTime() >
      scriptName.getLastModificationTime()

  if not isIniResultCached:
    let
      (output, exitCode) =
        execNimscript(nimsFile, scriptName.parentDir(), "printPkgInfo", options, live=false)

    if exitCode == 0 and output.len != 0:
      result.writeFile(output)
    else:
      raise newException(NimbleError, output & "\nprintPkgInfo() failed")

proc execScript(scriptName, actionName: string, options: Options):
  ExecutionResult[bool] =
  let
    nimsFile = getNimsFile(scriptName, options)

  let
    (output, exitCode) = execNimscript(nimsFile, scriptName.parentDir(), actionName, options)

  if exitCode != 0:
    raise newException(NimbleError, output)

  let
    j =
      if output.len != 0:
        parseJson(output)
      else:
        parseJson("{}")

  result.flags = newTable[string, seq[string]]()
  result.success = j{"success"}.getBool()
  result.command = j{"command"}.getStr()
  if "project" in j:
    result.arguments.add j["project"].getStr()
  if "flags" in j:
    for flag, vals in j["flags"].pairs:
      result.flags[flag] = @[]
      for val in vals.items():
        result.flags[flag].add val.getStr()
  result.retVal = j{"retVal"}.getBool()

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
