# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import strformat, strutils, json
import common

type
  InvalidSha1HashError* = object of NimbleError
    ## Represents an error caused by invalid value of a sha1 hash.

  Sha1Hash* {.requiresInit.} = object
    ## Type representing a sha1 hash value. It can only be created by special
    ## procedure which validates the input.
    hashValue: string

template `$`*(sha1Hash: Sha1Hash): string = sha1Hash.hashValue
template `%`*(sha1Hash: Sha1Hash): JsonNode = %sha1Hash.hashValue
template `==`*(lhs, rhs: Sha1Hash): bool = lhs.hashValue == rhs.hashValue

proc invalidSha1Hash(value: string): ref InvalidSha1HashError =
  ## Creates a new exception object for an invalid sha1 hash value.
  result = newNimbleError[InvalidSha1HashError](
    &"The string '{value}' does not represent a valid sha1 hash value.")

proc validateSha1Hash(value: string): bool =
  ## Checks whether given string is a valid sha1 hash value. Only lower case
  ## hexadecimal digits are accepted.
  if value.len == 0:
    # Empty string is used as a special value for not set sha1 hash.
    return true
  if value.len != 40:
    # Valid sha1 hash must be exactly 40 characters long.
    return false
  for c in value:
    if c notin {'0' .. '9', 'a'..'f'}:
      # All characters of valid sha1 hash must be hexadecimal digits with lower
      # case letters for digits representing numbers between 10 and 15
      # ('a' to 'f').
      return false
  return true

proc initSha1Hash*(value: string): Sha1Hash =
  ## Creates a new `Sha1Hash` object from a string by making all latin letters
  ## lower case and validating the transformed value. In the case the supplied
  ## string is not a valid sha1 hash value then raises an `InvalidSha1HashError`
  ## exception.
  let value = value.toLowerAscii
  if not validateSha1Hash(value):
    raise invalidSha1Hash(value)
  return Sha1Hash(hashValue: value)

const
  notSetSha1Hash* = initSha1Hash("")

proc initFromJson*(dst: var Sha1Hash, jsonNode: JsonNode,
                   jsonPath: var string) =
  case jsonNode.kind
  of JNull: dst = notSetSha1Hash
  of JObject: dst = initSha1Hash(jsonNode["hashValue"].str)
  of JString: dst = initSha1Hash(jsonNode.str)
  else:
    assert false,
      "The `jsonNode` must have one of {JNull, JObject, JString} kinds."

when isMainModule:
  import unittest

  test "validate sha1":
    check validateSha1Hash("")
    check not validateSha1Hash("9")
    check not validateSha1Hash("99345ce680cd3e48acdb9ab4212e4bd9bf9358g7")
    check not validateSha1Hash("99345ce680cd3e48acdb9ab4212e4bd9bf9358b")
    check not validateSha1Hash("99345CE680CD3E48ACDB9AB4212E4BD9BF9358B7")
    check validateSha1Hash("99345ce680cd3e48acdb9ab4212e4bd9bf9358b7")

  test "init sha1":
    check initSha1Hash("") == notSetSha1Hash
    expect InvalidSha1HashError: discard initSha1Hash("9")
    expect InvalidSha1HashError:
      discard initSha1Hash("99345ce680cd3e48acdb9ab4212e4bd9bf9358g7")
    expect InvalidSha1HashError:
      discard initSha1Hash("99345ce680cd3e48acdb9ab4212e4bd9bf9358b")
    check $initSha1Hash("99345ce680cd3e48acdb9ab4212e4bd9bf9358b7") ==
                        "99345ce680cd3e48acdb9ab4212e4bd9bf9358b7"
    check $initSha1Hash("99345CE680CD3E48ACDB9AB4212E4BD9BF9358B7") ==
                        "99345ce680cd3e48acdb9ab4212e4bd9bf9358b7"
