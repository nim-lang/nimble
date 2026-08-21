import std/unittest
import pubgrub/[ranges, term, incompatibility]

type
  V = int
  R = Ranges[V]

const root = "root"

proc pos(package: string, r: R): PackageTerm[string, R] = positiveTerm(package, r)
proc neg(package: string, r: R): PackageTerm[string, R] = negativeTerm(package, r)

proc fact(terms: seq[PackageTerm[string, R]], cause: CauseKind):
    Incompatibility[string, R] =
  newIncompatibility(terms, cause)

## A stand-in for something conflict resolution produced. The two causes are
## never inspected by the code under test here, only carried.
proc derived(terms: seq[PackageTerm[string, R]]): Incompatibility[string, R] =
  let leaf = fact(@[pos("x", fullRange[V]())], ckNoVersions)
  derivedFrom(terms, leaf, leaf, root)

suite "incompatibility: construction":
  test "terms about different packages are kept as given":
    let inc = fact(@[pos("foo", between(1, 2)), neg("bar", between(2, 3))],
                   ckFromDependencyOf)
    check inc.terms.len == 2
    check inc.terms[0].package == "foo"
    check inc.terms[1].package == "bar"

  test "terms about the same package are intersected":
    let inc = fact(@[pos("foo", atLeast(1)), pos("foo", lessThan(5))],
                   ckNoVersions)
    check inc.terms.len == 1
    check inc.terms[0].term == positiveTerm(between(1, 5))

  test "merging keeps the position of the first term":
    let inc = fact(@[neg("bar", between(2, 3)), pos("foo", atLeast(1)),
                     pos("foo", lessThan(5))], ckFromDependencyOf)
    check inc.terms.len == 2
    check inc.terms[0].package == "bar"
    check inc.terms[1].package == "foo"

  test "a derived incompatibility drops positive terms about the root":
    let inc = derived(@[pos(root, fullRange[V]()), neg("foo", between(1, 2))])
    check inc.terms.len == 1
    check inc.terms[0].package == "foo"

  test "a lone root term survives, because it is the failure":
    let inc = derived(@[pos(root, fullRange[V]())])
    check inc.terms.len == 1
    check inc.isFailure(root)

  test "a negative root term is information and stays":
    let inc = derived(@[neg(root, between(1, 2)), pos("foo", between(1, 2))])
    check inc.terms.len == 2

suite "incompatibility: failure":
  test "no terms at all is a failure":
    check derived(@[]).isFailure(root)

  test "a single positive root term is a failure":
    check fact(@[pos(root, fullRange[V]())], ckNoVersions).isFailure(root)

  test "a single positive term about anything else is not":
    check not fact(@[pos("foo", fullRange[V]())], ckNoVersions).isFailure(root)

  test "a single negative root term is not":
    check not fact(@[neg(root, between(1, 2))], ckNotRoot).isFailure(root)

suite "incompatibility: identity":
  test "same terms and same cause compare equal":
    let
      a = fact(@[pos("foo", between(1, 2)), neg("bar", atLeast(2))],
               ckFromDependencyOf)
      b = fact(@[pos("foo", between(1, 2)), neg("bar", atLeast(2))],
               ckFromDependencyOf)
    check sameTerms(a, b)

  test "a different cause is a different fact":
    let
      a = fact(@[pos("foo", between(1, 2))], ckNoVersions)
      b = fact(@[pos("foo", between(1, 2))], ckNotRoot)
    check not sameTerms(a, b)

  test "a different set is a different fact":
    let
      a = fact(@[pos("foo", between(1, 2))], ckNoVersions)
      b = fact(@[pos("foo", between(1, 3))], ckNoVersions)
    check not sameTerms(a, b)

suite "incompatibility: describe":
  test "a dependency reads as one":
    let inc = fact(@[pos("foo", between(1, 2)), neg("bar", between(2, 3))],
                   ckFromDependencyOf)
    check inc.describe(root) == "foo [1, 2) depends on bar [2, 3)"

  test "an unconstrained depender is every version of it":
    let inc = fact(@[pos("foo", fullRange[V]()), neg("bar", between(2, 3))],
                   ckFromDependencyOf)
    check inc.describe(root) == "every version of foo depends on bar [2, 3)"

  test "the root package is named without its version":
    let inc = fact(@[pos(root, singleton(1)), neg("bar", between(2, 3))],
                   ckFromDependencyOf)
    check inc.describe(root) == "root depends on bar [2, 3)"

  test "no versions says which set came up empty":
    let inc = fact(@[pos("foo", between(1, 2))], ckNoVersions)
    check inc.describe(root) == "no versions of foo match [1, 2)"

  test "the root fact states the version being solved for":
    let inc = fact(@[neg(root, singleton(1))], ckNotRoot)
    check inc.describe(root) == "root is [1, 1]"

  test "the failure is stated as such":
    check derived(@[pos(root, fullRange[V]())]).describe(root) ==
      "version solving failed"

  test "a lone positive term is forbidden, a lone negative one required":
    check derived(@[pos("foo", between(1, 2))]).describe(root) ==
      "foo [1, 2) is forbidden"
    check derived(@[neg("foo", between(1, 2))]).describe(root) ==
      "foo [1, 2) is required"

  test "two positives are incompatible with each other":
    check derived(@[pos("foo", between(1, 2)), pos("bar", between(2, 3))])
      .describe(root) == "foo [1, 2) is incompatible with bar [2, 3)"

  test "two negatives are alternatives":
    check derived(@[neg("foo", between(1, 2)), neg("bar", between(2, 3))])
      .describe(root) == "either foo [1, 2) or bar [2, 3)"

  test "one positive and several negatives is a requirement":
    check derived(@[pos("foo", fullRange[V]()), neg("bar", between(2, 3)),
                    neg("baz", between(1, 2))]).describe(root) ==
      "every version of foo requires bar [2, 3) or baz [1, 2)"

  test "several positives and negatives become an implication":
    check derived(@[pos("foo", between(1, 2)), pos("bar", between(1, 2)),
                    neg("baz", between(1, 2))]).describe(root) ==
      "if foo [1, 2) and bar [1, 2) then baz [1, 2)"
