# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
#
# Various miscellaneous common types reside here, to avoid problems with
# recursive imports

import sugar, macros, hashes, strutils, sets
export sugar.dump

type
  NimbleError* = object of CatchableError
    hint*: string

  BuildFailed* = object of NimbleError

  ## Same as quit(QuitSuccess) or quit(QuitFailure), but allows cleanup.
  ## Inheriting from `Defect` is workaround to avoid accidental catching of
  ## `NimbleQuit` by `CatchableError` handlers.
  NimbleQuit* = object of Defect
    exitCode*: int

  ProcessOutput* = tuple[output: string, exitCode: int]

const
  nimbleVersion* = "0.13.1"
  nimblePackagesDirName* = "pkgs"
  nimbleBinariesDirName* = "bin"

proc newNimbleError*[ErrorType](msg: string, hint = "",
                                details: ref CatchableError = nil):
    ref ErrorType =
  result = newException(ErrorType, msg, details)
  result.hint = hint

proc nimbleError*(msg: string, hint = "", details: ref CatchableError = nil):
    ref NimbleError =
  newNimbleError[NimbleError](msg, hint, details)

proc buildFailed*(msg: string, details: ref CatchableError = nil):
    ref BuildFailed =
  newNimbleError[BuildFailed](msg)

proc nimbleQuit*(exitCode = QuitSuccess): ref NimbleQuit =
  result = newException(NimbleQuit, "")
  result.exitCode = exitCode

proc hasField(NewType: type[object], fieldName: static string,
              FieldType: type): bool {.compiletime.} =
  for name, value in fieldPairs(NewType.default):
    if name == fieldName and $value.typeOf == $FieldType:
      return true
  return false

macro accessField(obj: typed, name: static string): untyped = 
  newDotExpr(obj, ident(name))

proc to*(obj: object, NewType: type[object]): NewType =
  ## Creates an object of `NewType` type, with all fields with both same name
  ## and type like a field of `obj`, set to the values of the corresponding
  ## fields of `obj`.

  # `ResultType` is a bug workaround: "Cannot evaluate at compile time: NewType"
  type ResultType = NewType
  for name, value in fieldPairs(obj):
    when ResultType.hasField(name, value.typeOf):
      accessField(result, name) = value

template newClone*[T: not ref](obj: T): ref T =
  ## Creates a garbage collected heap copy of not a reference object.
  let result = obj.typeOf.new
  result[] = obj
  result

proc dup*[T](obj: T): T = obj

proc `$`*(p: ptr | ref): string = cast[int](p).toHex
  ## Converts the pointer `p` to its hex string representation.

proc hash*(p: ptr | ref): int = cast[int](p).hash
  ## Calculates the has value of the pointer `p`.

template cd*(dir: string, body: untyped) =
  ## Sets the current dir to ``dir``, executes ``body`` and restores the
  ## previous working dir.
  let lastDir = getCurrentDir()
  setCurrentDir(dir)
  block:
    defer: setCurrentDir(lastDir)
    body

when isMainModule:
  import unittest

  test "to":
    type 
      Foo = object
        i: int
        f: float
      
      Bar = object
        i: string
        f: float
        s: string

    let foo = Foo(i: 42, f: 3.1415)
    var bar = to(foo, Bar)
    bar.s = "hello"
    check bar == Bar(i: "", f: 3.1415, s: "hello")
