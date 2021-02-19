# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
#
# Various miscellaneous common types reside here, to avoid problems with
# recursive imports

when not defined(nimscript):
  import sets, tables

  import version

  type
    BuildFailed* = object of NimbleError

    PackageInfo* = object
      myPath*: string ## The path of this .nimble file
      isNimScript*: bool ## Determines if this pkg info was read from a nims file
      isMinimal*: bool
      isInstalled*: bool ## Determines if the pkg this info belongs to is installed
      isLinked*: bool ## Determines if the pkg this info belongs to has been linked via `develop`
      nimbleTasks*: HashSet[string] ## All tasks defined in the Nimble file
      postHooks*: HashSet[string] ## Useful to know so that Nimble doesn't execHook unnecessarily
      preHooks*: HashSet[string]
      name*: string
      ## The version specified in the .nimble file.Assuming info is non-minimal,
      ## it will always be a non-special version such as '0.1.4'.
      ## If in doubt, use `getConcreteVersion` instead.
      version*: string
      specialVersion*: string ## Either `myVersion` or a special version such as #head.
      author*: string
      description*: string
      license*: string
      skipDirs*: seq[string]
      skipFiles*: seq[string]
      skipExt*: seq[string]
      installDirs*: seq[string]
      installFiles*: seq[string]
      installExt*: seq[string]
      requires*: seq[PkgTuple]
      bin*: Table[string, string]
      binDir*: string
      srcDir*: string
      backend*: string
      foreignDeps*: seq[string]

    ## Same as quit(QuitSuccess), but allows cleanup.
    NimbleQuit* = ref object of CatchableError

  proc raiseNimbleError*(msg: string, hint = "") =
    var exc = newException(NimbleError, msg)
    exc.hint = hint
    raise exc

  proc getOutputInfo*(err: ref NimbleError): (string, string) =
    var error = ""
    var hint = ""
    error = err.msg
    when not defined(release):
      let stackTrace = getStackTrace(err)
      error = stackTrace & "\n\n" & error
    if not err.isNil:
      hint = err.hint

    return (error, hint)

import strscans
from strutils import allCharsInSet

proc extractNimbleVersion(): string =
  let x = staticRead("../../nimble.nimble")
  var prefix = ""
  assert scanf(x, "$*version$s=$s\"$+\"", prefix, result)
  assert result.len >= 3
  assert allCharsInSet(result, {'0'..'9', '.'})

const
  nimbleVersion* = extractNimbleVersion()

when not declared(initHashSet):
  import sets

  template initHashSet*[A](initialSize = 64): HashSet[A] =
    initSet[A](initialSize)

when not declared(toHashSet):
  import sets

  template toHashSet*[A](keys: openArray[A]): HashSet[A] =
    toSet(keys)
