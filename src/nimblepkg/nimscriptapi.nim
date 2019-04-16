# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

## This module is implicitly imported in NimScript .nimble files.

import system except getCommand, setCommand
import strformat, strutils

var
  packageName* = ""    ## Set this to the package name. It
                       ## is usually not required to do that, nims' filename is
                       ## the default.
  version*: string     ## The package's version.
  author*: string      ## The package's author.
  description*: string ## The package's description.
  license*: string     ## The package's license.
  srcdir*: string      ## The package's source directory.
  binDir*: string      ## The package's binary directory.
  backend*: string     ## The package's backend.

  skipDirs*, skipFiles*, skipExt*, installDirs*, installFiles*,
    installExt*, bin*: seq[string] = @[] ## Nimble metadata.
  requiresData*: seq[string] = @[] ## The package's dependencies.

  foreignDeps*: seq[string] = @[] ## The foreign dependencies. Only
                                  ## exported for 'distros.nim'.

  beforeHooks: seq[string] = @[]
  afterHooks: seq[string] = @[]
  commandLineParams: seq[string] = @[]

  command = "e"
  project = ""
  retVal = true

proc requires*(deps: varargs[string]) =
  ## Call this to set the list of requirements of your Nimble
  ## package.
  for d in deps: requiresData.add(d)

proc getParams() =
  for i in 4 .. paramCount():
    commandLineParams.add paramStr(i).normalize

proc getCommand(): string =
  return command

proc setCommand(cmd: string, prj = "") =
  command = cmd
  if prj.len != 0:
    project = prj

template printIfLen(varName) =
  if varName.len != 0:
    iniOut &= astToStr(varName) & ": \"" & varName & "\"\n"

template printSeqIfLen(varName) =
  if varName.len != 0:
    iniOut &= astToStr(varName) & ": \"" & varName.join(", ") & "\"\n"

proc printPkgInfo() =
  if backend.len == 0:
    backend = "c"

  var
    iniOut = "[Package]\n"
  printIfLen packageName
  printIfLen version
  printIfLen author
  printIfLen description
  printIfLen license
  printIfLen srcdir
  printIfLen binDir
  printIfLen backend

  printSeqIfLen skipDirs
  printSeqIfLen skipFiles
  printSeqIfLen skipExt
  printSeqIfLen installDirs
  printSeqIfLen installFiles
  printSeqIfLen installExt
  printSeqIfLen bin
  printSeqIfLen beforeHooks
  printSeqIfLen afterHooks

  if requiresData.len != 0:
    iniOut &= "\n[Deps]\n"
    iniOut &= &"requires: \"{requiresData.join(\", \")}\"\n"

  echo iniOut

proc onExit() =
  if "printPkgInfo".normalize in commandLineParams:
    printPkgInfo()
  else:
    var
      output = ""
    output &= "\"command\": \"" & command & "\", "
    if project.len != 0:
      output &= "\"project\": \"" & project & "\", "
    output &= "\"retVal\": " & $retVal

    echo "{" & output & "}"

# TODO: New release of Nim will move this `task` template under a
# `when not defined(nimble)`. This will allow us to override it in the future.
template task*(name: untyped; description: string; body: untyped): untyped =
  ## Defines a task. Hidden tasks are supported via an empty description.
  ## Example:
  ##
  ## .. code-block:: nim
  ##  task build, "default build is via the C backend":
  ##    setCommand "c"
  proc `name Task`*() = body

  if commandLineParams.len == 0 or "help" in commandLineParams:
    echo(astToStr(name), "        ", description)
  elif astToStr(name).normalize in commandLineParams:
    `name Task`()

template before*(action: untyped, body: untyped): untyped =
  ## Defines a block of code which is evaluated before ``action`` is executed.
  proc `action Before`*(): bool =
    result = true
    body

  beforeHooks.add astToStr(action)

  if (astToStr(action) & "Before").normalize in commandLineParams:
    retVal = `action Before`()

template after*(action: untyped, body: untyped): untyped =
  ## Defines a block of code which is evaluated after ``action`` is executed.
  proc `action After`*(): bool =
    result = true
    body

  afterHooks.add astToStr(action)

  if (astToStr(action) & "After").normalize in commandLineParams:
    retVal = `action After`()

proc getPkgDir(): string =
  ## Returns the package directory containing the .nimble file currently
  ## being evaluated.
  result = currentSourcePath.rsplit(seps={'/', '\\', ':'}, maxsplit=1)[0]

getParams()
