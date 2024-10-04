# Disable "ObservableStores" warning for the entire project because it gives
# too many false positives.
switch("warning", "ObservableStores:off")
switch("define", "ssl")
# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
