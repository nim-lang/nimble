import packagea

proc test*(): string =
  when defined(windows) or defined(macosx):
    when compiles($packagea.test(6, 9)):
      $packagea.test(6, 9) #This will fail in the old code path as the babel name for packageA is CamelCase.
    else:
      $PackageA.test(6, 9) #once vnext is the default, we will remove this.
  elif defined(unix):
    $packagea.test(6, 9)
  else:
    {.error: "Sorry, your platform is not supported.".}
