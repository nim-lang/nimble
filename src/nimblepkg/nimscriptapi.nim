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

  startCommand = "e"
  endCommand = startCommand
  endProject = ""

proc requires*(deps: varargs[string]) =
  ## Call this to set the list of requirements of your Nimble
  ## package.
  for d in deps: requiresData.add(d)

proc getParams(): seq[string] =
  for i in 4 .. paramCount():
    result.add paramStr(i)

proc getCommand(): string =
  return endCommand

proc setCommand(cmd: string, project = "") =
  endCommand = cmd
  if project.len != 0:
    endProject = project

template printIfLen(varName) =
  if varName.len != 0:
    iniOut &= astToStr(varName) & ": \"" & varName & "\"\n"

template printSeqIfLen(varName) =
  if varName.len != 0:
    iniOut &= astToStr(varName) & ": \"" & varName.join(", ") & "\"\n"

proc printPkgInfo() =
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

  if requiresData.len != 0:
    iniOut &= "\n[Deps]\n"
    iniOut &= &"requires: \"{requiresData.join(\", \")}\"\n"

  echo iniOut

proc onExit() =
  let
    params = getParams()
  if "printPkgInfo" in params:
    printPkgInfo()
  else:
    var
      output = ""
    if endCommand != startCommand:
      output &= "\"command\": \"" & endCommand & "\", "
    if endProject.len != 0:
      output &= "\"project\": \"" & endProject & "\", "

    if output.len != 0:
      echo "{" & output[0 .. ^3] & "}"
    else:
      echo "{}"

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

  let params = getParams()
  if params.len == 0 or "help" in params:
    echo(astToStr(name), "        ", description)
  elif astToStr(name) in params:
    `name Task`()

template before*(action: untyped, body: untyped): untyped =
  ## Defines a block of code which is evaluated before ``action`` is executed.
  proc `action Before`*() =
    body

  let params = getParams()
  if astToStr(action) & "Before" in params:
    `action Before`()

template after*(action: untyped, body: untyped): untyped =
  ## Defines a block of code which is evaluated after ``action`` is executed.
  proc `action After`*() =
    body

  let params = getParams()
  if astToStr(action) & "After" in params:
    `action After`()

template builtin = discard

proc getPkgDir*(): string =
  ## Returns the package directory containing the .nimble file currently
  ## being evaluated.
  builtin
