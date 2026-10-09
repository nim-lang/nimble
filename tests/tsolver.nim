{.used.}

# Copyright (C) the Nimble contributors. All rights reserved.
# BSD License. Look at license.txt for more info.

import unittest, os, osproc
import testscommon
import std/[tables, json, jsonutils, strutils, sequtils, times, options]
import chronos
import nimblepkg/[version, nimblesolver, options, config, packageinfotypes,
                  versiondiscovery, urls, download]
from nimblepkg/common import cd, NimbleError

let nimBin = some("nim")
#Test utils:
proc downloadAndStorePackageVersionTableFor(pkgName: string, options: Options) =
  #Downloads all the dependencies for a given package and store the minimal version of the deps in a json file.
  var fileName = pkgName
  if pkgName.startsWith("https://"):
    let pkgUrl = pkgName
    fileName = pkgUrl.split("/")[^1].split(".")[0]
  
  let path = "packageMinimal" / fileName & ".json"
  if fileExists(path):
    return
  let pv: PkgTuple = (pkgName, VersionRange(kind: verAny))
  var pkgInfo = downloadPkInfoForPv(pv, options, nimBin = nimBin)
  var root = pkgInfo.getMinimalInfo(options)
  root.isRoot = true
  var pkgVersionTable = waitFor collectAllVersions(root, options, downloadMinimalPackage, nimBin = nimBin)
  pkgVersionTable[pkgName] = PackageVersions(pkgName: pkgName, versions: @[root])
  let json = pkgVersionTable.toJson()
  writeFile(path, json.pretty())

proc downloadAllPackages() {.used.} = 
  var options = initOptions()
  options.nimBin = some options.makeNimBin("nim")
  # options.config.packageLists["uing"] = PackageList(name: pkgName, urls: @[pkgUrl])
  options.config.packageLists["official"] = PackageList(name: "Official", urls: @[
    "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
    "https://nim-lang.org/nimble/packages.json"
  ])

  # let packages = getPackageList(options).mapIt(it.name)
  let importantPackages = [
  "alea", "argparse", "arraymancer", "ast_pattern_matching", "asyncftpclient", "asyncthreadpool", "awk", "bigints", "binaryheap", "BipBuffer", "blscurve",
  "bncurve", "brainfuck", "bump", "c2nim", "cascade", "cello", "checksums", "chroma", "chronicles", "chronos", "cligen", "combparser", "compactdict", 
  "https://github.com/alehander92/comprehension", "cowstrings", "criterion", "datamancer", "dashing", "delaunay", "docopt", "drchaos", "https://github.com/jackmott/easygl", "elvis", "fidget", "fragments", "fusion", "gara", "glob", "ggplotnim", 
  "https://github.com/disruptek/gittyup", "gnuplot", "https://github.com/disruptek/gram", "hts", "httpauth", "illwill", "inim", "itertools", "iterutils", "jstin", "karax", "https://github.com/jblindsay/kdtree", "loopfusion", "lockfreequeues", "macroutils", "manu", "markdown", 
  "measuremancer", "memo", "msgpack4nim", "nake", "https://github.com/nim-lang/neo", "https://github.com/nim-lang/NESM", "netty", "nico", "nicy", "nigui", "nimcrypto", "NimData", "nimes", "nimfp", "nimgame2", "nimgen", "nimib", "nimlsp", "nimly", 
  "nimongo", "https://github.com/disruptek/nimph", "nimPNG", "nimpy", "nimquery", "nimsl", "nimsvg", "https://github.com/nim-lang/nimterop", "nimwc", "nimx", "https://github.com/zedeus/nitter", "norm", "npeg", "numericalnim", "optionsutils", "ormin", "parsetoml", "patty", "pixie", 
  "plotly", "pnm", "polypbren", "prologue", "protobuf", "pylib", "rbtree", "react", "regex", "results", "RollingHash", "rosencrantz", "sdl1", "sdl2_nim", "sigv4", "sim", "smtp", "https://github.com/genotrance/snip", "ssostrings", 
  "stew", "stint", "strslice", "strunicode", "supersnappy", "synthesis", "taskpools", "telebot", "tempdir", "templates", "https://krux02@bitbucket.org/krux02/tensordslnim.git", "terminaltables", "termstyle", "timeit", "timezones", "tiny_sqlite", 
  "unicodedb", "unicodeplus", "https://github.com/alaviss/union", "unpack", "weave", "websocket", "winim", "with", "ws", "yaml", "zero_functional", "zippy"
  ]
  let ignorePackages = ["rpgsheet", 
  "arturo", "argument_parser", "murmur", "nimgame", "locale", "nim-locale",
  "nim-ao", "ao", "termbox", "linagl", "kwin", "yahooweather", "noaa",
  "nimwc", "pylib",
  "artemis"]
  let startAt = 0#importantPackages.find("rbtree")
  let toDownload = importantPackages
  for i, pkg in toDownload:
    if i >= startAt or pkg in ignorePackages:
      continue
    echo "Downloading ", pkg
    downloadAndStorePackageVersionTableFor(pkg, options)
    echo "Done with ", pkg

proc fromJsonHook(pv: var PkgTuple, jsonNode: JsonNode,
                  opt = Joptions()) {.used.} =
  if jsonNode.kind == Jstring:
    pv = parseRequires(jsonNode.getStr())
  else:
    raise newException(ValueError, "Expected a string for PkgTuple found: " & $jsonNode.kind & " val: " & $jsonNode)

proc resolve(pkgVersionTable: Table[string, PackageVersions],
             solver: SolverKind, algorithm = raMaxVer):
    tuple[packages: Table[string, Version], output: string] =
  ## Resolves the table the way every nimble command does, through
  ## `getSolvedPackages`, with `solver`. No packages means no solution, and
  ## `output` says why.
  var options = initOptions()
  options.solver = solver
  options.resolutionAlgorithm = algorithm
  for pkg in pkgVersionTable.getSolvedPackages(result.output, options):
    result.packages[pkg.pkgName] = pkg.version

proc table(root: PackageMinimalInfo,
           deps: varargs[PackageVersions]): Table[string, PackageVersions] =
  result = initTable[string, PackageVersions]()
  result[root.name] = PackageVersions(pkgName: root.name, versions: @[root])
  for d in deps:
    result[d.pkgName] = d

for solver in SolverKind:
  suite "dependency resolution (" & $solver & ")":
    test "can solve a simple graph":
      let pkgVersionTable = {
        "a": PackageVersions(pkgName: "a", versions: @[
          PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
            (name:"b", ver: parseVersionRange ">= 0.1.0")
          ], isRoot:true),
        ]),
        "b": PackageVersions(pkgName: "b", versions: @[
          PackageMinimalInfo(name: "b", version: newVersion "0.1.0")
        ])
      }.toTable()
      let (packages, _) = resolve(pkgVersionTable, solver)
      check packages.len == 2
      check packages["a"] == newVersion "3.0"
      check packages["b"] == newVersion "0.1.0"

    test "nitter: same package from different fork URLs (asynctools)":
      # nitter's dep tree requires asynctools from multiple URLs:
      # - jester#baca3f requires "https://github.com/timotheecour/asynctools#pr_fix_compilation"
      # - httpbeast requires "asynctools#0e6bdc3ed5bae8c7cc9" (name-based → official)
      # normalizeSpecialVersions picks the first special version (topologically)
      # and rewrites all other requirements to use it.

      let pkgName = "https://github.com/zedeus/nitter"
      let pv: PkgTuple = (pkgName, VersionRange(kind: verAny))
      var options = initOptions()
      options.solver = solver
      options.nimBin = some options.makeNimBin("nim")
      options.config.packageLists["official"] = PackageList(name: "Official", urls: @[
        "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
        "https://nim-lang.org/nimble/packages.json"
      ])

      var pkgInfo = downloadPkInfoForPv(pv, options, nimBin = nimBin)
      var pkgsToInstall: seq[(string, Version)] = @[]
      var solvedPkgs: seq[SolvedPackage] = @[]
      var output = ""

      # lenient=true (default): should resolve successfully
      options.lenient = true
      discard solvePackages(pkgInfo, @[], pkgsToInstall, options, output, solvedPkgs, nimBin)
      check solvedPkgs.len > 0

      # lenient=false: should fail with NimbleError on Linux/macOS where httpbeast is used (not used in windows)
      options.lenient = false
      when defined(windows):
        discard solvePackages(pkgInfo, @[], pkgsToInstall, options, output, solvedPkgs, nimBin)
      else:
        expect NimbleError:
          discard solvePackages(pkgInfo, @[], pkgsToInstall, options, output, solvedPkgs, nimBin)

    test "URL-keyed discovery versions reach the name node (websock split-brain)":
      # Mirrors the libp2pconflict failure: libp2p 1.x requires websock by name,
      # libp2p 2.x by URL. Discovery can end up keying the full version list
      # under the URL while the name node holds only the newest version. The
      # older websock (no nimcrypto pin) is the only one compatible with quic's
      # nimcrypto pin, so this graph only solves if the URL node's versions are
      # merged into the name node during normalization.
      const wsUrl = "https://github.com/status-im/nim-websock"
      var t = {
        "root": PackageVersions(pkgName: "root", versions: @[
          PackageMinimalInfo(name: "root", version: newVersion "0.1.0", requires: @[
            (name: "libp2p", ver: VersionRange(kind: verAny)),
            (name: "quic", ver: parseVersionRange "#abc")], isRoot: true)]),
        "libp2p": PackageVersions(pkgName: "libp2p", versions: @[
          PackageMinimalInfo(name: "libp2p", version: newVersion "1.15.3", requires: @[
            (name: "websock", ver: parseVersionRange ">= 0.2.1")]),
          PackageMinimalInfo(name: "libp2p", version: newVersion "2.3.0", requires: @[
            (name: wsUrl, ver: parseVersionRange ">= 0.4.0")])]),
        "quic": PackageVersions(pkgName: "quic", versions: @[
          PackageMinimalInfo(name: "quic", version: newVersion "#abc", requires: @[
            (name: "nimcrypto", ver: parseVersionRange ">= 0.6.0 & < 0.7.0")])]),
        "websock": PackageVersions(pkgName: "websock", versions: @[
          PackageMinimalInfo(name: "websock", version: newVersion "0.4.2", requires: @[
            (name: "nimcrypto", ver: parseVersionRange ">= 0.7.0")], url: wsUrl)]),
        wsUrl: PackageVersions(pkgName: wsUrl, versions: @[
          PackageMinimalInfo(name: "websock", version: newVersion "0.3.0", requires: @[
            (name: "nimcrypto", ver: VersionRange(kind: verAny))], url: wsUrl),
          PackageMinimalInfo(name: "websock", version: newVersion "0.4.2", requires: @[
            (name: "nimcrypto", ver: parseVersionRange ">= 0.7.0")], url: wsUrl)]),
        "nimcrypto": PackageVersions(pkgName: "nimcrypto", versions: @[
          PackageMinimalInfo(name: "nimcrypto", version: newVersion "0.6.4"),
          PackageMinimalInfo(name: "nimcrypto", version: newVersion "0.7.3")]),
      }.toTable()
      var opts = initOptions()
      t.normalizeRequirements(opts)
      t.normalizeSpecialVersions(opts)
      let (packages, _) = resolve(t, solver)
      check packages.getOrDefault("libp2p") == newVersion "1.15.3"
      check packages.getOrDefault("websock") == newVersion "0.3.0"

    test "solves 'Conflicting dependency resolution' #1162":
      let pkgVersionTable = {
        "a": PackageVersions(pkgName: "a", versions: @[
          PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
            (name:"b", ver: parseVersionRange ">= 0.1.4"),
            (name:"c", ver: parseVersionRange ">= 0.0.5 & <= 0.1.0")
          ], isRoot:true),
        ]),
        "b": PackageVersions(pkgName: "b", versions: @[
          PackageMinimalInfo(name: "b", version: newVersion "0.1.4", requires: @[
            (name:"c", ver: VersionRange(kind: verAny))
          ]),
        ]),
        "c": PackageVersions(pkgName: "c", versions: @[
          PackageMinimalInfo(name: "c", version: newVersion "0.1.0"),
          PackageMinimalInfo(name: "c", version: newVersion "0.2.1")
        ])
      }.toTable()
      let (packages, _) = resolve(pkgVersionTable, solver)
      check packages.len == 3
      check packages["a"] == newVersion "3.0"
      check packages["b"] == newVersion "0.1.4"
      check packages["c"] == newVersion "0.1.0"

    test "dont solve unsatisfable":
      let pkgVersionTable = {
        "a": PackageVersions(pkgName: "a", versions: @[
          PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
            (name:"b", ver: parseVersionRange ">= 0.5.0")
          ], isRoot:true),
        ]),
        "b": PackageVersions(pkgName: "b", versions: @[
          PackageMinimalInfo(name: "b", version: newVersion "0.1.0")
        ])
      }.toTable()
      let (packages, output) = resolve(pkgVersionTable, solver)
      echo output
      check packages.len == 0

    test "issue #1162":
      removeDir("conflictingdepres")
      let exitCode1 = execCmd("git checkout conflictingdepres/")
      check exitCode1 == QuitSuccess

      cd "conflictingdepres":
        #integration version of the test above
        #[
          The folder structure of the test is key for the setup:
            Notice how inside the pkgs2 folder (convention when using local packages) there are 3 folders
            where c has two versions of the same package. The version is retrieved counterintuitively from 
            the nimblemeta.json special version field. 
        ]#
        let (output, exitCode) = execNimble("install", "-l",
                                            "--solver:" & $solver, "--verbose")
        check exitCode == QuitSuccess
        # The flag reached the resolver: only PubGrub announces itself.
        check ("Resolving dependencies with PubGrub" in output) ==
          (solver == skPubGrub)

      removeDir("conflictingdepres")
      let exitCode2 = execCmd("git checkout conflictingdepres/")
      check exitCode2 == QuitSuccess

    test "should be able to solve all nimble packages":
      # downloadAllPackages() #uncomment this to download all packages. It's better to just keep them cached as it takes a while.
      let now = now()
      var pks = 0
      for jsonFile in walkPattern("packageMinimal/*.json"):
        inc pks
        var pkgVersionTable = parseJson(readFile(jsonFile)).jsonTo(Table[string, PackageVersions], Joptions(allowMissingKeys: true))
        pkgVersionTable.normalizeRequirements(initOptions())
        let (packages, _) = resolve(pkgVersionTable, solver)
        if packages.len == 0:
          checkpoint jsonFile
        check packages.len > 0

      let ends = now()
      echo "Solved ", pks, " packages in ", ends - now, " seconds"

    test "#head requirements require #head available":
      # When a package requires dep#head, only #head should satisfy it, not tagged versions
      let pkgVersionTable = {
        "a": PackageVersions(pkgName: "a", versions: @[
          PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
            (name:"b", ver: parseVersionRange "#head")
          ], isRoot:true),
        ]),
        "b": PackageVersions(pkgName: "b", versions: @[
          PackageMinimalInfo(name: "b", version: newVersion "0.1.0")  # Only tagged version, no #head
        ])
      }.toTable()
      let (packages, _) = resolve(pkgVersionTable, solver)
      # Should fail because #head is required but only 0.1.0 is available
      check packages.len == 0

    test "#head requirements are satisfied when #head is available":
      # When #head is available, it should satisfy #head requirements
      let pkgVersionTable = {
        "a": PackageVersions(pkgName: "a", versions: @[
          PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
            (name:"b", ver: parseVersionRange "#head")
          ], isRoot:true),
        ]),
        "b": PackageVersions(pkgName: "b", versions: @[
          PackageMinimalInfo(name: "b", version: newVersion "0.1.0"),
          PackageMinimalInfo(name: "b", version: newVersion "#head")  # #head is available
        ])
      }.toTable()
      let (packages, _) = resolve(pkgVersionTable, solver)
      check packages.len == 2
      check packages["b"] == newVersion("#head")

    test "should not match other tags":
      let pkgVersionTable = {
        "a": PackageVersions(pkgName: "a", versions: @[
          PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
            (name:"b", ver: parseVersionRange "#head")
          ], isRoot:true),
        ]),
        "b": PackageVersions(pkgName: "b", versions: @[
          PackageMinimalInfo(name: "b", version: newVersion "#someOtherTag")
        ])
      }.toTable()
      let (packages, _) = resolve(pkgVersionTable, solver)
      check packages.len == 0

    test "should prioritize exact version matches":
      let pkgVersionTable = {
        "a": PackageVersions(pkgName: "a", versions: @[
          PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
            (name:"b", ver: parseVersionRange "== 1.0.0"),
            (name:"b", ver: parseVersionRange ">= 0.5.0")
          ], isRoot:true),
        ]),
        "b": PackageVersions(pkgName: "b", versions: @[
          PackageMinimalInfo(name: "b", version: newVersion "1.0.0"),
          PackageMinimalInfo(name: "b", version: newVersion "2.0.0")
        ])
      }.toTable()
      let (packages, _) = resolve(pkgVersionTable, solver)
      check packages.len == 2
      check packages["a"] == newVersion "3.0"
      check packages["b"] == newVersion "1.0.0"  # Should pick exact version 1.0.0 despite 2.0.0 being available

    test "if a dependency is unsatisfable, it should fallback to the previous version of the depency when available":
      let pkgVersionTable = {
        "a": PackageVersions(pkgName: "a", versions: @[
          PackageMinimalInfo(name: "a", version: newVersion "3.0", requires: @[
            (name:"b", ver: parseVersionRange ">= 0.5.0")
          ], isRoot: true),       
        ]),
        "b": PackageVersions(pkgName: "b", versions: @[
          PackageMinimalInfo(name: "b", version: newVersion "0.6.0", requires: @[
            (name:"c", ver: parseVersionRange ">= 0.0.5")
          ]),
          PackageMinimalInfo(name: "b", version: newVersion "0.5.0", requires: @[
         
          ]),
        ]),
        "c": PackageVersions(pkgName: "c", versions: @[
          PackageMinimalInfo(name: "c", version: newVersion "0.0.4"),
        ])
      }.toTable()

      let (packages, _) = resolve(pkgVersionTable, solver)
      check packages.len > 0

    test "should be able to solve packages with cycles in the requirements":
      # Packages with circular dependencies: a requires b, b requires a.
      # The solver should handle this without hanging or crashing.
      let pkgVersionTable = {
        "root": PackageVersions(pkgName: "root", versions: @[
          PackageMinimalInfo(name: "root", version: newVersion "1.0", requires: @[
            (name: "a", ver: parseVersionRange(">= 1.0")),
          ], isRoot: true),
        ]),
        "a": PackageVersions(pkgName: "a", versions: @[
          PackageMinimalInfo(name: "a", version: newVersion "1.0", requires: @[
            (name: "b", ver: parseVersionRange(">= 1.0")),
          ]),
        ]),
        "b": PackageVersions(pkgName: "b", versions: @[
          PackageMinimalInfo(name: "b", version: newVersion "1.0", requires: @[
            (name: "a", ver: parseVersionRange(">= 1.0")),
          ]),
        ]),
      }.toTable()
      let (packages, _) = resolve(pkgVersionTable, solver)
      check packages["a"] == newVersion "1.0"
      check packages["b"] == newVersion "1.0"

    test "should prefer newer versions (waku@0.36.0 over 0.1.0)":
      var pkgVersionTable = parseJson(readFile("packageMinimal/waku.json")).jsonTo(Table[string, PackageVersions], Joptions(allowMissingKeys: true))
      pkgVersionTable.normalizeRequirements(initOptions())
      let (packages, _) = resolve(pkgVersionTable, solver)
      check packages.len > 0
      check packages.getOrDefault("waku") == newVersion("0.36.0")

    test "normalizeRequirements resolves URL to nimble package name":
      # Reproduces nim-libp2p issue (github.com/vacp2p/nim-libp2p/pull/2348):
      # nimble file requires "https://github.com/user/nim-jwt.git#hash"
      # while CLI install adds "https://github.com/user/nim-jwt#hash" (no .git)
      # Both should normalize to the actual package name "jwt" from the .nimble file,
      # not keep the git URL as the dependency name.
      var pkgVersionTable = {
        "root": PackageVersions(pkgName: "root", versions: @[
          PackageMinimalInfo(name: "root", version: newVersion "1.0", requires: @[
            # From nimble file: URL with .git suffix
            (name: "https://github.com/vacp2p/nim-jwt.git", ver: VersionRange(kind: verSpecial, spe: newVersion "#abc123")),
            # From CLI install: URL without .git suffix
            (name: "https://github.com/vacp2p/nim-jwt", ver: VersionRange(kind: verSpecial, spe: newVersion "#abc123")),
            (name: "bearssl", ver: parseVersionRange(">= 0.2.7")),
          ], isRoot: true),
        ]),
        "jwt": PackageVersions(pkgName: "jwt", versions: @[
          PackageMinimalInfo(name: "jwt", version: newVersion "#abc123",
            url: "https://github.com/vacp2p/nim-jwt.git",
            requires: @[
              (name: "bearssl", ver: parseVersionRange(">= 0.2.7")),
            ]),
        ]),
        "bearssl": PackageVersions(pkgName: "bearssl", versions: @[
          PackageMinimalInfo(name: "bearssl", version: newVersion "0.2.8"),
        ]),
      }.toTable()
      # Set speSemanticVersion on the special version
      pkgVersionTable["jwt"].versions[0].version.speSemanticVersion = some("0.1.0")

      var options = initOptions()
      pkgVersionTable.normalizeRequirements(options)

      # Both URL requirements should be normalized to "jwt" (the .nimble name)
      let rootReqs = pkgVersionTable["root"].versions[0].requires
      for req in rootReqs:
        check(not req.name.isUrl)
      let jwtReqs = rootReqs.filterIt(it.name == "jwt")
      check jwtReqs.len == 2

      # The solver should find a valid solution using the package name
      let (packages, _) = resolve(pkgVersionTable, solver)
      check packages.hasKey("jwt")
      check packages.hasKey("bearssl")

    test "unsatisfiable deps report a conflict instead of crashing (json-rpc/chronos)":
      # nim-json-rpc's thread-chan branch: websock caps chronos below 4.4.0 while
      # asyncchannels pins chronos at a commit that declares 4.4.0 — a genuine
      # conflict. Dropping either requirement alone resolves fine, so the minimal
      # failing set is empty and the failure is explained by
      # generateUnsatisfiableMessage. That proc indexed g.nodes with the -1 that
      # findDependencyForDep returns for a requirement whose package has no node
      # (here: an old chronos needing a package that no longer exists), so the
      # code meant to explain the conflict crashed with an IndexDefect.
      var pkgVersionTable = initTable[string, PackageVersions]()
      let root = PackageMinimalInfo(
        name: "jsonrpc", version: newVersion("0.6.1"), isRoot: true,
        requires: @[("websock", parseVersionRange(">= 0.2.1 & < 0.5.0")),
                    ("asyncchannels", VersionRange(kind: verAny))])
      pkgVersionTable["jsonrpc"] = PackageVersions(pkgName: "jsonrpc", versions: @[root])
      pkgVersionTable["websock"] = PackageVersions(pkgName: "websock", versions: @[
        PackageMinimalInfo(name: "websock", version: newVersion("0.4.0"),
          requires: @[("chronos", parseVersionRange(">= 4.2.0 & < 4.4.0"))])])
      pkgVersionTable["asyncchannels"] = PackageVersions(
        pkgName: "asyncchannels", versions: @[
          PackageMinimalInfo(name: "asyncchannels", version: newVersion("0.1.0"),
            requires: @[("chronos", parseVersionRange("#b71392a13df707c0f02162b07caaddac2dd0103c"))])])
      var chronosPinned = newVersion("#b71392a13df707c0f02162b07caaddac2dd0103c")
      chronosPinned.speSemanticVersion = some("4.4.0")
      pkgVersionTable["chronos"] = PackageVersions(pkgName: "chronos", versions: @[
        PackageMinimalInfo(name: "chronos", version: chronosPinned),
        PackageMinimalInfo(name: "chronos", version: newVersion("4.2.2")),
        # An old version whose dependency no longer exists in the table.
        PackageMinimalInfo(name: "chronos", version: newVersion("3.0.0"),
          requires: @[("apackagethatdoesnotexist", VersionRange(kind: verAny))])])

      var output = ""
      var options = initOptions()
      options.solver = solver
      # No solution exists — the point is that we say so instead of crashing.
      let solved = pkgVersionTable.getSolvedPackages(output, options)
      check solved.len == 0
      check output.len > 0

    test "issue #1691: solver succeeds when old versions depend on missing packages":
      # Reproduces: prologue 0.3.x depends on "cookies" which no longer exists.
      # Newer versions (0.6.x) don't need it. The solver should skip old versions
      # and find a solution using the newer versions.
      var pkgVersionTable = initTable[string, PackageVersions]()
      # Root package requires prologue >= 0.6.0
      let root = PackageMinimalInfo(
        name: "testpkg", version: newVersion("0.1.0"), isRoot: true,
        requires: @[("prologue", parseVersionRange(">= 0.6.0"))])
      pkgVersionTable["testpkg"] = PackageVersions(pkgName: "testpkg", versions: @[root])
      # prologue has old version needing "cookies" (missing) and new version that doesn't
      let prologueOld = PackageMinimalInfo(
        name: "prologue", version: newVersion("0.3.2"),
        requires: @[("cookies", parseVersionRange(">= 0.2.0"))])
      let prologueNew = PackageMinimalInfo(
        name: "prologue", version: newVersion("0.6.8"),
        requires: @[("cookiejar", parseVersionRange(">= 0.2.0"))])
      pkgVersionTable["prologue"] = PackageVersions(
        pkgName: "prologue", versions: @[prologueOld, prologueNew])
      # cookiejar exists, cookies does NOT
      let cookiejar = PackageMinimalInfo(
        name: "cookiejar", version: newVersion("0.3.1"), requires: @[])
      pkgVersionTable["cookiejar"] = PackageVersions(
        pkgName: "cookiejar", versions: @[cookiejar])

      var output = ""
      var options = initOptions()
      options.solver = solver
      let solved = pkgVersionTable.getSolvedPackages(output, options)
      # Should find a solution using prologue 0.6.8 + cookiejar
      check solved.len > 0
      var foundPrologue = false
      for pkg in solved:
        if pkg.pkgName == "prologue":
          check pkg.version == newVersion("0.6.8")
          foundPrologue = true
      check foundPrologue

  suite "resolution algorithm (" & $solver & ")":
    let root = PackageMinimalInfo(
      name: "a", version: newVersion "1.0.0", isRoot: true,
      requires: @[(name: "b", ver: parseVersionRange ">= 1.0.0")])
    let bVersions = PackageVersions(pkgName: "b", versions: @[
      PackageMinimalInfo(name: "b", version: newVersion "1.0.0"),
      PackageMinimalInfo(name: "b", version: newVersion "1.1.0"),
      PackageMinimalInfo(name: "b", version: newVersion "1.2.0")])

    test "MaxVer selects the newest satisfying version":
      let picked = resolve(table(root, bVersions), solver, raMaxVer).packages
      check picked["b"] == newVersion "1.2.0"

    test "MinVer selects the oldest satisfying version":
      let picked = resolve(table(root, bVersions), solver, raMinVer).packages
      check picked["b"] == newVersion "1.0.0"

    test "MinVer still respects the lower bound of the range":
      # root requires b >= 1.1.0, so 1.0.0 is out of range; MinVer picks 1.1.0.
      let r = PackageMinimalInfo(
        name: "a", version: newVersion "1.0.0", isRoot: true,
        requires: @[(name: "b", ver: parseVersionRange ">= 1.1.0")])
      let picked = resolve(table(r, bVersions), solver, raMinVer).packages
      check picked["b"] == newVersion "1.1.0"

    test "MinVer does not prefer a special (#head) version over a regular one":
      let bWithHead = PackageVersions(pkgName: "b", versions: @[
        PackageMinimalInfo(name: "b", version: newVersion "1.0.0"),
        PackageMinimalInfo(name: "b", version: newVersion "1.1.0"),
        PackageMinimalInfo(name: "b", version: newVersion "#head")])
      let picked = resolve(table(root, bWithHead), solver, raMinVer).packages
      check picked["b"] == newVersion "1.0.0"
      check not picked["b"].isSpecial

    test "MinVer picks a #special version when another package requires it":
      let r = PackageMinimalInfo(
        name: "a", version: newVersion "1.0.0", isRoot: true,
        requires: @[
          (name: "b", ver: VersionRange(kind: verAny)),
          (name: "c", ver: parseVersionRange ">= 1.0.0")])
      let bVers = PackageVersions(pkgName: "b", versions: @[
        PackageMinimalInfo(name: "b", version: newVersion "0.1.0"),
        PackageMinimalInfo(name: "b", version: newVersion "0.2.0"),
        PackageMinimalInfo(name: "b", version: newVersion "#head")])
      let cVers = PackageVersions(pkgName: "c", versions: @[
        PackageMinimalInfo(name: "c", version: newVersion "1.0.0",
          requires: @[(name: "b", ver: parseVersionRange "#head")])])
      let picked = resolve(table(r, bVers, cVers), solver, raMinVer).packages
      check picked["b"] == newVersion "#head"
      check picked["b"].isSpecial
      check picked["c"] == newVersion "1.0.0"
