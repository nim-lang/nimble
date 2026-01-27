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
  let pkgInfo = downloadPkInfoForPv(pv, options, nimBin = "nim")
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
    let nimbleFile = getNimbleFileFromPkgNameHelper("jester")
    var options = initOptions()
    let nimbleFileInfo = extractRequiresInfo(nimbleFile, options)

    check nimbleFileInfo.nestedRequires
  
  
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
    let downloadRes = pv.downloadPkgFromUrl(options, nimBin = "nim")[0]
      #This is just to setup the test. We need a git dir to work on
    let repoDir = downloadRes.dir
    let downloadMethod = DownloadMethod git
    let packageVersions = getPackageMinimalVersionsFromRepo(
      repoDir, pv, downloadRes.version, downloadMethod, options, nimBin = "nim"
    )

    #we know these versions are available
    let availableVersions =
      @["0.3.4", "0.3.5", "0.3.6", "0.4.5", "0.4.4"].mapIt(newVersion(it))
    for version in availableVersions:
      check version in packageVersions.mapIt(it.version)

    check fileExists(options.pkgCachePath / TaggedVersionsFileName)

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

suite "isParsableByDeclarative":
  test "should return true for simple nimble content":
    let content = """
version = "0.1.0"
author = "test"
description = "Test package"
license = "MIT"

requires "nim >= 1.6.0"
requires "stew"
"""
    var options = initOptions()
    check isParsableByDeclarative(content, options) == true

  test "should return false for content with nested requires":
    let content = """
version = "0.1.0"
author = "test"

when defined(windows):
  requires "winapi"
else:
  requires "posix"
"""
    var options = initOptions()
    check isParsableByDeclarative(content, options) == false

  test "should return false for content with syntax errors":
    let content = """
version = "0.1.0"
author = "test"

requires "nim >= 1.6.0"
invalid syntax here!!!
"""
    var options = initOptions()
    check isParsableByDeclarative(content, options) == false

  test "should return true for content with tasks (no nested requires)":
    let content = """
version = "0.1.0"
author = "test"
description = "Test"
license = "MIT"

requires "nim"

task test, "Run tests":
  exec "nim c -r tests/test.nim"
"""
    var options = initOptions()
    check isParsableByDeclarative(content, options) == true

  test "should return false for content with if statements around requires":
    let content = """
version = "0.1.0"

if NimMajor >= 2:
  requires "nim >= 2.0.0"
else:
  requires "nim >= 1.6.0"
"""
    var options = initOptions()
    check isParsableByDeclarative(content, options) == false

suite "fileHasStateModifyingOps":
  test "should detect state ops in fixture with mkDir":
    check fileHasStateModifyingOps("buildInstall/pkgWithStateOps/pkgWithStateOps.nimble") == true

  test "should return false for simple library package":
    check fileHasStateModifyingOps("buildInstall/pkgNoBinary/pkgNoBinary.nimble") == false

suite "hasSideEffects":
  test "should return false for simple nimble file":
    let content = """
version = "0.1.0"
author = "test"
description = "Test"
license = "MIT"
requires "nim >= 1.6.0"
"""
    check contentHasStateModifyingOps(content) == false

  test "should detect exec at top level":
    let content = """
version = "0.1.0"
requires "nim"
exec "echo hello"
"""
    check contentHasStateModifyingOps(content) == true

  test "should detect createDir at top level":
    let content = """
version = "0.1.0"
requires "nim"
createDir "somedir"
"""
    check contentHasStateModifyingOps(content) == true

  test "should detect mkDir at top level":
    let content = """
version = "0.1.0"
mkDir "somedir"
"""
    check contentHasStateModifyingOps(content) == true

  test "should detect writeFile at top level":
    let content = """
version = "0.1.0"
writeFile "test.txt", "hello"
"""
    check contentHasStateModifyingOps(content) == true

  test "should detect cpFile at top level":
    let content = """
version = "0.1.0"
cpFile "a.txt", "b.txt"
"""
    check contentHasStateModifyingOps(content) == true

  test "should detect mvFile at top level":
    let content = """
version = "0.1.0"
mvFile "a.txt", "b.txt"
"""
    check contentHasStateModifyingOps(content) == true

  test "should detect rmFile at top level":
    let content = """
version = "0.1.0"
rmFile "a.txt"
"""
    check contentHasStateModifyingOps(content) == true

  test "should detect rmDir at top level":
    let content = """
version = "0.1.0"
rmDir "somedir"
"""
    check contentHasStateModifyingOps(content) == true

  test "should detect selfExec at top level":
    let content = """
version = "0.1.0"
selfExec "c test.nim"
"""
    check contentHasStateModifyingOps(content) == true

  test "should detect patchFile at top level":
    let content = """
version = "0.1.0"
patchFile "pkg", "file", "patch"
"""
    check contentHasStateModifyingOps(content) == true

  test "should NOT detect ops inside task blocks":
    let content = """
version = "0.1.0"
requires "nim"

task build, "Build":
  exec "nim c src/main.nim"
  mkDir "output"
"""
    check contentHasStateModifyingOps(content) == false

  test "should NOT detect ops inside before hook blocks":
    let content = """
version = "0.1.0"
requires "nim"

before install:
  exec "echo pre-install"
  mkDir "build"
"""
    check contentHasStateModifyingOps(content) == false

  test "should NOT detect ops inside after hook blocks":
    let content = """
version = "0.1.0"
requires "nim"

after install:
  exec "echo post-install"
  rmDir "temp"
"""
    check contentHasStateModifyingOps(content) == false

  test "should detect ops inside when blocks":
    let content = """
version = "0.1.0"
requires "nim"

when defined(linux):
  mkDir "linux_dir"
"""
    check contentHasStateModifyingOps(content) == true

  test "should detect ops inside if blocks":
    let content = """
version = "0.1.0"
requires "nim"

if NimMajor >= 2:
  exec "echo nim2"
"""
    check contentHasStateModifyingOps(content) == true

  test "should detect ops in else branch":
    let content = """
version = "0.1.0"

when defined(windows):
  discard
else:
  createDir "unix_dir"
"""
    check contentHasStateModifyingOps(content) == true

  test "should return false for file with only tasks and hooks":
    let content = """
version = "0.1.0"
author = "test"
description = "Test"
license = "MIT"
srcDir = "src"
bin = @["myapp"]
requires "nim >= 1.6.0"

task test, "Run tests":
  exec "nim c -r tests/test.nim"

before install:
  echo "preparing"

after install:
  echo "done"
"""
    check contentHasStateModifyingOps(content) == false

  test "should flag unknown calls as potentially having side effects":
    let content = """
version = "0.1.0"
requires "nim"
someUnknownProc "arg1", "arg2"
"""
    check contentHasStateModifyingOps(content) == true

  test "should return false for echo at top level":
    let content = """
version = "0.1.0"
requires "nim"
echo "hello"
"""
    check contentHasStateModifyingOps(content) == false

  test "should flag unknown calls inside when blocks":
    let content = """
version = "0.1.0"
when defined(linux):
  customSetup()
"""
    check contentHasStateModifyingOps(content) == true

  test "should return false for conditional requires":
    let content = """
version = "0.1.0"
when defined(windows):
  requires "winapi"
else:
  requires "posix"
"""
    check contentHasStateModifyingOps(content) == false

  test "should return false for old-style metadata calls":
    let content = """
version "0.1.0"
author "test"
description "A test package"
license "MIT"
srcDir "src"
bin "myapp"
skipDirs "tests"
installExt "nim"
foreignDep "openssl"
"""
    check contentHasStateModifyingOps(content) == false

  test "should return false for switch and taskrequires":
    let content = """
version = "0.1.0"
requires "nim"
switch "threads", "on"
taskrequires "docgen", "nimdoc >= 1.0"
"""
    check contentHasStateModifyingOps(content) == false

  test "should be case-insensitive for Requires":
    let content = """
version = "0.1.0"
Requires "nim >= 1.6.0"
"""
    check contentHasStateModifyingOps(content) == false
