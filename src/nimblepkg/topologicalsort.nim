# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import sequtils, sugar, tables, strformat, algorithm, sets
import packageinfotypes, packageinfo, options, cli, lockfile

proc buildDependencyGraph*(packages: HashSet[PackageInfo], options: Options):
    LockFileDependencies =
  ## Creates records which will be saved to the lock file.

  for pkgInfo in packages:
    let pkg = getPackage(pkgInfo.name, options)
    result[pkgInfo.name] = LockFileDependency(
      version: pkgInfo.version,
      vcsRevision: pkgInfo.vcsRevision,
      url: pkg.url,
      downloadMethod: pkg.downloadMethod,
      dependencies: pkgInfo.requires.map(
        pkg => pkg.name).filter(name => name != "nim"),
      checksums: Checksums(sha1: pkgInfo.checksum))

proc topologicalSort*(graph: LockFileDependencies):
    tuple[order: seq[string], cycles: seq[seq[string]]] =
  ## Topologically sorts dependency graph which will be saved to the lock file.
  ##
  ## Returns tuple containing sequence with the package names in the
  ## topologically sorted order and another sequence with detected cyclic
  ## dependencies if any (should not be such). Only cycles which don't have
  ## edges part of another cycle are being detected (in the order of the
  ## visiting).

  type
    NodeMark = enum
      nmNotMarked
      nmTemporary
      nmPermanent

    NodeInfo = tuple[mark: NodeMark, cameFrom: string]
    NodesInfo = OrderedTable[string, NodeInfo]

  var
    order = newSeqOfCap[string](graph.len)
    cycles: seq[seq[string]]
    nodesInfo: NodesInfo

  proc getCycle(finalNode: string): seq[string] =
    var
      path = newSeqOfCap[string](graph.len)
      previousNode = nodesInfo[finalNode].cameFrom

    path.add finalNode
    while previousNode != finalNode:
      path.add previousNode
      previousNode = nodesInfo[previousNode].cameFrom

    path.add previousNode
    path.reverse()

    return path

  proc printNotADagWarning() =
    let message = cycles.foldl(
      a & "\nCycle detected: " & b.foldl(&"{a} -> {b}"), 
      "The dependency graph is not a DAG.")
    display("Warning", message, Warning, HighPriority)

  for node, _ in graph:
    nodesInfo[node] = (mark: nmNotMarked, cameFrom: "")

  proc visit(node: string) =
    template nodeInfo: var NodeInfo = nodesInfo[node]

    if nodeInfo.mark == nmPermanent:
      return

    if nodeInfo.mark == nmTemporary:
      cycles.add getCycle(node)
      return

    nodeInfo.mark = nmTemporary

    let neighbors = graph[node].dependencies
    for node2 in neighbors:
      nodesInfo[node2].cameFrom = node
      visit(node2)

    nodeInfo.mark = nmPermanent
    order.add node

  for node, nodeInfo in nodesInfo:
    if nodeInfo.mark != nmPermanent:
      visit(node)

  if cycles.len > 0:
    printNotADagWarning()

  return (order, cycles)

when isMainModule:
  import unittest
  from sha1hashes import notSetSha1Hash

  proc initLockFileDependency(deps: seq[string] = @[]): LockFileDependency =
    result = LockFileDependency(
      vcsRevision: notSetSha1Hash,
      dependencies: deps,
      checksums: Checksums(sha1: notSetSha1Hash))

  suite "topological sort":

    test "graph without cycles":
      let
        graph = {
          "json_serialization": initLockFileDependency(
            @["serialization", "stew"]),
          "faststreams": initLockFileDependency(@["stew"]),
          "testutils": initLockFileDependency(),
          "stew": initLockFileDependency(),
          "serialization": initLockFileDependency(@["faststreams", "stew"]),
          "chronicles": initLockFileDependency(
            @["json_serialization", "testutils"])
          }.toOrderedTable

        expectedTopologicallySortedOrder = @[
          "stew", "faststreams", "serialization", "json_serialization",
          "testutils", "chronicles"]
        expectedCycles: seq[seq[string]] = @[]

        (actualTopologicallySortedOrder, actualCycles) = topologicalSort(graph)

      check actualTopologicallySortedOrder == expectedTopologicallySortedOrder
      check actualCycles == expectedCycles

    test "graph with cycles":
      let
        graph = {
          "A": initLockFileDependency(@["B", "E"]),
          "B": initLockFileDependency(@["A", "C"]),
          "C": initLockFileDependency(@["D"]),
          "D": initLockFileDependency(@["B"]),
          "E": initLockFileDependency(@["D", "E"])
          }.toOrderedTable

        expectedTopologicallySortedOrder = @["D", "C", "B", "E", "A"]
        expectedCycles = @[@["A", "B", "A"], @["B", "C", "D", "B"], @["E", "E"]]
        
        (actualTopologicallySortedOrder, actualCycles) = topologicalSort(graph)

      check actualTopologicallySortedOrder == expectedTopologicallySortedOrder
      check actualCycles == expectedCycles
