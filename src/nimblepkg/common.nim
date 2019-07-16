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
  nimbleVersion* = "0.10.2"
