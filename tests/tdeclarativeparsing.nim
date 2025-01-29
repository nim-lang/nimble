{.used.}
import unittest
import testscommon
import std/[options, tables, sequtils, os]
import
  nimblepkg/[packageinfotypes, version, options, config, nimblesat, declarativeparser, cli]

proc getNimbleFileFromPkgNameHelper(pkgName: string): string =
  let pv: PkgTuple = (pkgName, VersionRange(kind: verAny))
  var options = initOptions()
  options.nimBin = some options.makeNimBin("nim")
  options.config.packageLists["official"] = PackageList(
    name: "Official",
    urls:
      @[
        "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
        "https://nim-lang.org/nimble/packages.json",
      ],
  )
  options.pkgCachePath = "./nimbleDir/pkgcache"
  let pkgInfo = downloadPkInfoForPv(pv, options)
  pkgInfo.myPath

suite "Declarative parsing":
  test "should parse requires from a nimble file":
    let nimbleFile = getNimbleFileFromPkgNameHelper("nimlangserver")
    let nimbleFileInfo = extractRequiresInfo(nimbleFile)
    let requires = nimbleFileInfo.getRequires()

    let expectedPkgs =
      @["nim", "json_rpc", "with", "chronicles", "serialization", "stew", "regex"]
    for pkg in expectedPkgs:
      check pkg in requires.mapIt(it[0])

  test "should be able to get all the released PackageVersions from a git local repository using the declarative parser":
    var options = initOptions()
    options.maxTaggedVersions = 0 #all
    options.nimBin = some options.makeNimBin("nim")
    options.config.packageLists["official"] = PackageList(
      name: "Official",
      urls:
        @[
          "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
          "https://nim-lang.org/nimble/packages.json",
        ],
    )
    options.pkgCachePath = "./nimbleDir/pkgcache"
    options.useDeclarativeParser = true
    options.noColor = true
    options.verbosity = DebugPriority
    setSuppressMessages(false)
    removeDir(options.pkgCachePath)
    let pv = parseRequires("nimfp >= 0.3.4")
    let downloadRes = pv.downloadPkgFromUrl(options)[0]
      #This is just to setup the test. We need a git dir to work on
    let repoDir = downloadRes.dir
    let downloadMethod = DownloadMethod git
    let packageVersions = getPackageMinimalVersionsFromRepo(
      repoDir, pv[0], downloadRes.version, downloadMethod, options
    )

    #we know these versions are available
    let availableVersions =
      @["0.3.4", "0.3.5", "0.3.6", "0.4.5", "0.4.4"].mapIt(newVersion(it))
    for version in availableVersions:
      check version in packageVersions.mapIt(it.version)
    check fileExists(repoDir / TaggedVersionsFileName)

#[NEXT STEPS:
 - Change processFreeDependenciesSAT to dont use PackageInfo until the last step.
]#
echo "end"