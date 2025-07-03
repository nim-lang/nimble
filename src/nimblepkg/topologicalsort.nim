# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import sequtils, tables, strformat, algorithm, sets, os
import common, packageinfotypes, packageinfo, options, cli, version, vcstools, sha1hashes

proc getDependencies(packages: seq[PackageInfo], requires: seq[PkgTuple],
                     options: Options):
    seq[string] =
  ## Returns the names of the packages which are dependencies of a given
  ## package. It is needed because some of the names of the packages in the
  ## `requires` clause of a package could be URLs.
  for dep in requires:
    if dep.name.isNim:
      continue
    var depPkgInfo = initPackageInfo()
    var found = findPkg(packages, dep, depPkgInfo)
    if not found:
      let resolvedDep = dep.resolveAlias(options)
      found = findPkg(packages, resolvedDep, depPkgInfo)
      if not found:
        raise nimbleError(
           "Cannot build the dependency graph.\n" &
          &"Missing package \"{dep.name}\".")
    result.add depPkgInfo.name

proc allDependencies(requires: seq[PkgTuple], packages: seq[PackageInfo], options: Options): seq[string] =
  for dep in requires:
    var depPkgInfo = initPackageInfo()
    if findPkg(packages, dep, depPkgInfo):
      result.add depPkgInfo.name
      result.add allDependencies(depPkgInfo.requires, packages, options)
    else:
      let resolvedDep = dep.resolveAlias(options)
      if findPkg(packages, resolvedDep, depPkgInfo):
        result.add depPkgInfo.name
        result.add allDependencies(depPkgInfo.requires, packages, options)

proc deleteStaleDependencies*(packages: seq[PackageInfo],
                      rootPackage: PackageInfo,
                      options: Options): seq[PackageInfo] =
  # For lock operations in vnext mode, only include packages that are actual dependencies
  # This filters out packages in the develop file that are not real dependencies
  # Only apply this filtering for direct lock operations (no packages specified), not for upgrade operations
  if options.action.typ == actionLock and not options.isLegacy and options.action.packages.len == 0:
    let all = allDependencies(concat(rootPackage.requires,
                                     rootPackage.taskRequires.getOrDefault(options.task)),
                              packages,
                              options)
    let requiredNames = concat(rootPackage.requires,
                               rootPackage.taskRequires.getOrDefault(options.task)).mapIt(it.name)
    
    # Only filter if there are packages that are neither in allDependencies nor in requiredNames
    # This prevents filtering when all packages are legitimate dependencies
    let packagesToFilter = packages.filterIt(not all.contains(it.name) and not requiredNames.contains(it.name))
    
    if packagesToFilter.len > 0:
      # Include packages that are either found by allDependencies or are directly required
      # This handles the case where develop mode dependencies are not found by findPkg
      result = packages.filterIt(all.contains(it.name) or requiredNames.contains(it.name))
      return result
    else:
      return packages
    
  let all = allDependencies(concat(rootPackage.requires,
                                   rootPackage.taskRequires.getOrDefault(options.task)),
                            packages,
                            options)
  # Don't filter out develop mode dependencies (link packages) that are actual dependencies
  result = packages.filterIt(all.contains(it.name) or it.isLink)

proc buildDependencyGraph*(packages: seq[PackageInfo], options: Options):
    LockFileDeps =
  ## Creates records which will be saved to the lock file.
  for pkgInfo in packages:
    var vcsRevision = pkgInfo.metaData.vcsRevision
    
    # For develop mode dependencies, ensure VCS revision is set
    # Check both isLink and if the package has an empty VCS revision but exists locally
    if (pkgInfo.isLink or (vcsRevision == notSetSha1Hash and pkgInfo.getRealDir().dirExists())) and vcsRevision == notSetSha1Hash:
      try:
        vcsRevision = getVcsRevision(pkgInfo.getRealDir())
      except CatchableError:
        # If we can't get VCS revision, leave it as notSetSha1Hash
        discard
    
    result[pkgInfo.basicInfo.name] = LockFileDep(
      version: pkgInfo.basicInfo.version,
      vcsRevision: vcsRevision,
      url: pkgInfo.metaData.url,
      downloadMethod: pkgInfo.metaData.downloadMethod,
      dependencies: getDependencies(packages, pkgInfo.requires, options),
      checksums: Checksums(sha1: pkgInfo.basicInfo.checksum))

proc topologicalSort*(graph: LockFileDeps):
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

  var sortedNames = graph.keys.toSeq
  sortedNames.sort(cmp)

  for node in sortedNames:
    nodesInfo[node] = (mark: nmNotMarked, cameFrom: "")

  proc visit(node: string) =
    template nodeInfo: untyped = nodesInfo[node]

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

  for node in sortedNames:
    if nodesInfo[node].mark != nmPermanent:
      visit(node)

  if cycles.len > 0:
    printNotADagWarning()

  return (order, cycles)

when isMainModule:
  import unittest
  from version import notSetVersion
  from sha1hashes import notSetSha1Hash

  proc initLockFileDep(deps: seq[string] = @[]): LockFileDep =
    result = LockFileDep(
      version: notSetVersion,
      vcsRevision: notSetSha1Hash,
      dependencies: deps,
      checksums: Checksums(sha1: notSetSha1Hash))

  suite "topological sort":

    test "graph without cycles":
      let
        graph = {
          "json_serialization": initLockFileDep(
            @["serialization", "stew"]),
          "faststreams": initLockFileDep(@["stew"]),
          "testutils": initLockFileDep(),
          "stew": initLockFileDep(),
          "serialization": initLockFileDep(@["faststreams", "stew"]),
          "chronicles": initLockFileDep(
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
          "A": initLockFileDep(@["B", "E"]),
          "B": initLockFileDep(@["A", "C"]),
          "C": initLockFileDep(@["D"]),
          "D": initLockFileDep(@["B"]),
          "E": initLockFileDep(@["D", "E"])
          }.toOrderedTable

        expectedTopologicallySortedOrder = @["D", "C", "B", "E", "A"]
        expectedCycles = @[@["A", "B", "A"], @["B", "C", "D", "B"], @["E", "E"]]

        (actualTopologicallySortedOrder, actualCycles) = topologicalSort(graph)

      check actualTopologicallySortedOrder == expectedTopologicallySortedOrder
      check actualCycles == expectedCycles
