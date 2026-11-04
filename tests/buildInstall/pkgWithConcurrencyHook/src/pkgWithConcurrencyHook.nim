## A library package whose before-install hook can be paused by
## tests/tconcurrentinstall.nim (see pkgWithConcurrencyHook.nimble).

proc hello*(): string =
  "Hello from pkgWithConcurrencyHook!"
