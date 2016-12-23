# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

## This module is implicitly imported in NimScript .nimble files.

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
    result = ("-" & $d & " ") in gorge"uname -a"
  of Distribution.RedHat:
    result = "Red Hat" in gorge"uname -a"
  of Distribution.BSD: result = defined(bsd)

template detectOs*(d: untyped): bool =
  detectOsImpl(Distribution.d)

proc foreignCmd*(cmd: string; requiresSudo=false) =
  nimscriptapi.foreignDeps.add((if requiresSudo: "sudo " else: "") & cmd)

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
    elif detectOs(RedHat):
      foreignCmd "rpm install " & p, true
  else:
    discard
