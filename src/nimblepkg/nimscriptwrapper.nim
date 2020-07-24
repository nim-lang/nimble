# Copyright (C) Andreas Rumpf. All rights reserved.
# BSD License. Look at license.txt for more info.

## Implements the new configuration system for Nimble. Uses Nim as a
## scripting language.

import hashes, json, os, strutils, tables, times, osproc, strtabs

import version, options, cli, tools

type
  Flags = TableRef[string, seq[string]]
  ExecutionResult*[T] = object
    success*: bool
    command*: string
    arguments*: seq[string]
    flags*: Flags
    retVal*: T
    stdout*: string

const
  internalCmd = "e"
  printPkgInfo = "printPkgInfo"

proc isCustomTask(actionName: string, options: Options): bool =
  options.action.typ == actionCustom and actionName != printPkgInfo

proc needsLiveOutput(actionName: string, options: Options, isHook: bool): bool =
  let isCustomTask = isCustomTask(actionName, options)
  return isCustomTask or isHook or actionName == ""

proc writeExecutionOutput(data: string) =
  # TODO: in the future we will likely want this to be live, users will
  # undoubtedly be doing loops and other crazy things in their top-level
  # Nimble files.
  display("Info", data)

proc getNimblecache(): string =
  getTempDir() / "nimblecache-" & $getEnv("USER").hash().abs()

proc execNimscript(
  nimsFile, projectDir, actionName: string, options: Options, isHook: bool
): tuple[output: string, exitCode: int, stdout: string] =
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

  # Location of nimscriptapi
  var nimblePath = getAppDir()
  if dirExists(nimblePath / "src"):
    nimblePath = nimblePath / "src"

  var cmd = (
    getNimBin() & " e $# --colors:on -p:$# $# $# $#" % [
      "--hints:off --verbosity:0",
      nimblePath.quoteShell,
      nimsFileCopied.quoteShell,
      outFile.quoteShell,
      actionName
    ]
  ).strip()

  let isCustomTask = isCustomTask(actionName, options)
  if isCustomTask:
    for i in options.action.arguments:
      cmd &= " " & i.quoteShell()
    for key, val in options.action.flags.pairs():
      cmd &= " $#$#" % [if key.len == 1: "-" else: "--", key]
      if val.len != 0:
        cmd &= ":" & val.quoteShell()

  displayDebug("Executing " & cmd)

  if needsLiveOutput(actionName, options, isHook):
    result.exitCode = execCmd(cmd)
  else:
    # We want to capture any possible errors when parsing a .nimble
    # file's metadata. See #710.
    (result.stdout, result.exitCode) = execCmdEx(cmd)
  if outFile.fileExists():
    result.output = outFile.readFile()
    if options.shouldRemoveTmp(outFile):
      discard outFile.tryRemoveFile()

proc getNimsFile(scriptName: string, options: Options): string =
  # Create .nims and .ini file out of .nimble file in nimblecache
  let
    nimbleLastModified = getAppFilename().getLastModificationTime()
    cacheDir = getNimblecache()
    shash = $(scriptName.parentDir() & $nimbleLastModified).hash().abs()
    prjCacheDir = cacheDir / scriptName.splitFile().name & "_" & shash
    nimsFile = prjCacheDir / scriptName.extractFilename().addFileExt("nims")
    iniFile = nimsFile.changeFileExt("ini")

    isScriptResultCached =
      nimsFile.fileExists() and nimsFile.getLastModificationTime() >
      scriptName.getLastModificationTime()

  if not isScriptResultCached:
    createDir(nimsFile.parentDir())
    writeFile(nimsFile, """
import system except getCommand, setCommand, switch, `--`,
  packageName, version, author, description, license, srcDir, binDir, backend,
  skipDirs, skipFiles, skipExt, installDirs, installFiles, installExt, bin, foreignDeps,
  requires, task, packageName
""" &
      "import nimblepkg/nimscriptapi, strutils\n" & scriptName.readFile() & "\nonExit()\n")
    discard tryRemoveFile(iniFile)

  result = nimsFile

proc getIniFile*(scriptName: string, options: Options): string =
  let
    nimsFile = getNimsFile(scriptName, options)

  result = nimsFile.changeFileExt(".ini")

  let
    isIniResultCached =
      result.fileExists() and result.getLastModificationTime() >
      scriptName.getLastModificationTime()

  if not isIniResultCached:
    let (output, exitCode, stdout) = execNimscript(
      nimsFile, scriptName.parentDir(), printPkgInfo, options, isHook=false
    )

    if exitCode == 0 and output.len != 0:
      result.writeFile(output)
      stdout.writeExecutionOutput()
    else:
      raise newException(NimbleError, stdout & "\nprintPkgInfo() failed")

proc execScript(
  scriptName, actionName: string, options: Options, isHook: bool
): ExecutionResult[bool] =
  let nimsFile = getNimsFile(scriptName, options)

  let (output, exitCode, stdout) =
    execNimscript(
      nimsFile, scriptName.parentDir(), actionName, options, isHook
    )

  if exitCode != 0:
    let errMsg =
      if stdout.len != 0:
        stdout
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

  stdout.writeExecutionOutput()

proc execTask*(scriptName, taskName: string,
    options: Options): ExecutionResult[bool] =
  ## Executes the specified task in the specified script.
  ##
  ## `scriptName` should be a filename pointing to the nimscript file.
  display("Executing",  "task $# in $#" % [taskName, scriptName],
          priority = HighPriority)

  result = execScript(scriptName, taskName, options, isHook=false)

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

  result = execScript(scriptName, hookName, options, isHook=true)

proc hasTaskRequestedCommand*(execResult: ExecutionResult): bool =
  ## Determines whether the last executed task used ``setCommand``
  return execResult.command != internalCmd

proc listTasks*(scriptName: string, options: Options) =
  discard execScript(scriptName, "", options, isHook=false)
