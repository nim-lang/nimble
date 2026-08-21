# Copyright (C) 2026 the Nim PubGrub authors. All rights reserved.
# BSD License. Look at license.txt for more info.

## The standalone PubGrub library's suite, as a single target.
##
## The library lives in `pubgrub/` at the repository root and knows nothing
## about Nimble; its tests live next to it, so that it stays a package that can
## be lifted out as-is. This module only pulls that suite in, which gives it
## two entry points:
##
## - on its own, `cd tests/pubgrub && nim c -r tester`, which is what to use
##   while working on the solver - it takes seconds and does not rebuild
##   Nimble the way `tests/testscommon` does;
## - as one more suite of `tests/tester.nim`, so `nimble test` covers it.
##
## Importing a `unittest` module runs its suites, so there is nothing else to
## do here. Order is bottom-up: a failure in `ranges` explains failures in
## everything after it.

{.used.}

import ../../pubgrub/tests/tranges
import ../../pubgrub/tests/ttagged
import ../../pubgrub/tests/tterm
import ../../pubgrub/tests/tincompatibility
import ../../pubgrub/tests/tpartialsolution
import ../../pubgrub/tests/tsolver
import ../../pubgrub/tests/treport
import ../../pubgrub/tests/tupstream
import ../../pubgrub/tests/tpackage
