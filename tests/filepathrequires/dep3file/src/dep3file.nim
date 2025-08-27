# This is just an example to get you started. A typical library package
# exports the main API in this file. Note that you cannot rename this file
# but you can remove it if you wish.

proc add3*(x, y: int): int =
  ## Adds two numbers together.
  return x + y

when isMainModule:
  import depfile
  let addResult = add(3, 4)
  let substractResult = subtract(10, 5)
  let multiplyResult = multiply(2, 3)
  echo("Addition Result: ", addResult)
  echo("Subtraction Result: ", substractResult)
  echo("Multiplication Result: ", multiplyResult)