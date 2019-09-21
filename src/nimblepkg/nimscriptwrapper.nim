# Copyright (C) Andreas Rumpf. All rights reserved.
# BSD License. Look at license.txt for more info.

## Implements the new configuration system for Nimble. Uses Nim as a
## scripting language.

import version, options, cli, tools
import hashes, json, os, strutils, tables, times, osproc, strtabs

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

proc execNimscript(nimsFile, projectDir, actionName: string, options: Options):
  tuple[output: string, exitCode: int] =
  let
    nimsFileCopied = projectDir / nimsFile.splitFile().name & "_" & getProcessId() & ".nims"
    outFile = getNimbleTempDir() & ".out"

  let
    isScriptResultCopied =
      nimsFileCopied.fileExists() and
      nimsFileCopied.getLastModificationTime() >= nimsFile.getLastModificationTime()

  if not isScriptResultCopied:
    nimsFile.copyFile(nimsFileCopied)

  defer:
    # Only if copied in this invocation, allows recursive calls of nimble
    if not isScriptResultCopied and options.shouldRemoveTmp(nimsFileCopied):
        nimsFileCopied.removeFile()

  var
    cmd = ("nim e --hints:off --verbosity:0 -p:" & (getTempDir() / "nimblecache").quoteShell &
      " " & nimsFileCopied.quoteShell & " " & outFile.quoteShell & " " & actionName).strip()

  if options.action.typ == actionCustom and actionName != "printPkgInfo":
    for i in options.action.arguments:
      cmd &= " " & i.quoteShell()
    for key, val in options.action.flags.pairs():
      cmd &= " $#$#" % [if key.len == 1: "-" else: "--", key]
      if val.len != 0:
        cmd &= ":" & val.quoteShell()

  displayDebug("Executing " & cmd)

  result.exitCode = execCmd(cmd)
  if outFile.fileExists():
    result.output = outFile.readFile()
    if options.shouldRemoveTmp(outFile):
      discard outFile.tryRemoveFile()

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
        execNimscript(nimsFile, scriptName.parentDir(), "printPkgInfo", options)

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
    let errMsg =
      if output.len != 0:
        output
      else:
        "Exception raised during nimble script execution"
    raise newException(NimbleError, errMsg)

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
