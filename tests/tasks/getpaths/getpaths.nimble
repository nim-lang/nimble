# Package

version       = "0.1.0"
author        = "Ivan Yonchovski"
description   = "A new awesome nimble package"
license       = "MIT"
srcDir        = "src"
bin           = @["run"]


# Dependencies

requires "unittest2"

taskRequires "echoPaths", "benchy"

task echoPaths, "":
    echo "paths: ", getPathsClause()

task echoOtherPaths, "":
    echo "paths: ", getPathsClause()

task checkEmptyPaths, "":
    delEnv("__NIMBLE_PATHS")
    doAssert getPaths().len == 0
    doAssert getPathsClause() == ""
