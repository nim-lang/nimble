# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import json

proc newJObjectIfKeyNotExists(obj: JsonNode, key: string): JsonNode =
  assert obj.kind == JObject
  if not obj.hasKey(key):
    let newObj = newJObject()
    obj.add(key, newObj)
    return newObj
  else:
    return obj[key]

proc addIfNotExist*(obj: JsonNode, keys: varargs[string],
                    val: JsonNode): JsonNode =
  # If the path in the `obj` json tree described by `keys` does not exist create
  # it, add the node `val` to it and return the added node, otherwise return the
  # value of the existing object at the end of the path.

  assert obj.kind == JObject
  var obj = obj
  for i in 0 ..< keys.len() - 1:
    obj = obj.newJObjectIfKeyNotExists(keys[i])
  if not obj.hasKey(keys[^1]):
    obj.add(keys[^1], val)
    return val
  else:
    return obj[keys[^1]]

proc cleanUpEmptyObjects*(obj: JsonNode): JsonNode =
  if obj.kind == JObject:
    result = newJObject()
    for key, value in obj:
      var newValue = cleanUpEmptyObjects(value)
      if newValue.kind notin {JObject, JArray} or newValue.len != 0:
        result.add(key, newValue)
  elif obj.kind == JArray:
    result = newJArray()
    for value in obj:
      var newValue = cleanUpEmptyObjects(value)
      if newValue.kind notin {JObject, JArray} or newValue.len != 0:
        result.add(newValue)
  else:
    result = obj

when isMainModule:

  import unittest
  from common import reportUnitTestSuccess

  proc testNewJObjectIfKeyNotExists() =

    proc test(testedJson, key, expectedResult: string) =
      let testedJson = parseJson(testedJson)
      let expectedResult = parseJson(expectedResult)
      let actualResult = newJObjectIfKeyNotExists(testedJson, key)
      check actualResult == expectedResult

    test("{}", "key", "{}")
    test("{ \"key1\": \"value1\", \"key2\": {} }", "key3", "{}")
    test("{ \"key1\": \"value1\", \"key2\": {} }", "key1", "\"value1\"")
    test("{ \"key1\": \"value1\", \"key2\": { \"key3\": [ 2, 3, 5] } }", "key2",
         "{ \"key3\": [ 2, 3, 5] }")

  proc testAddIfNotExist() =

    proc test(testedJson: string, keys: varargs[string],
              jsonToAdd, expectedResult, expectedEndObject: string) =
      let expectedResult = parseJson(expectedResult)
      let jsonToAdd = parseJson(jsonToAdd)
      let actualResult = parseJson(testedJson)
      let expectedEndObject = parseJson(expectedEndObject)
      let addedOrOldNode =actualResult.addIfNotExist(keys, jsonToAdd)
      check actualResult == expectedResult
      check addedOrOldNode == expectedEndObject

    test("{}", "key", "[]", "{ \"key\": [] }", "[]")
    test("{}", "key1", "key2", "{}", "{ \"key1\": { \"key2\": {} } }", "{}")
    test("{ \"key\": {} }", "key", "[]", "{ \"key\": {} }", "{}")
    test("{ \"key1\": { \"key2\": {} } }", "key1", "key2", "[1, 2, 3]",
         "{ \"key1\": { \"key2\": {} } }", "{}")
    test("{ \"key1\": {}, \"key2\": {} }", "key2", "key3", "{ \"key4\": [1] }",
         "{ \"key1\": {}, \"key2\": { \"key3\": { \"key4\": [1] } } }",
         "{ \"key4\": [1] }")

  proc testCleanUpEmptyObjects() =

    proc test(testedJson, expectedJson: string) =
      let testedJsonNode = parseJson(testedJson)
      let expectedResult = parseJson(expectedJson)
      let actualResult = cleanUpEmptyObjects(testedJsonNode)
      check actualResult == expectedResult

    test("{}", "{}")
    test("[]", "[]")
    test("{ \"key\": \"value\" }", "{ \"key\": \"value\" }")
    test("[ 3, 1415 ]", "[ 3, 1415 ]")

    test("{ \"key\": [ \"value1\", \"value2\" ] }",
         "{ \"key\": [ \"value1\", \"value2\" ] }")

    test("{ \"key\": {} }", "{}")
    test("[ [], [] ]", "[]")
    test("[ { \"key1\": [ { \"key1.1\": [] } ] }, { \"key2\": [] } ]", "[]")

    test(""" {
      "key1": {
        "key1.1": "value1.1",
        "key1.2": "value1.2"
      },
      "key2": {},
      "key3": [
        {
          "key3.1": "value3.1",
          "key3.2": "value3.2"
        },
        {},
        {
          "key3.3": "value3.3"
        },
        {}
      ],
      "key4": {
        "key4.1": {},
        "key4.2": []
      },
      "key5": 5
      }""", """ {
      "key1": {
        "key1.1": "value1.1",
        "key1.2": "value1.2"
      },
      "key3": [
        {
          "key3.1": "value3.1",
          "key3.2": "value3.2"
        },
        {
          "key3.3": "value3.3"
        },
      ],
      "key5": 5
      }""")

  testNewJObjectIfKeyNotExists()
  testAddIfNotExist()
  testCleanUpEmptyObjects()
  reportUnitTestSuccess()
