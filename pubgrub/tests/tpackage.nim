import std/[unittest, options]
import pubgrub

## The umbrella module has to be enough on its own: a user should be able to
## `import pubgrub`, define the two provider procs on their own type, and
## solve - reaching every type the solver's signatures mention.

type
  VS = Ranges[int]
  Universe = object
    ## A provider is any type with `chooseVersion` and `dependencies` procs
    ## acting on it. This one supplies neither optional hook, so the solver's
    ## defaults apply.

proc chooseVersion(u: Universe, package: string, allowed: VS): Option[int] =
  for candidate in countdown(3, 1):
    if allowed.contains(candidate): return some(candidate)

proc dependencies(u: Universe, package: string, version: int):
    seq[Dependency[string, VS]] =
  if package == "root": @[(package: "foo", versions: atLeast(2))]
  else: @[]

type Bare = object
  ## Only the root has a version at all, so anything it requires fails.

proc chooseVersion(b: Bare, package: string, allowed: VS): Option[int] =
  if package == "root" and allowed.contains(1): return some(1)

proc dependencies(b: Bare, package: string, version: int):
    seq[Dependency[string, VS]] =
  if package == "root": @[(package: "foo", versions: atLeast(2))]
  else: @[]

suite "package":
  test "one import is enough to define a provider and solve":
    let res = solve(Universe(), "root", 1)
    check res.outcome == soSolved
    check res.packages == @[(package: "root", version: 1),
                            (package: "foo", version: 3)]

  test "a failure comes back with a report":
    let res = solve(Bare(), "root", 1)
    check res.outcome == soUnsolvable
    check report(res.failure, "root") ==
      "Because root depends on foo [2, inf) which doesn't match any " &
      "versions, version solving failed."
