{.used.}

import std/unittest
import pubgrub/[ranges, term]

type
  V = int
  R = Ranges[V]

## Shorthand: `p 1 ..< 5` reads as "at some version in [1, 5)".
proc p(r: R): Term[R] = positiveTerm(r)
proc n(r: R): Term[R] = negativeTerm(r)

suite "term: basics":
  test "a positive term allows its own set":
    check p(between(1, 5)).allowed == between(1, 5)

  test "a negative term allows everything outside its set":
    check n(between(1, 5)).allowed == complement(between(1, 5))

  test "inverse flips the sign, not the set":
    let t = p(atLeast(3))
    check t.inverse == n(atLeast(3))
    check t.inverse.inverse == t

  test "only an unsatisfiable positive term is empty":
    check p(emptyRange[V]()).isEmpty
    check not p(fullRange[V]()).isEmpty

  test "a negative term is never empty, however much it excludes":
    # Leaving the package out satisfies it, and that is always available.
    check not n(between(1, 5)).isEmpty
    check not n(fullRange[V]()).isEmpty
    check not n(emptyRange[V]()).isEmpty

  test "excluding everything is not the same as allowing nothing":
    # `not *` says the package is absent - a real, satisfiable state - while
    # `p(empty)` says it is at a version that does not exist.
    check relation(n(fullRange[V]()), p(fullRange[V]())) == srDisjoint
    check relation(p(emptyRange[V]()), p(fullRange[V]())) == srSubset

suite "term: intersection":
  test "two positives narrow":
    check intersect(p(atLeast(1)), p(lessThan(5))) == p(between(1, 5))

  test "two negatives widen and stay negative":
    let t = intersect(n(between(1, 3)), n(between(5, 9)))
    check not t.positive
    check t.versions == union(between(1, 3), between(5, 9))

  test "mixed signs subtract and go positive":
    let t = intersect(p(between(1, 10)), n(between(4, 6)))
    check t.positive
    check t.allowed == difference(between(1, 10), between(4, 6))

  test "mixed signs are order independent":
    let
      a = p(between(1, 10))
      b = n(between(4, 6))
    check intersect(a, b).allowed == intersect(b, a).allowed

  test "contradictory terms intersect to nothing":
    check intersect(p(between(1, 3)), p(between(5, 9))).isEmpty
    check intersect(p(between(1, 3)), n(between(1, 3))).isEmpty

  test "difference is intersection with the inverse":
    let
      a = p(between(1, 10))
      b = p(between(4, 6))
    check difference(a, b) == intersect(a, b.inverse)

suite "term: satisfies and relation":
  test "a narrower positive satisfies a wider one":
    check p(between(2, 4)).satisfies(p(between(1, 10)))
    check not p(between(1, 10)).satisfies(p(between(2, 4)))

  test "a positive satisfies a negative it avoids":
    check p(between(1, 3)).satisfies(n(between(5, 9)))
    check not p(between(1, 6)).satisfies(n(between(5, 9)))

  test "a wider negative satisfies a narrower one":
    # Excluding more is a stronger statement.
    check n(between(1, 10)).satisfies(n(between(2, 4)))
    check not n(between(2, 4)).satisfies(n(between(1, 10)))

  test "relation reports subset":
    check relation(p(between(2, 4)), p(between(1, 10))) == srSubset
    check relation(p(between(1, 3)), n(between(5, 9))) == srSubset

  test "relation reports disjoint":
    check relation(p(between(1, 3)), p(between(5, 9))) == srDisjoint
    check relation(p(between(1, 3)), n(between(1, 3))) == srDisjoint

  test "relation reports overlapping":
    check relation(p(between(1, 5)), p(between(3, 9))) == srOverlapping

  test "everything is a subset of a term that allows everything":
    check relation(p(between(1, 5)), p(fullRange[V]())) == srSubset
    check relation(p(between(1, 5)), n(emptyRange[V]())) == srSubset

  test "an empty term is both subset and disjoint, subset wins":
    # Vacuous truth: nothing satisfies it, so nothing it implies is violated.
    check relation(p(emptyRange[V]()), p(between(1, 5))) == srSubset

suite "term: rendering":
  test "sign shows up in the string":
    check $p(between(1, 5)) == "[1, 5)"
    check $n(between(1, 5)) == "not [1, 5)"
