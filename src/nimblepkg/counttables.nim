# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import tables, strformat

type
  CountType = uint
  CountTable*[K] = distinct Table[K, CountType]
    ## Maps a key to some unsigned integer count.

template withValue[K](t: var CountTable[K], k: K;
                      value, body1, body2: untyped) =
  withValue(Table[K, CountType](t), k, value, body1, body2)

proc `[]=`[K](t: var CountTable[K], k: K, v: CountType) {.inline.} =
  Table[K, CountType](t)[k] = v

proc del[K](t: var CountTable[K], k: K) {.inline.} =
  del(Table[K, CountType](t), k)

proc getOrDefault[K](t: CountTable[K], k: K): CountType {.inline.} =
  getOrDefault(Table[K, CountType](t), k)

proc inc*[K](t: var CountTable[K], k: K) =
  ## Increments the count of key `k` in table `t`. If the key is missing the
  ## procedure adds it with a count 1.
  t.withValue(k, value) do:
    const maxCount = CountType.high
    assert value[] < maxCount,
            "Cannot increment because the result will exceed the maximum " &
           &"possible count value of {maxCount}." 
    value[].inc()
  do:
    t[k] = 1

proc dec*[K](t: var CountTable[K], k: K): bool {.discardable.} =
  ## Decrements the count of key `k` in table `t`. If the count drops to zero
  ## the procedure removes the key from the table.
  ##
  ## Returns `true` in the case the count for the key `k` drops to zero and the
  ## key is removed from the table or `false` otherwise.
  ##
  ## If the key `k` is missing raises a `KeyError` exception.
  t.withValue(k, value) do:
    value[].dec()
    if value[] == 0:
      t.del(k)
      result = true
  do:
    raise newException(KeyError, &"The key \"{k}\" is not found.")

proc count*[K](t: CountTable[K], k: K): CountType = t.getOrDefault(k)
  ## Returns the count of the key `k` from the table `t`. If the key is missing
  ## returns zero.

proc `[]`*[K](t: CountTable[K], k: K): CountType = Table[K, CountType](t)[k]
  ## Returns the count of the key `k` from the table `t`. If the key is missing
  ## raises a `KeyError` exception.

proc hasKey*[K](t: CountTable[K], k: K): bool = t.count(k) != 0
  ## Checks whether the key `k` is present in the table `t`.

when isMainModule:
  import unittest
  import common

  let testKey = 'a'
  var t: CountTable[testKey.typeOf]

  proc checkKeyCount[K](t: CountTable[K], k: K, c: CountType) =
    check t.count(k) == c
    if c != 0:
      check t.hasKey(k)
      check t[k] == c
    else:
      check not t.hasKey(k)
      expect KeyError, (discard t[k])

  checkKeyCount(t, testKey, 0)

  t.inc(testKey)
  checkKeyCount(t, testKey, 1)

  t.inc(testKey)
  checkKeyCount(t, testKey, 2)

  check not t.dec(testKey)
  checkKeyCount(t, testKey, 1)

  check t.dec(testKey)
  checkKeyCount(t, testKey, 0)

  expect KeyError, t.dec(testKey)
  checkKeyCount(t, testKey, 0)

  reportUnitTestSuccess()
