import os

# `tests/config.nims` sends every test binary to `buildTests/`, and this one is
# also called `tester`. Give it its own directory so it does not overwrite the
# main Nimble tester.
switch("outdir", currentSourcePath().parentDir.parentDir.parentDir /
  "buildTests" / "pubgrub")
