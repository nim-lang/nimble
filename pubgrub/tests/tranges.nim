{.used.}

import std/unittest
import pubgrub/ranges

## `int` stands in for a version: all the algebra needs is `<` and `==`.
type V = int

suite "ranges: construction and membership":
  test "empty contains nothing":
    let r = emptyRange[V]()
    check r.isEmpty
    check not r.contains(0)
    check $r == "<empty>"

  test "full contains everything":
    let r = fullRange[V]()
    check r.isFull
    check r.contains(-100)
    check r.contains(0)
    check r.contains(100)

  test "singleton contains exactly one value":
    let r = singleton(5)
    check r.contains(5)
    check not r.contains(4)
    check not r.contains(6)

  test "the comparison constructors agree with contains":
    check atLeast(3).contains(3)
    check not greaterThan(3).contains(3)
    check atMost(3).contains(3)
    check not lessThan(3).contains(3)
    check atLeast(3).contains(99)
    check lessThan(3).contains(-99)

  test "between is half open":
    let r = between(1, 4)
    check r.contains(1)
    check r.contains(3)
    check not r.contains(4)

  test "a backwards or degenerate interval is empty":
    check between(4, 1).isEmpty
    check between(2, 2).isEmpty
    check interval(exclBound(2), exclBound(2)).isEmpty
    check interval(inclBound(2), inclBound(2)) == singleton(2)

suite "ranges: complement":
  test "empty and full are complements":
    check complement(emptyRange[V]()) == fullRange[V]()
    check complement(fullRange[V]()) == emptyRange[V]()

  test "complement flips bound inclusivity":
    check complement(atLeast(3)) == lessThan(3)
    check complement(greaterThan(3)) == atMost(3)
    check complement(atMost(3)) == greaterThan(3)
    check complement(lessThan(3)) == atLeast(3)

  test "complement of a bounded interval is two tails":
    let r = complement(between(1, 4))
    check r.segments.len == 2
    check r.contains(0)
    check not r.contains(1)
    check not r.contains(3)
    check r.contains(4)

  test "complement is an involution":
    let cases = @[emptyRange[V](), fullRange[V](), singleton(2), atLeast(7),
                  lessThan(-3), between(1, 4),
                  union(between(1, 3), between(10, 20))]
    for r in cases:
      check complement(complement(r)) == r

suite "ranges: set algebra":
  test "intersection narrows to the overlap":
    check intersection(atLeast(1), lessThan(5)) == between(1, 5)
    check intersection(between(1, 5), between(3, 9)) == between(3, 5)
    check intersection(between(1, 3), between(5, 9)).isEmpty

  test "intersection with empty and full":
    let r = between(2, 8)
    check intersection(r, emptyRange[V]()).isEmpty
    check intersection(r, fullRange[V]()) == r

  test "union merges overlapping segments":
    check union(between(1, 5), between(3, 9)) == between(1, 9)

  test "union coalesces adjacent segments":
    # The half open boundary means these two touch with no gap.
    check union(between(1, 2), between(2, 3)) == between(1, 3)
    check union(atMost(5), greaterThan(5)) == fullRange[V]()

  test "union of exclusive-bound neighbours keeps the shared point out":
    # (1, 2) and (2, 3) touch at 2 but neither contains it; the union must
    # not invent it. The complement-based union takes care of this because
    # complementing produces the singleton [2, 2] in between.
    let r = union(interval(exclBound(1), exclBound(2)),
                  interval(exclBound(2), exclBound(3)))
    check r.segments.len == 2
    check not r.contains(2)
    check complement(r).contains(2)

  test "removing a singleton punches a one-point hole":
    let r = difference(between(1, 5), singleton(3))
    check r.contains(2)
    check not r.contains(3)
    check r.contains(4)
    check union(r, singleton(3)) == between(1, 5)

  test "union keeps disjoint segments apart":
    let r = union(between(1, 3), between(10, 20))
    check r.segments.len == 2
    check r.contains(2)
    check not r.contains(5)
    check r.contains(15)

  test "difference removes a hole":
    let r = difference(between(1, 10), between(4, 6))
    check r.segments.len == 2
    check r.contains(3)
    check not r.contains(5)
    check r.contains(7)

  test "difference with a disjoint set changes nothing":
    let r = between(1, 5)
    check difference(r, between(50, 60)) == r

  test "de Morgan holds":
    let
      a = union(between(1, 5), atLeast(20))
      b = between(3, 30)
    check complement(union(a, b)) == intersection(complement(a), complement(b))
    check complement(intersection(a, b)) == union(complement(a), complement(b))

suite "ranges: relations":
  test "subset":
    check between(2, 4).isSubsetOf(between(1, 10))
    check not between(1, 10).isSubsetOf(between(2, 4))
    check emptyRange[V]().isSubsetOf(singleton(1))
    check between(1, 5).isSubsetOf(between(1, 5))
    check singleton(3).isSubsetOf(fullRange[V]())

  test "disjoint":
    check between(1, 3).isDisjointFrom(between(3, 5))
    check not between(1, 4).isDisjointFrom(between(3, 5))
    check emptyRange[V]().isDisjointFrom(fullRange[V]())

  test "overlapping is neither subset nor disjoint":
    let
      a = between(1, 5)
      b = between(3, 9)
    check not a.isSubsetOf(b)
    check not a.isDisjointFrom(b)

suite "ranges: canonical form":
  test "segments come out ordered and non adjacent":
    let r = union(@[between(10, 20), between(1, 3), between(2, 5),
                    singleton(30)])
    check r.segments.len == 3
    check $r == "[1, 5) | [10, 20) | [30, 30]"

  test "equality is set equality, not representation equality":
    check union(between(1, 2), between(2, 3)) == between(1, 3)
    check union(singleton(1), emptyRange[V]()) == singleton(1)
