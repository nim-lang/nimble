import std/sequtils
export sequtils

when not declared(addUnique):
  #From the STD as it is not available in older Nim versions
  func addUnique*[T](s: var seq[T], x: T) =
    ## Adds `x` to the container `s` if it is not already present.
    ## Uses `==` to check if the item is already present.
    runnableExamples:
      var a = @[1, 2, 3]
      a.addUnique(4)
      a.addUnique(4)
      assert a == @[1, 2, 3, 4]

    for i in 0..high(s):
      if s[i] == x: return
    when (NimMajor, NimMinor) >= (2, 2):
      s.add ensureMove(x)
    else:
      s.add x
