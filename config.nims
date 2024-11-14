# Disable "ObservableStores" warning for the entire project because it gives
# too many false positives.
import std/os
switch("warning", "ObservableStores:off")
switch("define", "ssl")
switch("path", "vendor" / "zippy" / "src")
switch("path", "vendor" / "sat" / "src")
switch("path", "vendor" / "checksums" / "src")
