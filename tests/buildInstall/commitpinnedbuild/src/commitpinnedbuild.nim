import uirelays

# Reference the import so it is not elided; the point is that the module resolves.
when isMainModule:
  echo astToStr(uirelays)
