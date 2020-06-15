# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import macros

template delegateField*(ObjectType: type[object],
                        objectField, accessor: untyped) =
  ## Defines two additional templates for getter and setter of nested object
  ## field directly via the embedding object. The name of the nested object
  ## field must match the name of the accessor.
  ##
  ## Sample usage:
  ##
  ## .. code-block:: nim
  ##
  ##   type
  ##     Object1 = object
  ##       field1: int
  ##
  ##     Object2 = object
  ##       field2: Object1
  ##
  ##   delegateField(Object2, field2, field1)
  ##
  ##   var obj: Object2
  ##   obj.field1 = 42
  ##   echo obj.field1        # prints 42
  ##   echo obj.field2.field1 # also prints 42

  type AccessorType = ObjectType.default.objectField.accessor.typeOf

  template accessor*(obj: ObjectType): AccessorType =
    obj.objectField.accessor

  template `accessor "="`*(obj: var ObjectType, value: AccessorType) =
    obj.objectField.accessor = value

func fields(Object: type[object | tuple]): seq[string] =
  ## Collects the names of the fields of an object.
  let obj = Object.default
  for name, _ in obj.fieldPairs:
    result.add name

macro aliasThisImpl(dotExpression: typed, fields: static seq[string]): untyped =
  ## Accepts a dot expressions of an object and an object's field of object type
  ## and the names of the fields of the nested object. Iterates them and for
  ## each one generates getter and setter template accessors directly via the
  ## embedding object.

  dotExpression.expectKind nnkDotExpr
  result = newStmtList()
  let ObjectType = dotExpression[0]
  let objectField = dotExpression[1]
  for accessor in fields:
    result.add newCall(
      "delegateField", ObjectType, objectField, accessor.newIdentNode)

template aliasThis*(dotExpression: untyped) =
  ## Makes fields of an object nested in another object accessible via the
  ## embedding one. Currently only Nim's non variant `object` types and only a
  ## single level of nesting are supported.
  ##
  ## Sample usage:
  ##
  ## .. code-block:: nim
  ##
  ##   type
  ##     Object1 = object
  ##       field1: int
  ##
  ##     Object2 = object
  ##       field2: Object1
  ##
  ##   aliasThis Object2.field2
  ##
  ##   var obj: Object2
  ##   obj.field1 = 42
  ##   echo obj.field1        # prints 42
  ##   echo obj.field2.field1 # also prints 42

  aliasThisImpl(dotExpression, dotExpression.typeOf.fields)

when isMainModule:
  import unittest
  import common

  type
    Object1 = object
      field11: float 
      field12: seq[int]
      field13: int

    Tuple = tuple[tField1: string, tField2: int]

    Object2 = object
      field11: float # intentionally the name is the same as in Object1
      field22: Object1
      field23: Tuple

  aliasThis(Object2.field22)
  aliasThis(Object2.field23)

  var obj = Object2(
    field11: 3.14,
    field22: Object1(
      field11: 2.718,
      field12: @[1, 1, 2, 3, 5, 8],
      field13: 42),
    field23: ("tuple", 1))

  # check access to the original value in both ways
  check obj.field13 == 42
  check obj.field22.field13 == 42
  check obj.field12 == @[1, 1, 2, 3, 5, 8]
  check obj.field22.field12 == @[1, 1, 2, 3, 5, 8]

  # check setter via an alias
  obj.field13 = -obj.field13
  check obj.field13 == -42
  check obj.field22.field13 == -42

  # check setter without an alias
  obj.field22.field13 = 0
  check obj.field13 == 0
  check obj.field22.field13 == 0

  # check procedure call via an alias
  obj.field12.add 13
  check obj.field12 == @[1, 1, 2, 3, 5, 8, 13]
  check obj.field22.field12 == @[1, 1, 2, 3, 5, 8, 13]

  # check procedure call without an alias
  obj.field22.field12.add 21
  check obj.field12 == @[1, 1, 2, 3, 5, 8, 13, 21]
  check obj.field22.field12 == @[1, 1, 2, 3, 5, 8, 13, 21]

  # check that the priority is on the not aliased field
  check obj.field11 == 3.14
  # check that the aliased, but shadowed field is still accessible
  check obj.field22.field11 == 2.718

  # check that setting via matching field name does not override
  # the shadowed field
  obj.field11 = 0
  check obj.field11 == 0
  check obj.field22.field11 == 2.718

  # check access to tuple fields via an alias
  check obj.tField1 == "tuple"
  check obj.tField2 == 1

  # check modification of tuple fields via an alias
  obj.tField1 &= " test"
  obj.tField2.inc
  check obj.field23 == ("tuple test", 2)

  reportUnitTestSuccess()
