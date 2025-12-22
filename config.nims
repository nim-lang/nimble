# Disable "ObservableStores" warning for the entire project because it gives
# too many false positives.
import std/os
#The duplication of the paths (see src/nimble.nim.cfg) is necessary so nimble test keeps working
switch("warning", "ObservableStores:off")
switch("define", "ssl")
switch("path", "vendor" / "zippy" / "src")
switch("path", "vendor" / "sat" / "src")
switch("path", "vendor" / "checksums" / "src")
switch("path", "vendor" / "chronos")
switch("path", "vendor" / "results")
switch("path", "vendor" / "stew")
switch("define", "zippyNoSimd")
# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
