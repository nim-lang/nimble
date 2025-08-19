{.used.}
import unittest, os, sequtils, strutils
import testscommon
from nimblepkg/common import cd

suite "file path requires":
  test "can specify a dependency as a file path":
    removeDir "nimbleDir"
    cd "filepathrequires/mainfile":
      let (_, exitCode) = execNimble("run", "--requires: file://../depfile")
      check exitCode == QuitSuccess
    #Make sure the package wasnt installed
    let pkgCounts = walkDir("nimbleDir/pkgs2/").toSeq.len
    check pkgCounts == 0
        
  test "can specify a dependency as an absolute path":
    removeDir "nimbleDir"
    let depPath = getCurrentDir() / "filepathrequires" / "depfile"
    cd "filepathrequires/mainfile":
      let (_, exitCode) = execNimble("run", "--requires: file://" & depPath)
      check exitCode == QuitSuccess
    #Make sure the package wasnt installed
    let pkgCounts = walkDir("nimbleDir/pkgs2/").toSeq.len
    check pkgCounts == 0
    
  test "can specify a dependency with a space in the path":
    removeDir "nimbleDir"
    cd "filepathrequires/mainfile":
      let depPath = "../space folder/dep2file"
      let allReqs = @["file://" & depPath, "file://../depfile"] #we need to add depfile as the main package needs it
      let (_, exitCode) = execNimble("run","-d:withDep2", "--requires: " & allReqs.join("; "))
      check exitCode == QuitSuccess
    #Make sure the package wasnt installed
    let pkgCounts = walkDir("nimbleDir/pkgs2/").toSeq.len
    check pkgCounts == 0

  test "can specify transitive dependencies":
    removeDir "nimbleDir"
    cd "filepathrequires/mainfile":
      #dep3file already has a dependency on depfile
      let (_, exitCode) = execNimble("run", "--requires: file://../dep3file")
      check exitCode == QuitSuccess
    #Make sure the package wasnt installed
    let pkgCounts = walkDir("nimbleDir/pkgs2/").toSeq.len
    check pkgCounts == 0
    