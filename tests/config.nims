# this also doesn't work (even in nims): --outdir:"$nimcache/buildTests"
import os
let repoDir = currentSourcePath().parentDir.parentDir
switch("outdir", repoDir / "buildTests")

# The standalone PubGrub library lives outside `tests/`. Its suite is pulled in
# by `tests/pubgrub/tester.nim`, which may be compiled either on its own or as
# part of `tests/tester.nim` - the two have different project directories, so
# the path is anchored to this file rather than to `$projectDir`.
switch("path", repoDir / "pubgrub" / "src")
