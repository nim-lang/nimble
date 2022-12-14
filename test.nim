type
  NodeInfo = tuple[mark: bool, cameFrom: string]

proc foo =
  var name: seq[NodeInfo] = @[(mark: false, cameFrom: "sid")]

  template index: var NodeInfo =
    name[0]

  index.mark = false
  index.mark = true
  echo name

foo()
