import unittest2

when defined(useDevelop):
  import unittest2/customFile

suite "Test":
  test "Foo":
    check true
