#
#
#            Nim's Runtime Library
#        (c) Copyright 2020 Nim contributors
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.

## C++11 like Smart pointers. It always uses the shared allocator.

# TODO: Add the "isolation" checks that are currently implicitly assumed
# for memory safety.

type
  UniquePtr*[T] = object
    ## Non copyable pointer to object T, exclusive ownership of the object is assumed.
    val: ptr T

proc `=destroy`*[T](p: var UniquePtr[T]) =
  mixin `=destroy`
  if p.val != nil:
    `=destroy`(p.val[])
    when compileOption("threads"):
      deallocShared(p.val)
    else:
      dealloc(p.val)

proc `=`*[T](dest: var UniquePtr[T], src: UniquePtr[T]) {.error.}

proc newUniquePtr*[T](val: sink T): UniquePtr[T] {.nodestroy.} =
  when compileOption("threads"):
    result.val = cast[ptr T](allocShared(sizeof(T)))
  else:
    result.val = cast[ptr T](alloc(sizeof(T)))
  # thanks to '.nodestroy' we don't have to use allocShared0 here.
  # This is compiled into a copyMem operation, no need for a sink
  # here either.
  result.val[] = val
  # no destructor call for 'val: sink T' here either.

converter convertUniquePtrToObj*[T](p: UniquePtr[T]): var T {.inline.} =
  when compileOption("boundChecks"):
    assert(p.val != nil, "deferencing nil unique pointer")
  p.val[]

proc isNil*[T](p: UniquePtr[T]): bool {.inline.} =
  p.val == nil

proc `[]`*[T](p: UniquePtr[T]): var T {.inline.} =
  when compileOption("boundChecks"):
    assert(p.val != nil, "deferencing nil unique pointer")
  p.val[]

proc `[]=`*[T](p:UniquePtr[T], v:T) {.inline.} = (p[]) = v

proc `$`*[T](p: UniquePtr[T]): string {.inline.} =
  if p.val == nil: "UniquePtr[" & $T & "](nil)"
  else: "UniquePtr[" & $T & "](" & $p.val[] & ")"

#------------------------------------------------------------------------------

type
  SharedPtr*[T] = object
    ## Shared ownership reference counting pointer
    val: ptr tuple[value: T, atomicCounter: int]

proc `=destroy`*[T](p: var SharedPtr[T]) =
  mixin `=destroy`
  if p.val != nil:
    if (when compileOption("threads"):
          atomicLoadN(addr p.val[].atomicCounter, ATOMIC_CONSUME) == 0 else:
          p.val[].atomicCounter == 0):
      `=destroy`(p.val[])
      when compileOption("threads"):
        deallocShared(p.val)
      else:
        dealloc(p.val)
    else:
      when compileOption("threads"):
        discard atomicDec(p.val[].atomicCounter)
      else:
        dec(p.val[].atomicCounter)

proc `=`*[T](dest: var SharedPtr[T], src: SharedPtr[T]) =
  if src.val != nil:
    when compileOption("threads"):
      discard atomicInc(src.val[].atomicCounter)
    else:
      inc(src.val[].atomicCounter)
  if dest.val != nil:
    `=destroy`(dest)
  dest.val = src.val

proc newSharedPtr*[T](val: sink T): SharedPtr[T] {.nodestroy.} =
  when compileOption("threads"):
    result.val = cast[typeof(result.val)](allocShared(sizeof(result.val[])))
  else:
    result.val = cast[typeof(result.val)](alloc(sizeof(result.val[])))
  result.val.atomicCounter = 0
  result.val.value = val

converter convertSharedPtrToObj*[T](p: SharedPtr[T]): var T {.inline.} =
  when compileOption("boundChecks"):
    doAssert(p.val != nil, "deferencing nil shared pointer")
  p.val.value

proc isNil*[T](p: SharedPtr[T]): bool {.inline.} =
  p.val == nil

proc `[]`*[T](p: SharedPtr[T]): var T {.inline.} =
  when compileOption("boundChecks"):
    doAssert(p.val != nil, "deferencing nil shared pointer")
  p.val.value

proc `[]=`*[T](p:SharedPtr[T], v:T) {.inline.} = (p[]) = v

proc `$`*[T](p: SharedPtr[T]): string {.inline.} =
  if p.val == nil: "SharedPtr[" & $T & "](nil)"
  else: "SharedPtr[" & $T & "](" & $p.val.value & ")"

#------------------------------------------------------------------------------

type
  ConstPtr*[T] = distinct SharedPtr[T]
    ## Distinct version of referencing counting smart pointer SharedPtr[T],
    ## which doesn't allow mutating underlying object.

proc newConstPtr*[T](val: sink T): ConstPtr[T] =
  ConstPtr[T](newSharedPtr(val))

converter convertConstPtrToObj*[T](p: ConstPtr[T]): lent T {.inline.} =
  SharedPtr[T](p).val.value

proc isNil*[T](p: ConstPtr[T]): bool {.inline.} =
  SharedPtr[T](p).val == nil

proc `[]`*[T](p: ConstPtr[T]): lent T {.inline.} =
  when compileOption("boundChecks"):
    doAssert(SharedPtr[T](p).val != nil, "deferencing nil const pointer")
  SharedPtr[T](p).val.value

template `[]=`*[T](p:ConstPtr[T], v:T) = {.error: "'" & p.astToStr & "[]' cannot be assigned to (ConstPtr)".}

proc `$`*[T](p: ConstPtr[T]): string {.inline.} =
  if SharedPtr[T](p).val == nil: "ConstPtr[" & $T & "](nil)"
  else: "ConstPtr[" & $T & "](" & $SharedPtr[T](p).val.value & ")"

when isMainModule:
  import unittest

  test "UniquePtr[T] test":
    var a1: UniquePtr[float]
    let a2 = newUniquePtr(0)
    check:
      $a1 == "UniquePtr[float](nil)"
      a1.isNil == true
      $a2 == "UniquePtr[int](0)"
      a2.isNil == false
      a2[] == 0

  test "SharedPtr[T] test":
    var a1: SharedPtr[float]
    let a2 = newSharedPtr(0)
    check:
      $a1 == "SharedPtr[float](nil)"
      a1.isNil == true
      $a2 == "SharedPtr[int](0)"
      a2.isNil == false
      a2[] == 0

  test "ConstPtr[T] test":
    var a1: ConstPtr[float]
    let a2 = newConstPtr(0)
    check:
      $a1 == "ConstPtr[float](nil)"
      a1.isNil == true
      $a2 == "ConstPtr[int](0)"
      a2.isNil == false
      a2[] == 0
