# This is just an example to get you started. A typical library package
# exports the main API in this file. Note that you cannot rename this file
# but you can remove it if you wish.
when not defined(no_test):
  import json_serialization/nimbletest

  hello()

proc add*(x, y: int): int =
  ## Adds two numbers together.
  return x + y
