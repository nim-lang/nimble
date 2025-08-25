import math, times
import ../results

type
  Test1Type* = int

  Test2Type* = object
    f1*: Test1Type
    f2*: Test1Type
    f3*: Test1Type

  Test3Type* = object
    f1*: int
    f2*: int
    f3*: Test2Type

  Test4Type* = seq[byte]

  Test5Type* = seq[Test3Type]

  Test6Type* = object
    f1*: int
    f2*: int
    f3*: seq[byte]

  Test7Type* = ref object
    f1*: Test1Type
    f2*: Test1Type
    f3*: Test1Type

  ErrorCode* = enum
    Fail1
    Fail2
    Fail3

  Result1* = Result[Test1Type, ErrorCode]
  Result2* = Result[Test2Type, ErrorCode]
  Result3* = Result[Test3Type, ErrorCode]
  Result4* = Result[Test4Type, ErrorCode]
  Result5* = Result[Test5Type, ErrorCode]
  Result6* = Result[Test6Type, ErrorCode]
  Result7* = Result[Test7Type, ErrorCode]

proc getResult1(): Result1 =
  result.ok(0xCAFE)

proc getValue1(): Test1Type =
  result = 0xCAFE

proc getResult2(): Result2 =
  result.ok(Test2Type(f1: 0xCAFE, f2: 0xCAFE, f3: 0xCAFE))

proc getValue2(): Test2Type =
  result = Test2Type(f1: 0xCAFE, f2: 0xCAFE, f3: 0xCAFE)

proc getResult3(): Result3 =
  result.ok(
    Test3Type(f1: 0xCAFE, f2: 0xCAFE, f3: Test2Type(f1: 0xCAFE, f2: 0xCAFE, f3: 0xCAFE))
  )

proc getValue3(): Test3Type =
  result =
    Test3Type(f1: 0xCAFE, f2: 0xCAFE, f3: Test2Type(f1: 0xCAFE, f2: 0xCAFE, f3: 0xCAFE))

proc getResult41(): Result4 =
  var res = newSeq[byte](16384)
  result.ok(res)

proc getValue41(): Test4Type =
  result = newSeq[byte](16384)

proc getResult42(): Result4 =
  var res = newSeq[byte](65536)
  result.ok(res)

proc getValue42(): Test4Type =
  result = newSeq[byte](65536)

proc getResult51(): Result5 =
  var res = newSeq[Test3Type](512)
  result.ok(res)

proc getValue51(): Test5Type =
  result = newSeq[Test3Type](512)

proc getResult52(): Result5 =
  var res = newSeq[Test3Type](2048)
  result.ok(res)

proc getValue52(): Test5Type =
  result = newSeq[Test3Type](2048)

proc getResult61(): Result6 =
  var res = Test6Type(f1: 0xCAFE, f2: 0xCAFE, f3: newSeq[byte](16384))
  result.ok(res)

proc getValue61(): Test6Type =
  result = Test6Type(f1: 0xCAFE, f2: 0xCAFE, f3: newSeq[byte](16384))

proc getResult62(): Result6 =
  var res = Test6Type(f1: 0xCAFE, f2: 0xCAFE, f3: newSeq[byte](65536))
  result.ok(res)

proc getValue62(): Test6Type =
  result = Test6Type(f1: 0xCAFE, f2: 0xCAFE, f3: newSeq[byte](65536))

proc getResult7(): Result7 =
  var res = Test7Type(f1: 0xCAFE, f2: 0xCAFE, f3: 0xCAFE)
  result.ok(res)

proc getValue7(): Test7Type =
  result = Test7Type(f1: 0xCAFE, f2: 0xCAFE, f3: 0xCAFE)

proc test1R(num: int): int =
  for i in 0 ..< num:
    var opt = getResult1()[]
    inc(result)

proc test1V(num: int): int =
  for i in 0 ..< num:
    var opt = getValue1()
    inc(result)

proc test2R(num: int): int =
  for i in 0 ..< num:
    var opt = getResult2()[]
    inc(result)

proc test2V(num: int): int =
  for i in 0 ..< num:
    var opt = getValue2()
    inc(result)

proc test3R(num: int): int =
  for i in 0 ..< num:
    var opt = getResult3()[]
    inc(result)

proc test3V(num: int): int =
  for i in 0 ..< num:
    var opt = getValue3()
    inc(result)

proc test41R(num: int): int =
  for i in 0 ..< num:
    var opt = getResult41()[]
    inc(result)

proc test41V(num: int): int =
  for i in 0 ..< num:
    var opt = getValue41()
    inc(result)

proc test42R(num: int): int =
  for i in 0 ..< num:
    var opt = getResult42()[]
    inc(result)

proc test42V(num: int): int =
  for i in 0 ..< num:
    var opt = getValue42()
    inc(result)

proc test51R(num: int): int =
  for i in 0 ..< num:
    var opt = getResult51()[]
    inc(result)

proc test51V(num: int): int =
  for i in 0 ..< num:
    var opt = getValue51()
    inc(result)

proc test52R(num: int): int =
  for i in 0 ..< num:
    var opt = getResult52()[]
    inc(result)

proc test52V(num: int): int =
  for i in 0 ..< num:
    var opt = getValue52()
    inc(result)

proc test61R(num: int): int =
  for i in 0 ..< num:
    var opt = getResult61()[]
    inc(result)

proc test61V(num: int): int =
  for i in 0 ..< num:
    var opt = getValue61()
    inc(result)

proc test62R(num: int): int =
  for i in 0 ..< num:
    var opt = getResult62()[]
    inc(result)

proc test62V(num: int): int =
  for i in 0 ..< num:
    var opt = getValue62()
    inc(result)

proc test7R(num: int): int =
  for i in 0 ..< num:
    var opt = getResult7()[]
    inc(result)

proc test7V(num: int): int =
  for i in 0 ..< num:
    var opt = getValue7()
    inc(result)

const TestsCount = 100_000_000
const SeqTestsCount = 10_000

when isMainModule:
  block:
    echo "Integer test"
    var a1 = cpuTime()
    var r1 = test1V(TestsCount)
    var b1 = cpuTime()
    var a2 = cpuTime()
    var r2 = test1R(TestsCount)
    var b2 = cpuTime()
    echo "  value test = ", $(b1 - a1)
    echo "  result test = ", $(b2 - a2)
    var d1 = b1 - a1
    var d2 = b2 - a2
    if d1 == 0:
      d1 = 0.00000001
    echo "  difference = ", round((float(d2) * 100.00) / float(d1), 2), "%"

  block:
    echo "Simple object test"
    var a1 = cpuTime()
    var r1 = test2V(TestsCount)
    var b1 = cpuTime()
    var a2 = cpuTime()
    var r2 = test2R(TestsCount)
    var b2 = cpuTime()
    echo "  value test = ", $(b1 - a1)
    echo "  result test = ", $(b2 - a2)
    var d1 = b1 - a1
    var d2 = b2 - a2
    if d1 == 0:
      d1 = 0.00000001
    echo "  difference = ", round((float(d2) * 100.00) / float(d1), 2), "%"

  block:
    echo "Complex object test"
    var a1 = cpuTime()
    var r1 = test3V(TestsCount)
    var b1 = cpuTime()
    var a2 = cpuTime()
    var r2 = test3R(TestsCount)
    var b2 = cpuTime()
    echo "  value test = ", $(b1 - a1)
    echo "  result test = ", $(b2 - a2)
    var d1 = b1 - a1
    var d2 = b2 - a2
    if d1 == 0:
      d1 = 0.00000001
    echo "  difference = ", round((float(d2) * 100.00) / float(d1), 2), "%"

  block:
    echo "seq[byte](16384) test"
    var a1 = cpuTime()
    var r1 = test41V(SeqTestsCount)
    var b1 = cpuTime()
    var a2 = cpuTime()
    var r2 = test41R(SeqTestsCount)
    var b2 = cpuTime()
    echo "  value test = ", $(b1 - a1)
    echo "  result test = ", $(b2 - a2)
    var d1 = b1 - a1
    var d2 = b2 - a2
    if d1 == 0:
      d1 = 0.00000001
    echo "  difference = ", round((float(d2) * 100.00) / float(d1), 2), "%"

  block:
    echo "seq[byte](65536) test"
    var a1 = cpuTime()
    var r1 = test42V(SeqTestsCount)
    var b1 = cpuTime()
    var a2 = cpuTime()
    var r2 = test42R(SeqTestsCount)
    var b2 = cpuTime()
    echo "  value test = ", $(b1 - a1)
    echo "  result test = ", $(b2 - a2)
    var d1 = b1 - a1
    var d2 = b2 - a2
    if d1 == 0:
      d1 = 0.00000001
    echo "  difference = ", round((float(d2) * 100.00) / float(d1), 2), "%"

  block:
    echo "seq[T](512) test"
    var a1 = cpuTime()
    var r1 = test51V(SeqTestsCount)
    var b1 = cpuTime()
    var a2 = cpuTime()
    var r2 = test51R(SeqTestsCount)
    var b2 = cpuTime()
    echo "  value test = ", $(b1 - a1)
    echo "  result test = ", $(b2 - a2)
    var d1 = b1 - a1
    var d2 = b2 - a2
    if d1 == 0:
      d1 = 0.00000001
    echo "  difference = ", round((float(d2) * 100.00) / float(d1), 2), "%"

  block:
    echo "seq[T](2048) test"
    var a1 = cpuTime()
    var r1 = test52V(SeqTestsCount)
    var b1 = cpuTime()
    var a2 = cpuTime()
    var r2 = test52R(SeqTestsCount)
    var b2 = cpuTime()
    echo "  value test = ", $(b1 - a1)
    echo "  result test = ", $(b2 - a2)
    var d1 = b1 - a1
    var d2 = b2 - a2
    if d1 == 0:
      d1 = 0.00000001
    echo "  difference = ", round((float(d2) * 100.00) / float(d1), 2), "%"

  block:
    echo "Object with seq[byte](16384) inside test"
    var a1 = cpuTime()
    var r1 = test61V(SeqTestsCount)
    var b1 = cpuTime()
    var a2 = cpuTime()
    var r2 = test61R(SeqTestsCount)
    var b2 = cpuTime()
    echo "  value test = ", $(b1 - a1)
    echo "  result test = ", $(b2 - a2)
    var d1 = b1 - a1
    var d2 = b2 - a2
    if d1 == 0:
      d1 = 0.00000001
    echo "  difference = ", round((float(d2) * 100.00) / float(d1), 2), "%"

  block:
    echo "Object with seq[byte](65536) inside test"
    var a1 = cpuTime()
    var r1 = test62V(SeqTestsCount)
    var b1 = cpuTime()
    var a2 = cpuTime()
    var r2 = test62R(SeqTestsCount)
    var b2 = cpuTime()
    echo "  value test = ", $(b1 - a1)
    echo "  result test = ", $(b2 - a2)
    var d1 = b1 - a1
    var d2 = b2 - a2
    if d1 == 0:
      d1 = 0.00000001
    echo "  difference = ", round((float(d2) * 100.00) / float(d1), 2), "%"

  block:
    echo "Simple ref Object"
    var a1 = cpuTime()
    var r1 = test7V(SeqTestsCount)
    var b1 = cpuTime()
    var a2 = cpuTime()
    var r2 = test7R(SeqTestsCount)
    var b2 = cpuTime()
    echo "  value test = ", $(b1 - a1)
    echo "  result test = ", $(b2 - a2)
    var d1 = b1 - a1
    var d2 = b2 - a2
    if d1 == 0:
      d1 = 0.00000001
    echo "  difference = ", round((float(d2) * 100.00) / float(d1), 2), "%"
