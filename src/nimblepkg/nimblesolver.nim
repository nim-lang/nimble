import version, packageinfotypes, packageinfo, options, tools, cli, common, urls
import versiondiscovery
import nimblesat, nimblepubgrub
import lockfile, declarativeparser, sha1hashes

import compat/[sequtils]
import std/[tables, algorithm, sets, strutils, options, strformat, os]
import chronos

proc resolutionFailureMessage*(options: Options): string =
  ## The single user-facing message for a failed resolution. The solver output
  ## already carries the explanation (PubGrub's, when it could produce one), so
  ## that output *is* the error - appending a generic sentence after it only
  ## repeats "it failed" in vaguer words.
  result = options.satResult.output.strip()
  if result.len == 0:
    result = "Couldnt find a solution for the packages. Unsatisfiable " &
      "dependencies. Check there is no contradictory dependencies."

proc getSolvedPackages*(pkgVersionTable: Table[string, PackageVersions], output: var string, options: Options): seq[SolvedPackage] {.instrument.} =
  ## The solution for `pkgVersionTable` from the solver `--solver` selects:
  ## each chosen package with what it requires and what requires it, or
  ## nothing, with the reason in `output`.
  var graph = pkgVersionTable.toDepGraph()
  let packages =
    case options.solver
    of skSat: graph.satPackages(pkgVersionTable, output, options)
    of skPubGrub: pubGrubPackages(pkgVersionTable, output, options)
  graph.toSolvedPackages(packages)

proc topologicalSort*(solvedPkgs: seq[SolvedPackage]): seq[SolvedPackage] {.instrument.}  =
  var inDegree = initTable[string, int]()
  var adjList = initTable[string, seq[string]]()
  var zeroInDegree: seq[string] = @[]
  # Create a lookup table for O(1) package access
  var pkgLookup = initTable[string, SolvedPackage]()

  # Initialize in-degree and adjacency list using requirements
  for pkg in solvedPkgs:
    let pkgNameLower = pkg.pkgName.toLowerAscii
    pkgLookup[pkgNameLower] = pkg
    if not inDegree.hasKey(pkgNameLower):
      inDegree[pkgNameLower] = 0  # Ensure every package is in the inDegree table
    for dep in pkg.requirements:
      let depNameLower = dep.name.toLowerAscii
      if depNameLower notin adjList:
        adjList[depNameLower] = @[pkgNameLower]
      else:
        adjList[depNameLower].add(pkgNameLower)
      inDegree[pkgNameLower].inc  # Increase in-degree of this pkg since it depends on dep

  # Find all nodes with zero in-degree
  for (pkgName, degree) in inDegree.pairs:
    if degree == 0:
      zeroInDegree.add(pkgName)

  # Perform the topological sorting
  while zeroInDegree.len > 0:
    let current = zeroInDegree.pop()
    let currentPkg = pkgLookup[current]
    result.add(currentPkg)
    for neighbor in adjList.getOrDefault(current, @[]):
      inDegree[neighbor] -= 1
      if inDegree[neighbor] == 0:
        zeroInDegree.add(neighbor) 

proc isSystemNimCompatible*(solvedPkgs: seq[SolvedPackage], options: Options, nimVersion: Option[Version]): bool =
  if options.action.typ in {actionLock, actionDeps} or options.hasNimInLockFile():
    return false
  for solvedPkg in solvedPkgs:
    for req in solvedPkg.requirements:
      if req.isNim and nimVersion.isSome and not nimVersion.get.withinRange(req.ver):
        return false
  true

proc areAllReqAny(dep: SolvedPackage): bool =
  #Checks where all the requirements by other packages in the solution are any
  #This allows for using a special version to meet the requirement of the solution
  #Scenario will be, int he package list there is only a special version but all requirements
  #are any. So it wont need to download a regular version but just use the special version.
  for rev in dep.reverseDeps:
    for req in rev.requirements:
      if dep.pkgName == req.name:
        if req.ver.kind != verAny:
          return false
  true

proc normalizeGitUrl*(url: string): string =
  ## Normalize a git URL for comparison: strip trailing ".git" and "/", lowercase.
  ## e.g. "https://github.com/user/repo.git" == "https://github.com/user/repo"
  result = url.strip(chars = {'/'})
  if result.endsWith(".git"):
    result = result[0..^5]
  result = result.toLowerAscii()

proc getPackageNameFromUrl*(pv: PkgTuple, pkgVersionTable: Table[string, PackageVersions], options: Options): string =
  let normalizedPvName = normalizeGitUrl(pv.name)
  var candidates: seq[string] = @[]
  for pkgName, pkgVersions in pkgVersionTable:
    for pkgVersion in pkgVersions.versions:
      if normalizeGitUrl(pkgVersion.url) == normalizedPvName:
        candidates.add(pkgName)

  # Prefer package names that are not URLs
  for candidate in candidates:
    if not candidate.isUrl:
      return candidate

  # If no non-URL candidate, return the first one
  if candidates.len > 0:
    return candidates[0]

proc getUrlFromPkgName*(pkgName: string, pkgVersionTable: Table[string, PackageVersions], options: Options): string =
  for pkgTableName, pkgVersions in pkgVersionTable:
    for pkgVersion in pkgVersions.versions:
      if pkgVersion.name.toLower == pkgName.toLower:
        return pkgVersion.url
  return ""

proc normalizeRequirements*(pkgVersionTable: var Table[string, PackageVersions], options: Options) {.instrument.} =
  for pkgName, pkgVersions in pkgVersionTable.mpairs:
    for pkgVersion in pkgVersions.versions.mitems:
      for req in pkgVersion.requires.mitems:
        if req.name.isUrl:
          let newPkgName = getPackageNameFromUrl(req, pkgVersionTable, options)
          if newPkgName != "":
            let oldReq = req.name
            req.name = newPkgName
            options.satResult.normalizedRequirements[newPkgName] = oldReq
        req.name = req.name.resolveAlias(options)

  # Heal URL/name split-brain: version discovery can key one repo's versions
  # under both its package name and a URL-form requirement (e.g. libp2p 2.x
  # requires "https://.../nim-websock >= 0.4.0" while libp2p 1.x requires
  # "websock >= 0.2.1"), and the two lists can diverge. Requirements were just
  # normalized to names, so the name node must own every version the URL node
  # collected — otherwise name-bound ranges see only a subset and solvable
  # graphs are reported unsatisfiable.
  var urlKeys: seq[string] = @[]
  for key in pkgVersionTable.keys:
    if key.isUrl:
      urlKeys.add key
  for key in urlKeys:
    let vs = pkgVersionTable[key].versions
    if vs.len == 0:
      continue
    let nameKey = vs[0].name.toLowerAscii
    if nameKey != key and nameKey in pkgVersionTable:
      for v in vs:
        pkgVersionTable[nameKey].versions.addVersionUnique v

proc getRootSpecialRequirements(
    pkgVersionTable: Table[string, PackageVersions]): Table[string, Version] =
  for _, pkgVersions in pkgVersionTable:
    for pkgVersion in pkgVersions.versions:
      if pkgVersion.isRoot:
        for req in pkgVersion.requires:
          if req.ver.kind == verSpecial:
            result[req.name.toLowerAscii] = req.ver.spe
        return

proc normalizeSpecialVersions*(pkgVersionTable: var Table[string, PackageVersions], options: Options) {.instrument.} =
  ## First-#-wins: when multiple special versions exist for the same package
  ## (e.g. asynctools#commit_a from jester, asynctools#commit_b from httpbeast),
  ## keep only the first one encountered (topologically closest to root, since
  ## processRequirements traverses depth-first from root). Rewrite all other
  ## special requirements for that package to use the winner.
  var winners = initTable[string, Version]()  # pkgName -> winning special version

  # The special versions the ROOT explicitly requires. When a genuine conflict
  # exists, the root's pin is authoritative and must win, rather than letting an
  # arbitrary, traversal-order dependent choice discard it in favour of a
  # transitive dep's special version.
  let rootSpecialReqs = getRootSpecialRequirements(pkgVersionTable)

  # Phase 1: find packages with multiple special versions, pick the winner
  for pkgName, pkgVersions in pkgVersionTable.mpairs:
    if pkgName.isNim:
      continue
    var specialVersions: seq[Version] = @[]
    for v in pkgVersions.versions:
      # Compare distinct special versions, not raw occurrences: the same special
      # version can reach the table via several requirement paths (name- vs
      # URL-keyed), and a version never conflicts with itself.
      if v.version.isSpecial and v.version notin specialVersions:
        specialVersions.add v.version
    if specialVersions.len > 1:
      # Default to the first (topologically closest to root in DFS order), but
      # let an explicit root pin of this package win when it is one of the
      # candidates (#1785).
      let canonicalName =
        if pkgVersions.versions.len > 0: pkgVersions.versions[0].name.toLowerAscii
        else: pkgName.toLowerAscii
      var winner = specialVersions[0]
      if canonicalName in rootSpecialReqs and rootSpecialReqs[canonicalName] in specialVersions:
        winner = rootSpecialReqs[canonicalName]
      let others = specialVersions.filterIt(it != winner).mapIt($it).join(", ")
      if not options.lenient:
        raise resolutionFailureError(
          &"Multiple dependencies require different special versions of '{pkgName}': " &
          &"{winner}, {others}.")
      winners[pkgName] = winner
      pkgVersions.versions = pkgVersions.versions.filterIt(
        not it.version.isSpecial or it.version == winner
      )
      displayWarning(&"Multiple dependencies require different special versions of '{pkgName}': " &
        &"using {winner}, ignoring {others}. This will become an error in future versions.", HighPriority)

  # Phase 2: remove URL-keyed table entries for packages that have a winner
  # and fix normalizedRequirements so it points to the correct URL
  if winners.len > 0:
    var keysToRemove: seq[string] = @[]
    var winnerUrls = initTable[string, string]()  # pkgName -> URL of fork that has the winning version
    for key, pkgVersions in pkgVersionTable:
      if key.isUrl and pkgVersions.versions.len > 0:
        let name = pkgVersions.versions[0].name.toLower
        if name in winners:
          for v in pkgVersions.versions:
            if v.version == winners[name]:
              winnerUrls[name] = key
              break
          keysToRemove.add key
    for key in keysToRemove:
      pkgVersionTable.del key
    # Update normalizedRequirements: point to the winning fork's URL,
    # or remove the entry if the winner came from a name-based requirement
    # (so normal package resolution finds the official URL from packages.json)
    for name, winner in winners:
      if name in winnerUrls:
        options.satResult.normalizedRequirements[name] = winnerUrls[name]
      elif name in options.satResult.normalizedRequirements:
        options.satResult.normalizedRequirements.del name

    # Phase 3: rewrite requirements across the table to use winning versions
    for pkgName, pkgVersions in pkgVersionTable.mpairs:
      for pkgVersion in pkgVersions.versions.mitems:
        for req in pkgVersion.requires.mitems:
          let reqName = req.name.toLower
          if reqName in winners and req.ver.kind == verSpecial and req.ver.spe != winners[reqName]:
            req.ver = VersionRange(kind: verSpecial, spe: winners[reqName])
proc postProcessSolvedPkgs*(solvedPkgs: var seq[SolvedPackage], options: Options, nimBin: Option[string]) {.instrument.} =
  #Prioritizes fileUrl packages over the regular packages defined in the requirements
  var fileUrlPkgs: seq[PackageInfo] = @[]
  for solved in solvedPkgs:
    if solved.pkgName.isFileURL:
      let pkg = getPackageFromFileUrl(solved.pkgName, options, nimBin)
      fileUrlPkgs.add pkg
  var toReplace: seq[SolvedPackage] = @[]
  for solved in solvedPkgs:
    for fileUrlPkg in fileUrlPkgs:
      if solved.pkgName == fileUrlPkg.basicInfo.name:
        toReplace.add solved
        break
  solvedPkgs = solvedPkgs.filterIt(it notin toReplace)

proc solveLocalPackages(root: PackageMinimalInfo, pkgList: seq[PackageInfo], options: Options, output: var string, solvedPkgs: var seq[SolvedPackage], nimBin: Option[string]): HashSet[PackageInfo] =
  ## Try to solve using only installed packages (no cache, no downloads).
  ## Returns the solved packages if successful, or an empty set if local
  ## packages don't satisfy all constraints. See #1648.
  # Reset the output param up front: on the failure path we return without
  # touching `solvedPkgs`, so a solution left over from a previous solve pass
  # (e.g. a retry via withNimBinFallback) would otherwise leak into the
  # caller's local-solve early-return guard and skip full resolution.
  solvedPkgs = @[]
  var localTable = initTable[string, PackageVersions]()
  localTable[root.name] = PackageVersions(pkgName: root.name, versions: @[root])
  let rootPkgName = root.name.toLowerAscii()
  let nonRootPkgs = pkgList.filterIt(it.basicInfo.name.toLowerAscii() != rootPkgName)
  localTable.fillPackageTableFromPreferred(nonRootPkgs.mapIt(it.getMinimalInfo(options)))
  var localOutput = ""
  let localSolved = localTable.getSolvedPackages(localOutput, options)
  if localSolved.len == 0:
    return  # Local solve failed, caller should fall back to full resolution
  localTable.normalizeRequirements(options)
  localTable.normalizeSpecialVersions(options)
  options.satResult.pkgVersionTable = localTable
  solvedPkgs = localTable.getSolvedPackages(output, options).topologicalSort()
  solvedPkgs.postProcessSolvedPkgs(options, nimBin)
  var pkgs: HashSet[PackageInfo]
  for solvedPkg in solvedPkgs:
    if solvedPkg.pkgName == root.name: continue
    for pkgInfo in pkgList:
      if (cmpIgnoreCase(pkgInfo.basicInfo.name, solvedPkg.pkgName) == 0 or cmpIgnoreCase(pkgInfo.metadata.url, solvedPkg.pkgName) == 0) and
        pkgInfo.basicInfo.version == solvedPkg.version:
        pkgs.incl pkgInfo
        break
  return pkgs

proc solvePackages*(rootPkg: PackageInfo, pkgList: seq[PackageInfo], pkgsToInstall: var seq[(string, Version)], options: Options, output: var string, solvedPkgs: var seq[SolvedPackage], nimBin: Option[string]): HashSet[PackageInfo] {.instrument.} =
  var root: PackageMinimalInfo = rootPkg.getMinimalInfo(options)
  root.isRoot = true

  # Try local solve first: if installed packages satisfy all constraints, use
  # them without fetching newer versions. `lock` has to agree with `install`
  # here. Only the commands asking for something newer skip it: `isUpgrade`
  # (`upgrade`, `lock --refresh`, `lock pkg`), `--refresh`, and minVer, which
  # must consider the full version set.
  if pkgList.len > 0 and not options.isUpgrade and
     not options.forceFetch and
     options.resolutionAlgorithm != raMinVer:
    let localResult = solveLocalPackages(root, pkgList, options, output, solvedPkgs, nimBin)
    if localResult.len > 0 or solvedPkgs.len > 0:
      return localResult

  #`nimble dump` is a read-only command and must never trigger
  # network discovery. When the local solve fails, just return — callers
  # (getNimDir) interpret the empty result as "no nim resolved" and emit an
  # empty nimDir, letting the langserver prompt the user to install.
  if options.action.typ == actionDump:
    return

  var pkgVersionTable: Table[system.string, packageinfotypes.PackageVersions]
  # Load cached package versions to skip re-fetching known packages
  pkgVersionTable = cacheToPackageVersionTable(options)
  pkgVersionTable[root.name] = PackageVersions(pkgName: root.name, versions: @[root])

  let discoveredVersions = waitFor collectAllVersions(root, options, downloadMinimalPackage, pkgList.mapIt(it.getMinimalInfo(options)), nimBin)
  for pkgName, pkgVersions in discoveredVersions:
    if pkgName notin pkgVersionTable:
      pkgVersionTable[pkgName] = pkgVersions
    else:
      for ver in pkgVersions.versions:
        pkgVersionTable[pkgName].versions.addVersionUnique ver

  pkgVersionTable.normalizeRequirements(options)
  pkgVersionTable.normalizeSpecialVersions(options)

  options.satResult.pkgVersionTable = pkgVersionTable
  solvedPkgs = pkgVersionTable.getSolvedPackages(output, options).topologicalSort()
  solvedPkgs.postProcessSolvedPkgs(options, nimBin)
  
  let systemNimCompatible = solvedPkgs.isSystemNimCompatible(options, getNimVersionFromBin(nimBin.getNimBin))
  # echo "DEBUG: SolvedPkgs after post processing: ", solvedPkgs.mapIt(it.pkgName & " " & $it.version).join(", ")
  # echo "ACTION IS ", options.action.typ
  for solvedPkg in solvedPkgs:
    if solvedPkg.pkgName == root.name: continue    
    var foundInList = false
    let canUseAny = solvedPkg.areAllReqAny()
    for pkgInfo in pkgList:
      let specialVersions = if pkgInfo.metadata.specialVersions.len > 1: pkgInfo.metadata.specialVersions.toSeq()[1..^1] else: @[]
      let isSpecial = specialVersions.len > 0
      if (cmpIgnoreCase(pkgInfo.basicInfo.name, solvedPkg.pkgName) == 0 or cmpIgnoreCase(pkgInfo.metadata.url, solvedPkg.pkgName) == 0) and 
        (pkgInfo.basicInfo.version == solvedPkg.version and (not isSpecial or canUseAny) or solvedPkg.version in specialVersions) and
        #only add one (we could fall into adding two if there are multiple special versiosn in the package list and we can add any). 
        #But we still allow it on upgrade as they are post proccessed in a later stage
          ((options.action.typ in {actionLock}) or #For lock the result is cleaned in the lock proc that handles the pass
            (result.toSeq.filterIt(cmpIgnoreCase(it.basicInfo.name, solvedPkg.pkgName) == 0 or 
            cmpIgnoreCase(it.metadata.url, solvedPkg.pkgName) == 0).len == 0 or 
            options.action.typ in {actionUpgrade})): 
          result.incl pkgInfo
          foundInList = true
    if not foundInList:
      # displayInfo(&"Coudlnt find {solvedPkg.pkgName}", priority = HighPriority)
      if solvedPkg.pkgName.isNim and systemNimCompatible:
        continue #Skips systemNim
      pkgsToInstall.addUnique((solvedPkg.pkgName, solvedPkg.version))
      
    # echo "Packages in result: ", result.mapIt(it.basicInfo.name & " " & $it.basicInfo.version & " " & $it.metaData.vcsRevision).join(", ")


proc getPackageInfo*(name: string, pkgs: seq[PackageInfo], version: Option[Version] = none(Version)): Option[PackageInfo] =
    for pkg in pkgs:
      if cmpIgnoreCase(pkg.basicInfo.name, name) == 0 or cmpIgnoreCase(pkg.metadata.url, name) == 0:
        if version.isSome:
          if pkg.basicInfo.version == version.get:
            return some pkg
        else: #No version passed over first match
          return some pkg

proc getPkgVersionTable*(pkgInfo: PackageInfo, pkgList: seq[PackageInfo], options: Options, nimBin: Option[string]): Table[string, PackageVersions] =
  # Load cached package versions to skip re-fetching known packages
  result = cacheToPackageVersionTable(options)
  var root = pkgInfo.getMinimalInfo(options)
  root.isRoot = true
  result[root.name] = PackageVersions(pkgName: root.name, versions: @[root])
  let discoveredVersions = waitFor collectAllVersions(root, options, downloadMinimalPackage, pkgList.mapIt(it.getMinimalInfo(options)), nimBin)
  for pkgName, pkgVersions in discoveredVersions:
    if not result.hasKey(pkgName):
      result[pkgName] = pkgVersions
    else:
      for ver in pkgVersions.versions:
        result[pkgName].versions.addVersionUnique ver


const maxPkgNameDisplayWidth = 40  # Cap package name width
const maxVersionDisplayWidth = 10  # Cap version width

proc formatPkgName(pkgName: string, maxWidth = maxPkgNameDisplayWidth): string =
  result = pkgName
  if result.startsWith("https:"):
    let parts = result.split('/')
    result = parts[^1]
  # Handle git repo names with extension
  if result.endsWith(".git"):
    result = result[0..^5]  # Remove .git suffix
  
  # Truncate if still too long
  if result.len > maxWidth - 3:
    result = result[0..<(maxWidth - 3)] & "..."

proc dumpSolvedPackages*(pkgInfo: PackageInfo, pkgList: seq[PackageInfo], options: Options, nimBin: Option[string]) =
  var pkgToInstall: seq[(string, Version)] = @[]
  var output = ""
  var solvedPkgs: seq[SolvedPackage] = @[]
  discard solvePackages(pkgInfo, pkgList, pkgToInstall, options, output, solvedPkgs, nimBin)

  echo "PACKAGE".alignLeft(maxPkgNameDisplayWidth), "VERSION".alignLeft(maxVersionDisplayWidth), "REQUIREMENTS"
  echo "-".repeat(maxPkgNameDisplayWidth + maxVersionDisplayWidth + 4)
  
  # Sort packages alphabetically
  var sortedPackages = solvedPkgs
  sortedPackages.sort(proc(a, b: SolvedPackage): int =
    result = cmp(a.pkgName, b.pkgName)
    if result == 0:
      result = cmp(a.version, b.version)
  )
  
  # Find the pkgInfo package in the solved packages and move it to the front
  for i, pkg in sortedPackages:
    if pkg.pkgName == pkgInfo.basicInfo.name:
      let rootPkg = sortedPackages[i]
      sortedPackages.delete(i)
      sortedPackages.insert(rootPkg, 0)
      break
  
  # Display each package
  for i, pkg in sortedPackages:
    var displayName = formatPkgName(pkg.pkgName)
    
    # Mark root package with an asterisk (either it's the first package after sorting, or it's pkgInfo)
    let rootMarker = if pkg.pkgName == pkgInfo.basicInfo.name: "*" else: " "
    
    # Format requirements
    var reqStr = ""
    for i, req in pkg.requirements:
      if i > 0: reqStr.add ", "
      
      var reqName = formatPkgName(req.name)
      reqStr.add reqName
      if req.ver.kind != verAny:
        reqStr.add " " & $req.ver
    
    # Display package line
    echo rootMarker, " ", 
         displayName.alignLeft(maxPkgNameDisplayWidth - 1), 
         $pkg.version.version.alignLeft(maxVersionDisplayWidth), 
         if reqStr.len > 0: reqStr.splitLines()[0] else: ""
    
    # If requirements were long, display them on additional indented lines
    if reqStr.len > 0 and (reqStr.contains('\n') or reqStr.len > 80):
      let lines = reqStr.split(", ")
      var currentLine = ""
      for i, req in lines:
        if currentLine.len + req.len + 2 > 80:  # +2 for ", "
          if currentLine.len > 0:
            echo " ".repeat(maxPkgNameDisplayWidth + maxVersionDisplayWidth + 3), currentLine
          currentLine = req
        else:
          if currentLine.len > 0:
            currentLine.add ", "
          currentLine.add req
      
      if currentLine.len > 0:
        echo " ".repeat(maxPkgNameDisplayWidth + maxVersionDisplayWidth + 3), currentLine
    
    # Show reverse dependencies indented underneath - UPDATED to group by package name
    if pkg.reverseDependencies.len > 0:
      var depStr = "Required by: "
      
      # Group dependencies by package name
      var depGroups = initTable[string, seq[Version]]()
      for revDep in pkg.reverseDependencies:
        var depName = revDep[0].formatPkgName()
        
        if not depGroups.hasKey(depName):
          depGroups[depName] = @[]
        depGroups[depName].add(revDep[1])
      
      var depNames = toSeq(depGroups.keys)
      depNames.sort()
      
      # Format each dependency group
      var currentLine = depStr
      var lineLen = depStr.len
      
      for i, depName in depNames:
        var versions = depGroups[depName]
        
        # Sort versions in descending order
        versions.sort(proc(a, b: Version): int = 
          if a > b: -1
          elif a < b: 1
          else: 0
        )
        
        # Format versions as a compact list
        var versionStr = ""
        if versions.len == 1:
          versionStr = $versions[0].version
        else:
          versionStr = "v(" & versions.mapIt($it.version).join(", ") & ")"
        
        let depEntry = depName & " " & versionStr
        
        if i > 0:
          if lineLen + 2 + depEntry.len > 80:
            echo " ".repeat(maxPkgNameDisplayWidth + maxVersionDisplayWidth + 3), currentLine
            currentLine = "            " & depEntry
            lineLen = 12 + depEntry.len
          else:
            currentLine.add ", " & depEntry
            lineLen += 2 + depEntry.len
        else:
          currentLine.add depEntry
          lineLen += depEntry.len
      
      echo " ".repeat(maxPkgNameDisplayWidth + maxVersionDisplayWidth + 3), currentLine

proc dumpPackageVersionTable*(pkg: PackageInfo, pkgVersionTable: Table[string, PackageVersions], options: Options, nimBin: Option[string]) =
  # Display header
  echo "PACKAGE".alignLeft(maxPkgNameDisplayWidth), "VERSION".alignLeft(maxVersionDisplayWidth), "REQUIREMENTS"
  echo "-".repeat(maxPkgNameDisplayWidth + maxVersionDisplayWidth + 4)
  
  var sortedPackages = toSeq(pkgVersionTable.keys)
  sortedPackages.sort()
  
  if pkg.basicInfo.name in sortedPackages:
    sortedPackages.delete(sortedPackages.find(pkg.basicInfo.name))
    sortedPackages.insert(pkg.basicInfo.name, 0)
  
  # Display each package and its versions
  for pkgName in sortedPackages:
    let pkgVersions = pkgVersionTable[pkgName]
    var isFirstVersion = true
    
    # Sort versions in descending order (newest first)
    var sortedVersions = pkgVersions.versions
    sortedVersions.sort(proc(a, b: PackageMinimalInfo): int = 
      if a.version > b.version: -1
      elif a.version < b.version: 1
      else: 0
    )
    
    for version in sortedVersions:
      # Format package name - extract repo name for GitHub URLs
      var displayName = formatPkgName(pkgName)
      
      # Only show package name for first version
      let name = if isFirstVersion: displayName else: ""
      let rootMarker = if version.isRoot: "*" else: " "
      
      # Format requirements
      var reqStr = ""
      for i, req in version.requires:
        if i > 0: reqStr.add ", "
        
        var reqName = formatPkgName(req.name)
        
        reqStr.add reqName
        if req.ver.kind != verAny:
          reqStr.add " " & $req.ver
      
      # Display version line
      echo rootMarker, " ", 
           name.alignLeft(maxPkgNameDisplayWidth - 1), 
           $version.version.version.alignLeft(maxVersionDisplayWidth), 
           if reqStr.len > 0: reqStr.splitLines()[0] else: ""
      
      # If requirements were long, display them on additional indented lines
      if reqStr.len > 0 and (reqStr.contains('\n') or reqStr.len > 80):
        let lines = reqStr.split(", ")
        var currentLine = ""
        for i, req in lines:
          if currentLine.len + req.len + 2 > 80:  # +2 for ", "
            if currentLine.len > 0:
              echo " ".repeat(maxPkgNameDisplayWidth + maxVersionDisplayWidth + 3), currentLine
            currentLine = req
          else:
            if currentLine.len > 0:
              currentLine.add ", "
            currentLine.add req
        
        if currentLine.len > 0:
          echo " ".repeat(maxPkgNameDisplayWidth + maxVersionDisplayWidth + 3), currentLine
      
      isFirstVersion = false

proc dumpPackageVersionTable*(pkg: PackageInfo, pkgList: seq[PackageInfo], options: Options, nimBin: Option[string]) =
  let pkgVersionTable = getPkgVersionTable(pkg, pkgList, options, nimBin)
  dumpPackageVersionTable(pkg, pkgVersionTable, options, nimBin)

proc debugSATResult*(options: Options, calledFrom: string) =
  let satResult = options.satResult
  let color = "\e[32m"
  let reset = "\e[0m"
  echo "=== DEBUG SAT RESULT ==="
  echo "Called from: ", calledFrom
  echo "--------------------------------"
  echo color, "Pass: ", reset, satResult.pass
  if satResult.nimResolved.pkg.isSome:
    echo color, "Selected Nim: ", reset, satResult.nimResolved.pkg.get.basicInfo.name, " ", satResult.nimResolved.version
  else:
    echo "No Nim selected"
  echo color, "Bootstrap Nim: ", reset, "isSet: ", satResult.bootstrapNim.nimResolved.pkg.isSome, " version: ", satResult.bootstrapNim.nimResolved.version

  let pkgsWithErrors = satResult.pkgs.toSeq.filterIt(it.declarativeParserErrors.len > 0)
  if pkgsWithErrors.len > 0:
    echo color, "Declarative parser errors: ", reset
    for pkg in pkgsWithErrors:
      echo "  ", pkg.basicInfo.name, " ", pkg.basicInfo.version, ": ", pkg.declarativeParserErrors

  if satResult.rootPackage.hasLockFile(options):
    echo "Root package has lock file: ", satResult.rootPackage.myPath.parentDir() / "nimble.lock"
  else:
    echo "Root package does not have lock file"
  echo color, "Root package: ", reset, satResult.rootPackage.basicInfo.name, " ", satResult.rootPackage.basicInfo.version, " ", satResult.rootPackage.myPath
  echo color, "Root requires: ", reset, satResult.rootPackage.requires.mapIt(it.name & " " & $it.ver)
  echo color, "Solved packages: ", reset, satResult.solvedPkgs.mapIt(it.pkgName & " " & $it.version & " " & $it.deps.mapIt(it.pkgName))
  echo color, "Solution as Packages Info: ", reset, satResult.pkgs.mapIt(it.basicInfo.name & " " & $it.basicInfo.version)
  if options.isUpgrade:
    echo color, "Upgrade versions: ", reset, options.action.packages.mapIt(it.name & " " & $it.ver)
    echo color, "RESULT REVISIONS ", reset, satResult.pkgs.mapIt(it.basicInfo.name & " " & $it.metaData.vcsRevision)
    echo color, "PKG LIST REVISIONS ", reset, satResult.pkgList.mapIt(it.basicInfo.name & " " & $it.metaData.vcsRevision)
  echo color, "Packages to install: ", reset, satResult.pkgsToInstall
  echo color, "Installed pkgs: ", reset, satResult.pkgs.mapIt(it.basicInfo.name)
  echo color, "Build pkgs: ", reset, satResult.buildPkgs.mapIt(it.basicInfo.name)
  echo color, "Packages url: ", reset, satResult.pkgs.mapIt(it.metaData.url)
  echo color, "Package list: ", reset, satResult.pkgList.mapIt(it.basicInfo.name)
  echo color, "PkgList path: ", reset, satResult.pkgList.mapIt(it.myPath.parentDir)
  echo color, "Nimbledir: ", reset, options.getNimbleDir()
  echo color, "Nimble Action: ", reset, options.action.typ
  if options.action.typ == actionDevelop:
    echo color, "Path: ", reset, options.action.packages.mapIt(it.name)
    echo color, "Dev actions: ", reset, options.action.devActions.mapIt(it.actionType)
    echo color, "Dependencies: ", reset, options.action.packages.mapIt(it.name)
    for devAction in options.action.devActions:
      echo color, "Dev action: ", reset, devAction.actionType
      echo color, "Argument: ", reset, devAction.argument
  echo "--------------------------------"

proc getSolvedPkg*(satResult: SATResult, pkgInfo: PackageInfo): SolvedPackage =
  for solvedPkg in satResult.solvedPkgs:
    if pkgInfo.basicInfo.name.toLowerAscii() == solvedPkg.pkgName.toLowerAscii(): #No need to check version as they should match by design
      return solvedPkg
  raise newNimbleError[NimbleError]("Package not found in solution: " & $pkgInfo.basicInfo.name & " " & $pkgInfo.basicInfo.version)

proc enableFeatures*(rootPackage: var PackageInfo, options: var Options) =
  for feature in options.features:
    if feature in rootPackage.features:
      rootPackage.requires &= rootPackage.features[feature]
  for pkgName, activeFeatures in rootPackage.activeFeatures:
    var resolvedName = pkgName[0]
    if resolvedName.isFileURL:
      resolvedName = extractFilePathFromURL(resolvedName).lastPathPart
    appendGloballyActiveFeatures(resolvedName, activeFeatures)
    # Add the feature's requires directly to the root package so the SAT solver
    # always resolves them, regardless of which version of the dependency is picked
    for pkg in options.filePathPkgs:
      if cmpIgnoreCase(pkg.basicInfo.name, resolvedName) == 0:
        for feature in activeFeatures:
          if feature in pkg.features:
            rootPackage.requires &= pkg.features[feature]
        break

  #If root is a development package, we need to activate it as well:
  if rootPackage.isTopLevel(options) and ("dev" in rootPackage.features or "patch" in rootPackage.features):
    if "dev" in rootPackage.features:
      rootPackage.requires &= rootPackage.features["dev"]
      appendGloballyActiveFeatures(rootPackage.basicInfo.name, @["dev"])
    if "patch" in rootPackage.features:
      rootPackage.requires &= rootPackage.features["patch"]
      appendGloballyActiveFeatures(rootPackage.basicInfo.name, @["patch"])

proc getSolvedPkgFromInstalledPkgs*(satResult: SATResult, solvedPkg: SolvedPackage, options: Options, vcsRevision: Sha1Hash = notSetSha1Hash): Option[PackageInfo] =
  for pkg in satResult.pkgList:
    if pkg.basicInfo.name == solvedPkg.pkgName and pkg.basicInfo.version == solvedPkg.version:
      # If vcsRevision is specified (from lock file), also check that it matches
      if vcsRevision != notSetSha1Hash and pkg.metaData.vcsRevision != vcsRevision:
        continue
      return some(pkg)
  return none(PackageInfo)

proc preferLockedVersions(versions: var Table[string, PackageVersions],
    locked: LockFileDeps, targets: HashSet[string], options: Options,
    output: var string): seq[SolvedPackage] =
  ## Select the requested upgrades first, then retain every compatible pin.
  ## Pins restrict a package's candidates, rather than adding root requirements:
  ## dependencies removed by an upgrade must still be able to leave the graph.
  result = versions.getSolvedPackages(output, options)
  if result.len == 0:
    raise resolutionFailureError(
      "The requested versions are incompatible with the dependency " &
      "requirements:\n" & output)

  var selectedTargets = initTable[string, Version]()
  for pkg in result:
    if pkg.pkgName.toLowerAscii in targets:
      selectedTargets[pkg.pkgName.toLowerAscii] = pkg.version

  var pins = initTable[string, PackageVersions]()
  for key, pv in versions.mpairs:
    let name = pv.versions[0].name.toLowerAscii
    if name in selectedTargets:
      let selected = selectedTargets[name]
      pv.versions = pv.versions.filterIt(it.version == selected)
    elif name in locked:
      let pinned = locked[name].version
      let candidates = pv.versions.filterIt(it.version == pinned)
      if candidates.len > 0:
        pins[key] = PackageVersions(pkgName: pv.pkgName, versions: candidates)

  # The common case needs only one more solve: all other pins still work.
  var allPinned = versions
  for key, pin in pins:
    allPinned[key] = pin
  var trialOutput = ""
  let allPinnedSolution = allPinned.getSolvedPackages(trialOutput, options)
  if allPinnedSolution.len > 0:
    versions = allPinned
    output = trialOutput
    return allPinnedSolution

  # Some pins conflict with the upgrade. Keep them one at a time whenever a
  # complete solution still exists, including changes to reverse dependencies.
  # Stable ordering makes the result independent of the lock file's ordering.
  var names = toSeq(pins.keys)
  names.sort()
  for name in names:
    let previous = versions[name]
    versions[name] = pins[name]
    trialOutput = ""
    let solution = versions.getSolvedPackages(trialOutput, options)
    if solution.len == 0:
      versions[name] = previous
    else:
      result = solution
      output = trialOutput

proc solveSelectiveUpgrade(satResult: var SATResult, locked: LockFileDeps,
    pkgList: seq[PackageInfo], options: Options, nimBin: Option[string]) =
  var targets = initHashSet[string]()
  var root = satResult.rootPackage
  for requested in options.action.packages:
    let name = requested.name.resolveAlias(options)
    targets.incl(name.toLowerAscii)
    var direct = false
    for req in root.requires.mitems:
      if cmpIgnoreCase(req.name.resolveAlias(options), name) == 0:
        direct = true
        if requested.ver.kind != verAny:
          req.ver = requested.ver
    if not direct:
      root.requires.add((name: name, ver: requested.ver))

  # A lock records dependency names, but not their version ranges. Read the
  # actual manifests at the pinned revisions before deciding which pins work.
  # In particular, never validate an old pin using a newer version's requires.
  var pins: LockFileDeps
  var pinnedPackages: seq[PackageInfo]
  for name, dep in locked:
    let key = name.toLowerAscii
    if key in targets or name.isNim:
      continue
    pins[key] = dep
    var pinned = none(PackageInfo)
    for pkg in pkgList:
      if cmpIgnoreCase(pkg.basicInfo.name, name) == 0 and
         pkg.metadata.vcsRevision == dep.vcsRevision and
         (pkg.basicInfo.version == dep.version or
          dep.version in pkg.metadata.specialVersions):
        pinned = some(pkg)
        break
    if pinned.isNone:
      let dlInfo = getLockFileDownloadInfo(
        (name: name, ver: dep.version.toVersionRange()), dep, options)
      let (downloaded, _) = downloadFromDownloadInfo(dlInfo, options, nimBin)
      pinned = some(getPkgInfo(downloaded.dir, options, nimBin, pikRequires))
    var pkg = pinned.get
    pkg.basicInfo.version = dep.version
    pinnedPackages.add(pkg)

  # Discover once. Installed versions of the requested packages must not mask
  # an updated branch or revision. Pinned manifests also supply requirements
  # that may no longer occur in any of the newest package versions.
  let preferred = pkgList.filterIt(
    it.basicInfo.name.toLowerAscii notin targets and
    it.basicInfo.name.toLowerAscii notin pins) & pinnedPackages
  var rootMinimal = root.getMinimalInfo(options)
  rootMinimal.isRoot = true
  let discovered = waitFor collectAllVersions(rootMinimal, options,
    downloadMinimalPackage, preferred.mapIt(it.getMinimalInfo(options)), nimBin)
  # Discovery already consults the cache and expands active features. Use its
  # answer directly so older cache entries cannot mask refreshed manifests.
  var versions = initTable[string, PackageVersions]()
  for name, candidates in discovered:
    versions[name] = candidates
  versions[rootMinimal.name] = PackageVersions(
    pkgName: rootMinimal.name, versions: @[rootMinimal])
  versions.normalizeRequirements(options)
  versions.normalizeSpecialVersions(options)

  # Nim has already been resolved and configured by the caller.
  if "nim" in versions and "nim" notin targets and
     satResult.nimResolved.version != notSetVersion:
    versions["nim"] = PackageVersions(pkgName: "nim", versions: @[
      PackageMinimalInfo(name: "nim", version: satResult.nimResolved.version)])

  satResult.output = ""
  satResult.solvedPkgs = versions.preferLockedVersions(
    pins, targets, options, satResult.output).topologicalSort()
  satResult.solvedPkgs.postProcessSolvedPkgs(options, nimBin)
  satResult.pkgVersionTable = versions

  # Installation and locking must consume exactly the final solution. Carry
  # source revisions over only for retained pins, and discard the fresh solve's
  # speculative installation queue.
  satResult.pkgs = satResult.pkgs.toSeq.filterIt(it.basicInfo.name.isNim).toHashSet()
  satResult.pkgsToInstall = @[]
  for solved in satResult.solvedPkgs:
    if solved.pkgName == root.basicInfo.name or solved.pkgName.isNim:
      continue
    let key = solved.pkgName.toLowerAscii
    let retained = key in pins and solved.version == pins[key].version
    if retained:
      satResult.lockFileDeps[solved.pkgName] = pins[key]
    var installed = false
    for pkg in pkgList:
      if cmpIgnoreCase(pkg.basicInfo.name, solved.pkgName) == 0 and
         (pkg.basicInfo.version == solved.version or
          solved.version in pkg.metadata.specialVersions) and
         (not retained or pkg.metadata.vcsRevision == pins[key].vcsRevision) and
         key notin targets:
        satResult.pkgs.incl(pkg)
        installed = true
        break
    if not installed:
      satResult.pkgsToInstall.add((solved.pkgName, solved.version))


proc solveLockFileDeps*(satResult: var SATResult, pkgList: seq[PackageInfo], options: Options, nimBin: Option[string]) =
  let lockFile = options.lockFile(satResult.rootPackage.myPath.parentDir())
  let currentRequires = satResult.rootPackage.requires
  satResult.lockFileDeps.clear()
  var locked: LockFileDeps
  var existingRequires = newSeq[(string, string, Version)]()
  for name, dep in lockFile.getLockedDependencies.lockedDepsFor(options):
    locked[name] = dep
    existingRequires.add((name, dep.url, dep.version))

  # Check for new requirements not in lock file
  var shouldSolve = false
  # Collect the names of packages being explicitly upgraded so we can skip them
  # in the shouldSolve check. When upgrading, changed requirements for the
  # upgraded packages are expected and should not trigger a full re-solve.
  var upgradePkgNames: seq[string]
  if options.isUpgrade:
    for pkg in options.action.packages:
      upgradePkgNames.add(pkg.name.resolveAlias(options).toLowerAscii())
  for current in currentRequires:
    let currentName = current.name.resolveAlias(options).toLowerAscii()
    # Skip packages being explicitly upgraded — their requirements are expected to change
    if currentName in upgradePkgNames:
      continue
    var found = false
    for existing in existingRequires:
      let existingName = existing[0].resolveAlias(options).toLowerAscii()
      # match name or url against the lockfile requires
      let matches =
        if current.name.isURL: cmpIgnoreCase(current.name, existing[1]) == 0
        else: currentName == existingName
      # A `#branch`/`#commit`/`#tag` requirement is only satisfied by that exact
      # special version, so `satisfiesConstraint` - not `withinRange` - decides
      # it here. `withinRange` deliberately accepts any normal version for a
      # special range (post-download validation: the ref was fetched and its
      # nimble file carries a normal version), which would report a requirement
      # changed from `== 2.4.0` to `#<commit>` as already satisfied by the
      # locked `2.4.0` and leave the whole lock file stale.
      let satisfied =
        if current.ver.kind == verSpecial: existing[2].satisfiesConstraint(current.ver)
        else: existing[2].withinRange(current.ver)
      if matches and satisfied:
        found = true
        break
    if not found:
      if current.name.isNim:
        #ignore if nim wasnt present in the lock file as by default we dont save nim in the lock file
        if not existingRequires.anyIt(it[0].isNim):
          continue
      shouldSolve = true
      break

  # No-arg `nimble upgrade` = upgrade-all: re-solve the whole graph to the newest
  # compatible versions. The incremental actionUpgrade branch below only bumps the
  # named packages and keeps the rest locked, which is the wrong model here, so force
  # the full fresh solve. (The install-preferring local solve in solvePackages is
  # already skipped for actionUpgrade, so this resolves to newest.)
  if options.isUpgrade and options.action.packages.len == 0:
    shouldSolve = true

  var pkgListDecl: seq[PackageInfo]
  for pkg in pkgList:
    try:
      pkgListDecl.add(pkg.toRequiresInfo(options, nimBin))
    except BabelPackageError:
      discard # babel packages are unsupported — skip them, warning already displayed

  # Skip the re-solve when running outside a project dir.
  if not options.thereIsNimbleFile:
    shouldSolve = false

  satResult.pkgList = pkgListDecl.toHashSet()
  # Upgrade-all (`lock --refresh`, the deprecated `upgrade`) is the only case
  # that re-solves the whole graph from scratch - moving every pin is precisely
  # what it was asked to do. A requirement the lock file does not cover has to
  # be resolved as well, but there the pins that still satisfy the graph must
  # survive: adding one dependency (by hand or through `nimble add`) must not
  # drag every other one forward, nor move the compiler.
  let upgradeAll = options.isUpgrade and options.action.packages.len == 0
  if shouldSolve and upgradeAll:
    # Create fresh package list and solve ALL requirements
    satResult.pkgs = solvePackages(
      satResult.rootPackage,
      pkgListDecl,
      satResult.pkgsToInstall,
      options,
      satResult.output,
      satResult.solvedPkgs,
      nimBin
    )
    if satResult.solvedPkgs.len == 0:
      raise resolutionFailureError(options.resolutionFailureMessage)
  elif shouldSolve or options.isUpgrade:
    satResult.solveSelectiveUpgrade(locked, pkgListDecl, options, nimBin)

  else:
    # No new requirements and not upgrading
    satResult.solvedPkgs = satResult.solvedPkgs.filterIt(not it.pkgName.isNim)
    satResult.pkgsToInstall = @[]
    satResult.pkgs.clear()
    for name, dep in lockFile.getLockedDependencies.lockedDepsFor(options):
      let requirements = dep.dependencies.mapIt((name: it, ver: VersionRange(kind: verAny)))
      let solvedPkg = SolvedPackage(pkgName: name, version: dep.version, requirements: requirements)
      satResult.solvedPkgs.add(solvedPkg)
      # Keep the complete locked source for the installer. Resolving only the
      # package name here would consult packages.json again, which can select a
      # different repository or reject a package that is not indexed (#1837).
      satResult.lockFileDeps[name] = dep
      if name.isNim: continue
      let depInfo = satResult.getSolvedPkgFromInstalledPkgs(solvedPkg, options, dep.vcsRevision)
      if depInfo.isSome:
        satResult.pkgs.incl(depInfo.get)
      else:
        satResult.pkgsToInstall.add((name, dep.version))

proc solutionToFullInfo*(satResult: SATResult, options: var Options, nimBin: Option[string]) {.instrument.} =
  if satResult.rootPackage.infoKind != pikFull and not satResult.rootPackage.basicInfo.name.isNim:
    # Re-reading the root from disk drops whatever was appended to its requires
    # before the solve: `--requires`, the packages named by `install`/`add` and
    # the task requires that `lock` folds in. Every one of them has to survive,
    # because the lock file logic that runs after this reads the root's requires
    # to decide what changed. Without them it concludes nothing did: it keeps a
    # pin the user just asked to constrain away (`--requires`), and it drops a
    # package that was just added (`add` on a project with a lock file - the
    # package is solved, then silently discarded again).
    let solvedRequires = satResult.rootPackage.requires
    satResult.rootPackage = getPkgInfo(satResult.rootPackage.getNimbleFileDir, options, nimBin = nimBin).toRequiresInfo(options, nimBin = nimBin)
    satResult.rootPackage.enableFeatures(options)
    for require in solvedRequires:
      if not satResult.rootPackage.requires.anyIt(
          cmpIgnoreCase(it.name, require.name) == 0 and it.ver == require.ver):
        satResult.rootPackage.requires.add require
