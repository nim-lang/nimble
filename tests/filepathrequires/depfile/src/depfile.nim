# This is just an example to get you started. A typical library package
# exports the main API in this file. Note that you cannot rename this file
# but you can remove it if you wish.

proc add*(x, y: int): int =
  ## Adds two numbers together.
  return x + y

proc subtract*(x, y: int): int =
  ## Subtracts the second number from the first.
  return x - y

proc multiply*(x, y: int): int =
  ## Multiplies two numbers together.
  return x * y