# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

## This module is implicitly imported in NimScript .nimble files.

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

proc requires*(deps: varargs[string]) =
  ## Call this to set the list of requirements of your Nimble
  ## package.
  for d in deps: requiresData.add(d)

# TODO: New release of Nim will move this `task` template under a
# `when not defined(nimble)`. This will allow us to override it in the future.
when not declared(task):
  template task*(name: untyped; description: string; body: untyped): untyped =
    ## Defines a task. Hidden tasks are supported via an empty description.
    ## Example:
    ##
    ## .. code-block:: nim
    ##  task build, "default build is via the C backend":
    ##    setCommand "c"
    proc `name Task`*() = body

    let cmd = getCommand()
    if cmd.len == 0 or cmd == "help":
      setCommand "help"
      echo(astToStr(name), "        ", description)
    elif cmd == astToStr(name):
      setCommand "nop"
      `name Task`()

template before*(action: untyped, body: untyped): untyped =
  ## Defines a block of code which is evaluated before ``action`` is executed.
  proc `action Before`*(): bool =
    result = true
    body

template after*(action: untyped, body: untyped): untyped =
  ## Defines a block of code which is evaluated after ``action`` is executed.
  proc `action After`*(): bool =
    result = true
    body

template builtin = discard

proc getPkgDir*(): string =
  ## Returns the package directory containing the .nimble file currently
  ## being evaluated.
  builtin
