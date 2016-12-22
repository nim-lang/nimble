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

proc requires*(deps: varargs[string]) =
  ## Call this to set the list of requirements of your Nimble
  ## package.
  for d in deps: requiresData.add(d)

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

from strutils import contains

type
  Distribution* {.pure.} = enum ## an enum so that the poor programmer
                                ## cannot introduce typos
    Windows, ## some version of Windows
    Posix,   ## some Posix system
    MacOSX,  ## some version of OSX
    Linux,   ## some version of Linux
    Ubuntu,
    Gentoo,
    Fedora,
    RedHat,
    BSD,
    FreeBSD,
    OpenBSD

proc detectOsImpl(d: Distribution): bool =
  case d
  of Distribution.Windows: ## some version of Windows
    result = defined(windows)
  of Distribution.Posix: result = defined(posix)
  of Distribution.MacOSX: result = defined(macosx)
  of Distribution.Linux: result = defined(linux)
  of Distribution.Ubuntu, Distribution.Gentoo, Distribution.FreeBSD,
     Distribution.OpenBSD, Distribution.Fedora:
    result = $d in gorge"uname"
  of Distribution.RedHat:
    result = "Red Hat" in gorge"uname"
  of Distribution.BSD: result = defined(bsd)

template detectOs*(d: untyped): bool =
  detectOsImpl(Distribution.d)

var foreignDeps: seq[string] = @[]

proc foreignCmd*(cmd: string; requiresSudo=false) =
  foreignDeps.add((if requiresSudo: "sudo " else: "") & cmd)

proc foreignDep*(foreignPackageName: string) =
  let p = foreignPackageName
  when defined(windows):
    foreignCmd "Chocolatey install " & p
  elif defined(bsd):
    foreignCmd "ports install " & p, true
  elif defined(linux):
    if detectOs(Ubuntu):
      foreignCmd "apt-get install " & p, true
    elif detectOs(Gentoo):
      foreignCmd "emerge install " & p, true
    elif detectOs(Fedora):
      foreignCmd "yum install " & p, true
  else:
    discard
