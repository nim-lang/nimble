{.used.}
import unittest
import testscommon
import std/[options, tables, sequtils, os]
import
  nimblepkg/[packageinfotypes, version, options, config, nimblesat, declarativeparser, cli, common]

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
    var activeFeatures = initTable[PkgTuple, seq[string]]()
    let requires = nimbleFileInfo.getRequires(activeFeatures)

    let expectedPkgs =
      @["nim", "json_rpc", "with", "chronicles", "serialization", "stew", "regex"]
    for pkg in expectedPkgs:
      check pkg in requires.mapIt(it[0])
  
  test "should parse bin from a nimble file":
    let nimbleFile = getNimbleFileFromPkgNameHelper("nimlangserver")
    let nimbleFileInfo = extractRequiresInfo(nimbleFile)
    check nimbleFileInfo.bin.len == 1
    when defined(windows):
      check nimbleFileInfo.bin["nimlangserver.exe"] == "nimlangserver.exe"
    else:
      check nimbleFileInfo.bin["nimlangserver"] == "nimlangserver"

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
      repoDir, pv, downloadRes.version, downloadMethod, options
    )

    #we know these versions are available
    let availableVersions =
      @["0.3.4", "0.3.5", "0.3.6", "0.4.5", "0.4.4"].mapIt(newVersion(it))
    for version in availableVersions:
      check version in packageVersions.mapIt(it.version)
    check fileExists(repoDir / TaggedVersionsFileName)

  test "should be able to install a package using the declarative parser":
    let (output, exitCode) = execNimble("--parser:declarative", "install", "nimlangserver")
    echo output
    check exitCode == QuitSuccess


suite "Declarative parser features":
  test "should be able to parse features from a nimble file":
    let nimbleFile =  "./features/features.nimble"
    let nimbleFileInfo = extractRequiresInfo(nimbleFile)
    let features = nimbleFileInfo.features
    check features.len == 2 #we need to account for the default 'dev' feature
    check features["feature1"] == @["stew"]

  test "should be able to install a package using the declarative parser with a feature":
    cd "features":
      #notice it imports stew, which will fail to compile if feature1 is not activated although it only imports it in the when part
      let (output, exitCode) = execNimble("--parser:declarative", "--features:feature1", "run")      
      check exitCode == QuitSuccess
      check output.processOutput.inLines("feature1 is enabled")

  test "should not enable features if not specified":
    cd "features":
      let (output, exitCode) = execNimble("run")
      check exitCode == QuitSuccess
      check output.processOutput.inLines("feature1 is disabled")

  test "should globally activate features specified in requires":
    cd "features":
      let (output, exitCode) = execNimble("--parser:declarative", "run")
      check exitCode == QuitSuccess
      check output.processOutput.inLines("resultfeature is enabled")

  test "should ignore features specified in `requires` when using the vmparser":
    cd "features":
      let (output, exitCode) = execNimble("--parser:nimvm", "run")
      check exitCode == QuitSuccess
      check output.processOutput.inLines("resultfeature is disabled")

  test "should activate transitive features specified in `requires`":
    cd "features-deps":
      removeDir("nimbledeps")
      let (output, exitCode) = execNimble("--parser:declarative", "--features:ver1", "run")      
      check exitCode == QuitSuccess
      check output.processOutput.inLines("Feature ver1 activated")      
      check output.processOutput.inLines("Feature1 activated")

  test "should not activate transitive features specified in `requires` when using a dependency that do not enable them":
    cd "features-deps":
      removeDir("nimbledeps")
      let (output, exitCode) = execNimble("--parser:declarative", "--features:ver2", "run")
      check exitCode == QuitSuccess
      check output.processOutput.inLines("Feature ver2 activated")
      check output.processOutput.inLines("Feature1 deactivated")

  test "should activate dev feature if the root package is a development package":
    cd "features":
      let (output, exitCode) = execNimble("--parser:declarative", "run")
      check exitCode == QuitSuccess
      check output.processOutput.inLines("dev is enabled")


  #[NEXT Tests:

    TODO:
    - compile time nimble parser detection so we can warn when using the vm parser with features

]#

echo ""