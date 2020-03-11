# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
#
# Various miscellaneous common types reside here, to avoid problems with
# recursive imports

import sets, terminal

type
  NimbleError* = object of CatchableError
    hint*: string

  BuildFailed* = object of NimbleError

  ## Same as quit(QuitSuccess), but allows cleanup.
  NimbleQuit* = ref object of CatchableError

  ProcessOutput* = tuple[output: string, exitCode: int]

  NimbleDataJsonKeys* = enum
    ndjkVersion = "version"
    ndjkRevDep = "reverseDeps"
    ndjkRevDepName = "name"
    ndjkRevDepVersion = "version"
    ndjkRevDepChecksum = "checksum"

  PackageMetaDataJsonKeys* = enum
    pmdjkUrl = "url"
    pmdjkVcsRevision = "vcsRevision"
    pmdjkFiles = "files"
    pmdjkBinaries = "binaries"
    pmdjkIsLink = "isLink"

const
  nimbleVersion* = "0.13.1"
  nimbleDataFile* = (name: "nimbledata.json", version: "0.1.0")

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

proc reportUnitTestSuccess*() =
  if programResult == QuitSuccess:
    stdout.styledWrite(fgGreen, "All tests passed.\n")

when not declared(initHashSet):
  template initHashSet*[A](initialSize = 64): HashSet[A] =
    initSet[A](initialSize)

when not declared(toHashSet):
  template toHashSet*[A](keys: openArray[A]): HashSet[A] =
    toSet(keys)

template add*[A](s: HashSet[A], key: A) =
  s.incl(key)

template add*[A](s: HashSet[A], other: HashSet[A]) =
  s.incl(other)
