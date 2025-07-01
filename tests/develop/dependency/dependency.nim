import packagea

proc test*(): string =
  when defined(windows) or defined(macosx):
    $packagea.test(6, 9) #This will fail in the old code path as the babel name for packageA is CamelCase.
    # $PackageA.test(6, 9) 
  elif defined(unix):
    $packagea.test(6, 9)
  else:
    {.error: "Sorry, your platform is not supported.".}
