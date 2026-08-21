# Copyright (C) 2026 the Nim PubGrub authors. All rights reserved.
# BSD License. Look at license.txt for more info.

## PubGrub version solving.
##
## A port of the algorithm behind Dart's `pub`, generic over the package type
## `P`, the version type `V` and the version *set* `VS`. `pubgrub/ranges`
## supplies a ready-made `VS` for any totally ordered version type; a package
## manager whose versions do not all sit on one line - git commits, branch
## names - can supply its own instead without touching the solver.
##
## A provider is any type with `chooseVersion` and `dependencies` procs
## acting on it (plus two optional `...Hook` procs - see `pubgrub/solver`).
## Give one to `solve` and it either returns a solution or an incompatibility
## explaining why there is none:
##
## ```nim
## let res = solve(myRegistry, "root", rootVersion)
## case res.outcome
## of soSolved:     echo res.packages
## of soUnsolvable: echo report(res.failure, "root")
## ```
##
## Modules, bottom up: `ranges` (sets of versions), `term` (a set plus a
## sign), `incompatibility` (terms that cannot all hold, and where they came
## from), `partialsolution` (the assignments made so far), `solver` (the loop),
## `report` (the explanation).

import pubgrub/[ranges, tagged, term, incompatibility, partialsolution, solver,
                report]
export ranges, tagged, term, incompatibility, partialsolution, solver, report
