when isMainModule:
  import depfile
  let addResult = add(3, 4)
  let substractResult = subtract(10, 5)
  let multiplyResult = multiply(2, 3)
  echo("Addition Result: ", addResult)
  echo("Subtraction Result: ", substractResult)
  echo("Multiplication Result: ", multiplyResult)
  when defined(withDep2):
    import dep2file
    let add2Result = addDep2(3, 4)
    echo("Addition 2 Result: ", add2Result)
  when defined(withResults):
    import resultstest
    testResults()
