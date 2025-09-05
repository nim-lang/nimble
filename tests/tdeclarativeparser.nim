{.used.}
import unittest
import testscommon
import std/[options, tables, sequtils, os]
import
  nimblepkg/[packageinfotypes, version, options, config, nimblesat, declarativeparser, cli, common]

proc getNimbleFileFromPkgNameHelper(pkgName: string, ver = VersionRange(kind: verAny)): string =
  let pv: PkgTuple = (pkgName, ver)
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
  setup:
    removeDir("nimbleDir")

  test "should parse requires from a nimble file":
    let nimbleFile = getNimbleFileFromPkgNameHelper("nimlangserver")
    var options = initOptions()
    let nimbleFileInfo = extractRequiresInfo(nimbleFile, options)
    var activeFeatures = initTable[PkgTuple, seq[string]]()
    let requires = nimbleFileInfo.getRequires(activeFeatures)

    let expectedPkgs =
      @["nim", "json_rpc", "with", "chronicles", "serialization", "stew", "regex"]
    for pkg in expectedPkgs:
      check pkg in requires.mapIt(it[0])
  
  test "should detect nested requires and fail":
    # Create a test file with actual nested requires (not when defined)
    let testDir = "test_real_nested_requires"
    createDir(testDir)
    
    writeFile(testDir / "nested.nimble", """
version = "0.1.0"

requires "nim >= 1.6.0"

when someRuntimeCondition:
  requires "badlib"
""")
    
    var options = initOptions()
    let nimbleFileInfo = extractRequiresInfo(testDir / "nested.nimble", options)
    
    check nimbleFileInfo.nestedRequires
    
    # Clean up
    removeDir(testDir)

  test "should handle when defined() constructs and not mark as nested":
    let nimbleFile = getNimbleFileFromPkgNameHelper("jester") 
    var options = initOptions()
    let nimbleFileInfo = extractRequiresInfo(nimbleFile, options)
    
    # Should NOT be detected as nested requires since it uses when defined()
    check not nimbleFileInfo.nestedRequires
    check not nimbleFileInfo.hasErrors
    
    # Should have base requirement
    check "nim >= 1.0.0" in nimbleFileInfo.requires
    
    # Should have platform-specific requirement based on current platform
    when not defined(windows):
      check "httpbeast >= 0.4.0" in nimbleFileInfo.requires
    else:
      check "httpbeast >= 0.4.0" notin nimbleFileInfo.requires
  
  test "should parse bin from a nimble file":
    let nimbleFile = getNimbleFileFromPkgNameHelper("nimlangserver")
    var options = initOptions()
    let nimbleFileInfo = extractRequiresInfo(nimbleFile, options)
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
    options.localDeps = false
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
    let (output, exitCode) = execNimble("--parser:declarative", "install", "nimlangserver@#head")
    echo output
    check exitCode == QuitSuccess

  test "should be able to retrieve the nim info from a nim directory":
    let versions = @["1.6.12", "2.2.0"]
    for ver in versions:
      let nimbleFile = getNimbleFileFromPkgNameHelper("nim", parseVersionRange(ver))
      check extractNimVersion(nimbleFile) == ver

suite "Declarative parser features":
  test "should be able to parse features from a nimble file":
    let nimbleFile =  "./features/features.nimble"
    var options = initOptions()
    let nimbleFileInfo = extractRequiresInfo(nimbleFile, options)
    let features = nimbleFileInfo.features
    check features.len == 2 #we need to account for the default 'dev' feature
    check features["feature1"] == @["stew"]
    check nimbleFileInfo.requires == @["nim", "result[resultfeature]"]

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
      let (output, exitCode) = execNimble("--legacy", "run")
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

suite "Declarative parser requires file":
  
  test "should parse requires from a separate requires file":
    let testDir = "test_requires_file"
    createDir(testDir)
    
    # Create a simple nimble file
    writeFile(testDir / "test.nimble", """
version = "0.1.0"
author = "test"
description = "Test package"
license = "MIT"

requires "nim >= 1.6.0"
""")
    
    # Create a requires file with additional dependencies
    writeFile(testDir / "requires", """
# Additional requirements
stew
chronos >= 3.0.0

# Another requirement
json_rpc
""")
    
    var options = initOptions()
    let nimbleFileInfo = extractRequiresInfo(testDir / "test.nimble", options)
    
    # Should have requires from both nimble file and requires file
    check "nim >= 1.6.0" in nimbleFileInfo.requires
    check "stew" in nimbleFileInfo.requires
    check "chronos >= 3.0.0" in nimbleFileInfo.requires
    check "json_rpc" in nimbleFileInfo.requires
    
    # Clean up
    removeDir(testDir)

  test "should work without requires file":
    let testDir = "test_no_requires_file"
    createDir(testDir)
    
    # Create a simple nimble file without requires file
    writeFile(testDir / "test.nimble", """
version = "0.1.0"
author = "test"
description = "Test package"
license = "MIT"

requires "nim >= 1.6.0"
""")
    
    var options = initOptions()
    let nimbleFileInfo = extractRequiresInfo(testDir / "test.nimble", options)
    
    # Should only have requires from nimble file
    check "nim >= 1.6.0" in nimbleFileInfo.requires
    check nimbleFileInfo.requires.len == 1
    
    # Clean up
    removeDir(testDir)

  test "should ignore comments and empty lines in requires file":
    let testDir = "test_requires_comments"
    createDir(testDir)
    
    # Create a nimble file
    writeFile(testDir / "test.nimble", """
version = "0.1.0"
requires "nim"
""")
    
    # Create a requires file with comments and empty lines
    writeFile(testDir / "requires", """
# This is a comment
stew

# Another comment
chronos

# Empty line above and below


json_rpc
""")
    
    var options = initOptions()
    let nimbleFileInfo = extractRequiresInfo(testDir / "test.nimble", options)
    
    # Should only have actual requirements, not comments
    check "nim" in nimbleFileInfo.requires
    check "stew" in nimbleFileInfo.requires
    check "chronos" in nimbleFileInfo.requires
    check "json_rpc" in nimbleFileInfo.requires
    check nimbleFileInfo.requires.len == 4
    
    # Clean up
    removeDir(testDir)

suite "When defined() support":
  test "should parse when defined() conditions for current platform":
    let testDir = "test_when_defined"
    createDir(testDir)
    
    # Create a nimble file with when defined() blocks
    writeFile(testDir / "test.nimble", """
version = "0.1.0"
author = "test"
description = "Test package for when defined support"
license = "MIT"

requires "nim >= 1.6.0"

when defined(windows):
  requires "winapi"

when defined(linux):
  requires "linuxlib"

when defined(macosx):
  requires "macoslib"
""")
    
    var options = initOptions()
    let nimbleFileInfo = extractRequiresInfo(testDir / "test.nimble", options)
    
    # Should not treat when defined() as nested requires
    check not nimbleFileInfo.nestedRequires
    check not nimbleFileInfo.hasErrors
    
    # Should have base requirement
    check "nim >= 1.6.0" in nimbleFileInfo.requires
    
    # Should have platform-specific requirement based on current platform
    when defined(windows):
      check "winapi" in nimbleFileInfo.requires
      check "linuxlib" notin nimbleFileInfo.requires
      check "macoslib" notin nimbleFileInfo.requires
    elif defined(linux):
      check "linuxlib" in nimbleFileInfo.requires
      check "winapi" notin nimbleFileInfo.requires
      check "macoslib" notin nimbleFileInfo.requires
    elif defined(macosx):
      check "macoslib" in nimbleFileInfo.requires
      check "winapi" notin nimbleFileInfo.requires
      check "linuxlib" notin nimbleFileInfo.requires
    
    # Clean up
    removeDir(testDir)

  test "should handle complex when defined() expressions":
    let testDir = "test_when_complex"
    createDir(testDir)
    
    writeFile(testDir / "test.nimble", """
version = "0.1.0"

requires "nim >= 1.6.0"

when defined(windows) or defined(linux):
  requires "posixcompat"

when not defined(js):
  requires "nativelib"

when defined(windows) and defined(amd64):
  requires "winx64lib"
""")
    
    var options = initOptions()
    let nimbleFileInfo = extractRequiresInfo(testDir / "test.nimble", options)
    
    check not nimbleFileInfo.nestedRequires
    check not nimbleFileInfo.hasErrors
    check "nim >= 1.6.0" in nimbleFileInfo.requires
    
    # Check OR condition
    when defined(windows) or defined(linux):
      check "posixcompat" in nimbleFileInfo.requires
    else:
      check "posixcompat" notin nimbleFileInfo.requires
    
    # Check NOT condition
    when not defined(js):
      check "nativelib" in nimbleFileInfo.requires
    else:
      check "nativelib" notin nimbleFileInfo.requires
      
    # Check AND condition  
    when defined(windows) and defined(amd64):
      check "winx64lib" in nimbleFileInfo.requires
    else:
      check "winx64lib" notin nimbleFileInfo.requires
    
    # Clean up
    removeDir(testDir)

  test "should reject non-evaluable when conditions":
    let testDir = "test_when_invalid"
    createDir(testDir)
    
    writeFile(testDir / "test.nimble", """
version = "0.1.0"

requires "nim >= 1.6.0"

when someRuntimeCondition:
  requires "conditionallib"
""")
    
    var options = initOptions()
    let nimbleFileInfo = extractRequiresInfo(testDir / "test.nimble", options)
    
    # Should treat non-evaluable when as nested requires
    check nimbleFileInfo.nestedRequires
    
    # Clean up
    removeDir(testDir)

 