import issue678_dependency_1

proc issue678_dependency_2*() =
  issue678_dependency_1()
  echo "issue678_dependency_2"
