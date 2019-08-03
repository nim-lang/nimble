# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import os, strutils, sets

import packageparser, common, packageinfo, options, nimscriptwrapper, cli,
       version

proc execHook*(options: Options, before: bool): bool =
  ## Returns whether to continue.
  result = true

  # For certain commands hooks should not be evaluated.
  if options.action.typ in noHookActions:
    return

  var nimbleFile = ""
  try:
    nimbleFile = findNimbleFile(getCurrentDir(), true)
  except NimbleError: return true
  # PackageInfos are cached so we can read them as many times as we want.
  let pkgInfo = getPkgInfoFromFile(nimbleFile, options)
  let actionName =
    if options.action.typ == actionCustom: options.action.command
    else: ($options.action.typ)[6 .. ^1]
  let hookExists =
    if before: actionName.normalize in pkgInfo.preHooks
    else: actionName.normalize in pkgInfo.postHooks
  if pkgInfo.isNimScript and hookExists:
    let res = execHook(nimbleFile, actionName, before, options)
    if res.success:
      result = res.retVal

proc execCustom*(options: Options,
                 execResult: var ExecutionResult[bool],
                 failFast = true): bool =
  ## Executes the custom command using the nimscript backend.
  ##
  ## If failFast is true then exceptions will be raised when something is wrong.
  ## Otherwise this function will just return false.

  # Custom command. Attempt to call a NimScript task.
  let nimbleFile = findNimbleFile(getCurrentDir(), true)
  if not nimbleFile.isNimScript(options) and failFast:
    writeHelp()

  execResult = execTask(nimbleFile, options.action.command, options)
  if not execResult.success:
    if not failFast:
      return
    raiseNimbleError(msg = "Could not find task $1 in $2" %
                           [options.action.command, nimbleFile],
                     hint = "Run `nimble --help` and/or `nimble tasks` for" &
                            " a list of possible commands.")

  if execResult.command.normalize == "nop":
    display("Warning:", "Using `setCommand 'nop'` is not necessary.", Warning,
            HighPriority)
    return

  if not execHook(options, false):
    return

  return true

proc getOptionsForCommand*(execResult: ExecutionResult,
                           options: Options): Options =
  ## Creates an Options object for the requested command.
  var newOptions = options.briefClone()
  parseCommand(execResult.command, newOptions)
  for arg in execResult.arguments:
    parseArgument(arg, newOptions)
  for flag, vals in execResult.flags:
    for val in vals:
      parseFlag(flag, val, newOptions)
  return newOptions
