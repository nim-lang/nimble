import issue678_dependency_1, issue678_dependency_2

proc issue678*() =
  issue678_dependency_1()
  issue678_dependency_2()
  echo "issue678"

if isMainModule:
  issue678()
