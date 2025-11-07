{.used.}
import unittest, os, sequtils, strutils
import testscommon
import nimblepkg/[common, options, declarativeparser]
import nimble

suite "file path requires":
  test "can specify a dependency as a file path":
    removeDir "nimbleDir"
    cd "filepathrequires/mainfile":
      let (_, exitCode) = execNimble("run", "--requires: file://../depfile")
      check exitCode == QuitSuccess
    #Make sure the package wasnt installed
    let pkgCounts = walkDir("nimbleDir/pkgs2/").toSeq.len
    check pkgCounts == 1 #Depfile depends on results so it should be installed
        
  test "can specify a dependency as an absolute path":
    removeDir "nimbleDir"
    let depPath = getCurrentDir() / "filepathrequires" / "depfile"
    cd "filepathrequires/mainfile":
      let (_, exitCode) = execNimble("run", "--requires: file://" & depPath)
      check exitCode == QuitSuccess

  test "can specify a dependency with a space in the path":
    removeDir "nimbleDir"
    cd "filepathrequires/mainfile":
      let depPath = "../space folder/dep2file"
      let allReqs = @["file://" & depPath, "file://../depfile"] #we need to add depfile as the main package needs it
      let (_, exitCode) = execNimble("run","-d:withDep2", "--requires: " & allReqs.join("; "))
      check exitCode == QuitSuccess
 
  test "should override a version requirement": 
    #depfile depends on results 0.5.0
    #we are going to use our custom version results (0.5.1)
    removeDir "nimbleDir"
    cd "filepathrequires/mainfile":
      let (_, exitCode) = execNimble("run", "-d:withResults", "--requires: file://../depfile;file://../nim-results")
      check exitCode == QuitSuccess
    #Make sure the package wasnt installed
    let pkgCounts = walkDir("nimbleDir/pkgs2/").toSeq.len
    check pkgCounts == 0 #Should not install anything as depfile dep should be overridden by the custom version
    

  test "can add new deps to the new package":
    removeDir "nimbleDir"
    let depRequire = """requires "unittest2""""
    let resultsNimblePath = getCurrentDir() / "filepathrequires" / "nim-results"
    let resultsNimble = readFile(resultsNimblePath / "results.nimble")
    let resultsNimbleNew = resultsNimble & "\n" & depRequire
    writeFile(resultsNimblePath / "results.nimble", resultsNimbleNew)
    defer:
      writeFile(resultsNimblePath / "results.nimble", resultsNimble)

    cd "filepathrequires/mainfile":
      let (_, exitCode) = execNimble("run", "-d:withResults", "--requires: file://../depfile;file://../nim-results")
      check exitCode == QuitSuccess
    #Make sure the package wasnt installed
    let pkgCounts = walkDir("nimbleDir/pkgs2/").toSeq.len
    check pkgCounts == 1 #Should install the new dep on results

  test "can specify transitive dependencies": 
    removeDir "nimbleDir"
    cd "filepathrequires/mainfile":
      let (_, exitCode) = execNimble("run", "--requires: file://../dep3file")
      check exitCode == QuitSuccess
  
  test "traverse all filepaths packages upfront":
    var options = initOptions()
    options.isFilePathDiscovering = true
    cd "filepathrequires/dep3file":
      let entryPkg = getPkgInfoFromDirWithDeclarativeParser(getCurrentDir(), options, nimBin = "nim")
      loadFilePathPkgs(entryPkg, options, nimBin = "nim")
      check options.filePathPkgs.len == 2

  test "should not allow filepath requires in other deps if they werent openened through a filepath require":
    cd "filepathrequires/mainfile":
      let (_, exitCode) = execNimble("run", "--requires: file://../depfile;https://github.com/jmgomez/file_path_test")
      check exitCode != QuitSuccess

  test "should not allow filepath deps in a top level package that is not being in development":
    let (_, exitCode) = execNimble("install", "https://github.com/jmgomez/file_path_test")
    check exitCode != QuitSuccess

  test "should get requires from a requires file if it exists":
    cd "filepathrequires/mainfile":
      let requiresContent = "file://../depfile"
      writeFile("requires", requiresContent)
      defer: removeFile("requires")
      let (_, exitCode) = execNimble("run")
      check exitCode == QuitSuccess

