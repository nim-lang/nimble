# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
#
# Various miscellaneous common types reside here, to avoid problems with
# recursive imports

when not defined(nimscript):
  import sets

  import version
  export version.NimbleError # TODO: Surely there is a better way?

  type
    BuildFailed* = object of NimbleError

    PackageInfo* = object
      myPath*: string ## The path of this .nimble file
      isNimScript*: bool ## Determines if this pkg info was read from a nims file
      isMinimal*: bool
      isInstalled*: bool ## Determines if the pkg this info belongs to is installed
      isLinked*: bool ## Determines if the pkg this info belongs to has been linked via `develop`
      postHooks*: HashSet[string] ## Useful to know so that Nimble doesn't execHook unnecessarily
      preHooks*: HashSet[string]
      name*: string
      ## The version specified in the .nimble file.Assuming info is non-minimal,
      ## it will always be a non-special version such as '0.1.4'
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
      bin*: seq[string]
      binDir*: string
      srcDir*: string
      backend*: string
      foreignDeps*: seq[string]

    ## Same as quit(QuitSuccess), but allows cleanup.
    NimbleQuit* = ref object of Exception

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

const
  nimbleVersion* = "0.8.11"
