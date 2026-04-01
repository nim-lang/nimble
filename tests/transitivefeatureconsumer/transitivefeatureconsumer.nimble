# Package
version       = "0.1.0"
author        = "test"
description   = "Consumer with explicit features"
license       = "MIT"
srcDir        = "src"
bin           = @["transitivefeatureconsumer"]

requires "nim"
requires "file:///Volumes/Store/Projects/nim/nimble-2/tests/transitivefeaturelib[withresult]"
requires "result[resultfeature]"
