# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

{.used.}

import unittest, os, strutils, strformat, json, sets
import testscommon, nimblepkg/displaymessages, nimblepkg/paths

from nimblepkg/common import cd
from nimblepkg/developfile import developFileName, pkgFoundMoreThanOnceMsg
from nimblepkg/version import newVersion, parseVersionRange
from nimblepkg/nimbledatafile import nimbleDataFileName, NimbleDataJsonKeys

suite "develop feature":
  const
    pkgListFileName = "packages.json"
    dependentPkgName = "dependent"
    dependentPkgVersion = "1.0"
    dependentPkgNameAndVersion = &"{dependentPkgName}@{dependentPkgVersion}"
    dependentPkgPath = "develop/dependent".normalizedPath
    includeFileName = "included.develop"
    pkgAName = "packagea"
    pkgBName = "packageb"
    pkgSrcDirTestName = "srcdirtest"
    pkgHybridName = "hybrid"
    depPath = "../dependency".normalizedPath
    depName = "dependency"
    depVersion = "0.1.0"
    depNameAndVersion = &"{depName}@{depVersion}"
    dep2Path = "../dependency2".normalizedPath
    emptyDevelopFileContent = developFile(@[], @[])
  
  let anyVersion = parseVersionRange("")

  test "can develop from dir with srcDir":
    cd &"develop/{pkgSrcDirTestName}":
      let (output, exitCode) = execNimble("develop")
      check exitCode == QuitSuccess
      let lines = output.processOutput
      check not lines.inLines("will not be compiled")
      check lines.inLines(pkgSetupInDevModeMsg(
        pkgSrcDirTestName, getCurrentDir()))

  test "can git clone for develop":
    cdCleanDir installDir:
      let (output, exitCode) = execNimble("develop", pkgAUrl)
      check exitCode == QuitSuccess
      check output.processOutput.inLines(
        pkgSetupInDevModeMsg(pkgAName, installDir / pkgAName))

  test "can develop from package name":
    cdCleanDir installDir:
      usePackageListFile &"../develop/{pkgListFileName}":
        let (output, exitCode) = execNimble("develop", pkgBName)
        check exitCode == QuitSuccess
        var lines = output.processOutput
        check lines.inLinesOrdered(pkgInstalledMsg(pkgAName))
        check lines.inLinesOrdered(
          pkgSetupInDevModeMsg(pkgBName, installDir / pkgBName))

  test "can develop list of packages":
    cdCleanDir installDir:
      usePackageListFile &"../develop/{pkgListFileName}":
        let (output, exitCode) = execNimble(
          "develop", pkgAName, pkgBName)
        check exitCode == QuitSuccess
        var lines = output.processOutput
        check lines.inLinesOrdered(pkgSetupInDevModeMsg(
          pkgAName, installDir / pkgAName))
        check lines.inLinesOrdered(pkgInstalledMsg(pkgAName))
        check lines.inLinesOrdered(pkgSetupInDevModeMsg(
          pkgBName, installDir / pkgBName))

  test "cannot remove package with develop reverse dependency":
    cdCleanDir installDir:
      usePackageListFile &"../develop/{pkgListFileName}":
        check execNimble("develop", pkgBName).exitCode == QuitSuccess
        let (output, exitCode) = execNimble("remove", pkgAName)
        check exitCode == QuitFailure
        var lines = output.processOutput
        check lines.inLinesOrdered(
          cannotUninstallPkgMsg(pkgAName, newVersion("0.2.0"),
          @[installDir / pkgBName]))

  test "can reject binary packages":
    cd "develop/binary":
      let (output, exitCode) = execNimble("develop")
      check output.processOutput.inLines("cannot develop packages")
      check exitCode == QuitFailure

  test "can develop hybrid":
    cd &"develop/{pkgHybridName}":
      let (output, exitCode) = execNimble("develop")
      check exitCode == QuitSuccess
      var lines = output.processOutput
      check lines.inLinesOrdered("will not be compiled")
      check lines.inLinesOrdered(
        pkgSetupInDevModeMsg(pkgHybridName, getCurrentDir()))

  test "can specify different absolute clone dir":
    let otherDir = installDir / "./some/other/dir"
    cleanDir otherDir
    let (output, exitCode) = execNimble(
      "develop", &"-p:{otherDir}", pkgAUrl)
    check exitCode == QuitSuccess
    check output.processOutput.inLines(
      pkgSetupInDevModeMsg(pkgAName, otherDir / pkgAName))

  test "can specify different relative clone dir":
    const otherDir = "./some/other/dir"
    cdCleanDir installDir:
      let (output, exitCode) = execNimble(
        "develop", &"-p:{otherDir}", pkgAUrl)
      check exitCode == QuitSuccess
      check output.processOutput.inLines(
        pkgSetupInDevModeMsg(pkgAName, installDir / otherDir / pkgAName))

  test "do not allow multiple path options":
    let
      developDir = installDir / "./some/dir"
      anotherDevelopDir = installDir / "./some/other/dir"
    defer:
      # cleanup in the case of test failure
      removeDir developDir
      removeDir anotherDevelopDir
    let (output, exitCode) = execNimble(
      "develop", &"-p:{developDir}", &"-p:{anotherDevelopDir}", pkgAUrl)
    check exitCode == QuitFailure
    check output.processOutput.inLines("Multiple path options are given")
    check not developDir.dirExists
    check not anotherDevelopDir.dirExists

  test "do not allow path option without packages to download":
    let developDir = installDir / "./some/dir"
    let (output, exitCode) = execNimble("develop", &"-p:{developDir}")
    check exitCode == QuitFailure
    check output.processOutput.inLines(pathGivenButNoPkgsToDownloadMsg)
    check not developDir.dirExists

  test "do not allow add/remove options out of package directory":
    cleanFile developFileName
    let (output, exitCode) = execNimble("develop", "-a:./develop/dependency/")
    check exitCode == QuitFailure
    check output.processOutput.inLines(developOptionsOutOfPkgDirectoryMsg)

  test "cannot load invalid develop file":
    cd dependentPkgPath:
      cleanFile developFileName
      writeFile(developFileName, "this is not a develop file")
      let (output, exitCode) = execNimble("check")
      check exitCode == QuitFailure
      var lines = output.processOutput
      check lines.inLinesOrdered(
        notAValidDevFileJsonMsg(getCurrentDir() / developFileName))
      check lines.inLinesOrdered(validationFailedMsg)

  test "add downloaded package to the develop file":
    cleanDir installDir
    cd "develop/dependency":
      usePackageListFile &"../{pkgListFileName}":
        cleanFile developFileName
        let
          (output, exitCode) = execNimble(
            "develop", &"-p:{installDir}", pkgAName)
          pkgAAbsPath = installDir / pkgAName
          developFileContent = developFile(@[], @[pkgAAbsPath])
        check exitCode == QuitSuccess
        check parseFile(developFileName) == parseJson(developFileContent)
        var lines = output.processOutput
        check lines.inLinesOrdered(pkgSetupInDevModeMsg(pkgAName, pkgAAbsPath))
        check lines.inLinesOrdered(
          pkgAddedInDevModeMsg(&"{pkgAName}@0.6.0", pkgAAbsPath))

  test "cannot add not a dependency downloaded package to the develop file":
    cleanDir installDir
    cd "develop/dependency":
      usePackageListFile &"../{pkgListFileName}":
        cleanFile developFileName
        let
          (output, exitCode) = execNimble(
            "develop", &"-p:{installDir}", pkgAName, pkgBName)
          pkgAAbsPath = installDir / pkgAName
          pkgBAbsPath = installDir / pkgBName
          developFileContent = developFile(@[], @[pkgAAbsPath])
        check exitCode == QuitFailure
        check parseFile(developFileName) == parseJson(developFileContent)
        var lines = output.processOutput
        check lines.inLinesOrdered(pkgSetupInDevModeMsg(pkgAName, pkgAAbsPath))
        check lines.inLinesOrdered(pkgSetupInDevModeMsg(pkgBName, pkgBAbsPath))
        check lines.inLinesOrdered(
          pkgAddedInDevModeMsg(&"{pkgAName}@0.6.0", pkgAAbsPath))
        check lines.inLinesOrdered(
          notADependencyErrorMsg(&"{pkgBName}@0.2.0", depNameAndVersion))

  test "add package to develop file":
    cleanDir installDir
    cd dependentPkgPath:
      usePackageListFile &"../{pkgListFileName}":
        cleanFiles developFileName, dependentPkgName.addFileExt(ExeExt)
        var (output, exitCode) = execNimble("develop", &"-a:{depPath}")
        check exitCode == QuitSuccess
        check developFileName.fileExists
        check output.processOutput.inLines(
          pkgAddedInDevModeMsg(depNameAndVersion, depPath))
        const expectedDevelopFile = developFile(@[], @[depPath])
        check parseFile(developFileName) == parseJson(expectedDevelopFile)
        (output, exitCode) = execNimble("run")
        check exitCode == QuitSuccess
        check output.processOutput.inLines(pkgInstalledMsg(pkgAName))

  test "warning on attempt to add the same package twice":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      let (output, exitCode) = execNimble("develop", &"-a:{depPath}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(
        pkgAlreadyInDevModeMsg(depNameAndVersion, depPath))
      check parseFile(developFileName) ==  parseJson(developFileContent)

  test "cannot add invalid package to develop file":
    cd dependentPkgPath:
      cleanFile developFileName
      const invalidPkgDir = "../invalidPkg".normalizedPath
      createTempDir invalidPkgDir
      let (output, exitCode) = execNimble("develop", &"-a:{invalidPkgDir}")
      check exitCode == QuitFailure
      check output.processOutput.inLines(invalidPkgMsg(invalidPkgDir))
      check not developFileName.fileExists

  test "cannot add not a dependency to develop file":
    cd dependentPkgPath:
      cleanFile developFileName
      let (output, exitCode) = execNimble("develop", "-a:../srcdirtest/")
      check exitCode == QuitFailure
      check output.processOutput.inLines(
        notADependencyErrorMsg(&"{pkgSrcDirTestName}@1.0", "dependent@1.0"))
      check not developFileName.fileExists

  test "cannot add two packages with the same name to develop file":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      let (output, exitCode) = execNimble("develop", &"-a:{dep2Path}")
      check exitCode == QuitFailure
      check output.processOutput.inLines(
        pkgAlreadyPresentAtDifferentPathMsg(depName, depPath.absolutePath))
      check parseFile(developFileName) == parseJson(developFileContent)

  test "found two packages with the same name in the develop file":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(
        @[], @[depPath, dep2Path])
      writeFile(developFileName, developFileContent)

      let
        (output, exitCode) = execNimble("check")
        developFilePath = getCurrentDir() / developFileName

      check exitCode == QuitFailure
      var lines = output.processOutput
      check lines.inLinesOrdered(failedToLoadFileMsg(developFilePath))
      check lines.inLinesOrdered(pkgFoundMoreThanOnceMsg(depName,
        [(depPath.absolutePath.Path, developFilePath.Path), 
         (dep2Path.absolutePath.Path, developFilePath.Path)].toHashSet))
      check lines.inLinesOrdered(validationFailedMsg)

  test "remove package from develop file by path":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      let (output, exitCode) = execNimble("develop", &"-r:{depPath}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(
        pkgRemovedFromDevModeMsg(depNameAndVersion, depPath))
      check parseFile(developFileName) == parseJson(emptyDevelopFileContent)

  test "warning on attempt to remove not existing package path":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      let (output, exitCode) = execNimble("develop", &"-r:{dep2Path}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(pkgPathNotInDevFileMsg(dep2Path))
      check parseFile(developFileName) == parseJson(developFileContent)

  test "remove package from develop file by name":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      let (output, exitCode) = execNimble("develop", &"-n:{depName}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(
        pkgRemovedFromDevModeMsg(depNameAndVersion, depPath.absolutePath))
      check parseFile(developFileName) == parseJson(emptyDevelopFileContent)

  test "warning on attempt to remove not existing package name":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      const notExistingPkgName = "dependency2"
      let (output, exitCode) = execNimble("develop", &"-n:{notExistingPkgName}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(
        pkgNameNotInDevFileMsg(notExistingPkgName))
      check parseFile(developFileName) == parseJson(developFileContent)

  test "include develop file":
    cleanDir installDir
    cd dependentPkgPath:
      usePackageListFile &"../{pkgListFileName}":
        cleanFiles developFileName, includeFileName,
                   dependentPkgName.addFileExt(ExeExt)
        const includeFileContent = developFile(@[], @[depPath])
        writeFile(includeFileName, includeFileContent)
        var (output, exitCode) = execNimble("develop", &"-i:{includeFileName}")
        check exitCode == QuitSuccess
        check developFileName.fileExists
        check output.processOutput.inLines(inclInDevFileMsg(includeFileName))
        const expectedDevelopFile = developFile(@[includeFileName], @[])
        check parseFile(developFileName) == parseJson(expectedDevelopFile)
        (output, exitCode) = execNimble("run")
        check exitCode == QuitSuccess
        check output.processOutput.inLines(pkgInstalledMsg(pkgAName))

  test "warning on attempt to include already included develop file":
    cd dependentPkgPath:
      cleanFiles developFileName, includeFileName
      const developFileContent = developFile(@[includeFileName], @[])
      writeFile(developFileName, developFileContent)
      const includeFileContent = developFile(@[], @[depPath])
      writeFile(includeFileName, includeFileContent)

      let (output, exitCode) = execNimble("develop", &"-i:{includeFileName}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(
        alreadyInclInDevFileMsg(includeFileName))
      check parseFile(developFileName) == parseJson(developFileContent)

  test "cannot include invalid develop file":
    cd dependentPkgPath:
      cleanFiles developFileName, includeFileName
      writeFile(includeFileName, """{"some": "json"}""")
      let (output, exitCode) = execNimble("develop", &"-i:{includeFileName}")
      check exitCode == QuitFailure
      check not developFileName.fileExists
      check output.processOutput.inLines(failedToLoadFileMsg(includeFileName))

  test "cannot load a develop file with an invalid include file in it":
    cd dependentPkgPath:
      cleanFiles developFileName, includeFileName
      const developFileContent = developFile(@[includeFileName], @[])
      writeFile(developFileName, developFileContent)
      let (output, exitCode) = execNimble("check")
      check exitCode == QuitFailure
      let developFilePath = getCurrentDir() / developFileName
      var lines = output.processOutput()
      check lines.inLinesOrdered(failedToLoadFileMsg(developFilePath))
      check lines.inLinesOrdered(invalidDevFileMsg(developFilePath))
      check lines.inLinesOrdered(&"cannot read from file: {includeFileName}")
      check lines.inLinesOrdered(validationFailedMsg)

  test "can include file pointing to the same package":
    cleanDir installDir
    cd dependentPkgPath:
      usePackageListFile &"../{pkgListFileName}":
        cleanFiles developFileName, includeFileName,
                   dependentPkgName.addFileExt(ExeExt)
        const fileContent = developFile(@[], @[depPath])
        writeFile(developFileName, fileContent)
        writeFile(includeFileName, fileContent)
        var (output, exitCode) = execNimble("develop", &"-i:{includeFileName}")
        check exitCode == QuitSuccess
        check output.processOutput.inLines(inclInDevFileMsg(includeFileName))
        const expectedFileContent = developFile(
          @[includeFileName], @[depPath])
        check parseFile(developFileName) == parseJson(expectedFileContent)
        (output, exitCode) = execNimble("run")
        check exitCode == QuitSuccess
        check output.processOutput.inLines(pkgInstalledMsg(pkgAName))

  test "cannot include conflicting develop file":
    cd dependentPkgPath:
      cleanFiles developFileName, includeFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      const includeFileContent = developFile(@[], @[dep2Path])
      writeFile(includeFileName, includeFileContent)

      let
        (output, exitCode) = execNimble("develop", &"-i:{includeFileName}")
        developFilePath = getCurrentDir() / developFileName

      check exitCode == QuitFailure
      var lines = output.processOutput
      check lines.inLinesOrdered(
        failedToInclInDevFileMsg(includeFileName, developFilePath))
      check lines.inLinesOrdered(pkgFoundMoreThanOnceMsg(depName,
        [(depPath.absolutePath.Path, developFilePath.Path),
         (dep2Path.Path, includeFileName.Path)].toHashSet))
      check parseFile(developFileName) == parseJson(developFileContent)

  test "validate included dependencies version":
    cd &"{dependentPkgPath}2":
      cleanFiles developFileName, includeFileName
      const includeFileContent = developFile(@[], @[dep2Path])
      writeFile(includeFileName, includeFileContent)
      let (output, exitCode) = execNimble("develop", &"-i:{includeFileName}")
      check exitCode == QuitFailure
      var lines = output.processOutput
      let developFilePath = getCurrentDir() / developFileName
      check lines.inLinesOrdered(
        failedToInclInDevFileMsg(includeFileName, developFilePath))
      check lines.inLinesOrdered(invalidPkgMsg(dep2Path))
      check lines.inLinesOrdered(dependencyNotInRangeErrorMsg(
        depNameAndVersion, dependentPkgNameAndVersion,
        parseVersionRange(">= 0.2.0")))
      check not developFileName.fileExists

  test "exclude develop file":
    cd dependentPkgPath:
      cleanFiles developFileName, includeFileName
      const developFileContent = developFile(@[includeFileName], @[])
      writeFile(developFileName, developFileContent)
      const includeFileContent = developFile(@[], @[depPath])
      writeFile(includeFileName, includeFileContent)
      let (output, exitCode) = execNimble("develop", &"-e:{includeFileName}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(exclFromDevFileMsg(includeFileName))
      check parseFile(developFileName) == parseJson(emptyDevelopFileContent)

  test "warning on attempt to exclude not included develop file":
    cd dependentPkgPath:
      cleanFiles developFileName, includeFileName
      const developFileContent = developFile(@[includeFileName], @[])
      writeFile(developFileName, developFileContent)
      const includeFileContent = developFile(@[], @[depPath])
      writeFile(includeFileName, includeFileContent)
      let (output, exitCode) = execNimble("develop", &"-e:../{includeFileName}")
      check exitCode == QuitSuccess
      check output.processOutput.inLines(
        notInclInDevFileMsg((&"../{includeFileName}").normalizedPath))
      check parseFile(developFileName) == parseJson(developFileContent)

  test "relative paths in the develop file and absolute from the command line":
    cd dependentPkgPath:
      cleanFiles developFileName, includeFileName
      const developFileContent = developFile(
        @[includeFileName], @[depPath])
      writeFile(developFileName, developFileContent)
      const includeFileContent = developFile(@[], @[depPath])
      writeFile(includeFileName, includeFileContent)

      let
        includeFileAbsolutePath = includeFileName.absolutePath
        dependencyPkgAbsolutePath = "../dependency".absolutePath
        (output, exitCode) = execNimble("develop",
          &"-e:{includeFileAbsolutePath}", &"-r:{dependencyPkgAbsolutePath}")

      check exitCode == QuitSuccess
      var lines = output.processOutput
      check lines.inLinesOrdered(exclFromDevFileMsg(includeFileAbsolutePath))
      check lines.inLinesOrdered(
        pkgRemovedFromDevModeMsg(depNameAndVersion, dependencyPkgAbsolutePath))
      check parseFile(developFileName) == parseJson(emptyDevelopFileContent)

  test "absolute paths in the develop file and relative from the command line":
    cd dependentPkgPath:
      let
        currentDir = getCurrentDir()
        includeFileAbsPath = currentDir / includeFileName
        dependencyAbsPath = currentDir / depPath
        developFileContent = developFile(
          @[includeFileAbsPath], @[dependencyAbsPath])
        includeFileContent = developFile(@[], @[depPath])

      cleanFiles developFileName, includeFileName
      writeFile(developFileName, developFileContent)
      writeFile(includeFileName, includeFileContent)

      let (output, exitCode) = execNimble("develop",
        &"-e:{includeFileName}", &"-r:{depPath}")

      check exitCode == QuitSuccess
      var lines = output.processOutput
      check lines.inLinesOrdered(exclFromDevFileMsg(includeFileName))
      check lines.inLinesOrdered(
        pkgRemovedFromDevModeMsg(depNameAndVersion, depPath))
      check parseFile(developFileName) == parseJson(emptyDevelopFileContent)

  test "uninstall package with develop reverse dependencies":
    cleanDir installDir
    cd dependentPkgPath:
      usePackageListFile &"../{pkgListFileName}":
        const developFileContent = developFile(@[], @[depPath])
        cleanFiles developFileName, "dependent"
        writeFile(developFileName, developFileContent)

        block checkSuccessfulInstallAndReverseDependencyAddedToNimbleData:
          let
            (_, exitCode) = execNimble("install")
            nimbleData = parseFile(installDir / nimbleDataFileName)
            packageDir = getPackageDir(pkgsDir, "PackageA-0.5.0")
            checksum = packageDir[packageDir.rfind('-') + 1 .. ^1]
            devRevDepPath = nimbleData{$ndjkRevDep}{pkgAName}{"0.5.0"}{
              checksum}{0}{$ndjkRevDepPath}
            depAbsPath = getCurrentDir() / depPath

          check exitCode == QuitSuccess
          check not devRevDepPath.isNil
          check devRevDepPath.str == depAbsPath

        block checkSuccessfulUninstallAndRemovalFromNimbleData:
          let
            (_, exitCode) = execNimble("uninstall", "-i", pkgAName, "-y")
            nimbleData = parseFile(installDir / nimbleDataFileName)

          check exitCode == QuitSuccess
          check not nimbleData[$ndjkRevDep].hasKey(pkgAName)

  test "follow develop dependency's develop file":
    cd "develop":
      const pkg1DevFilePath = "pkg1" / developFileName
      const pkg2DevFilePath = "pkg2" / developFileName
      cleanFiles pkg1DevFilePath, pkg2DevFilePath
      const pkg1DevFileContent = developFile(@[], @["../pkg2"])
      writeFile(pkg1DevFilePath, pkg1DevFileContent)
      const pkg2DevFileContent = developFile(@[], @["../pkg3"])
      writeFile(pkg2DevFilePath, pkg2DevFileContent)
      cd "pkg1":
        cleanFile "pkg1".addFileExt(ExeExt)
        let (_, exitCode) = execNimble("run", "-n")
        check exitCode == QuitSuccess

  test "version clash from followed develop file":
    cd "develop":
      const pkg1DevFilePath = "pkg1" / developFileName
      const pkg2DevFilePath = "pkg2" / developFileName
      cleanFiles pkg1DevFilePath, pkg2DevFilePath
      const pkg1DevFileContent = developFile(@[], @["../pkg2", "../pkg3"])
      writeFile(pkg1DevFilePath, pkg1DevFileContent)
      const pkg2DevFileContent = developFile(@[], @["../pkg3.2"])
      writeFile(pkg2DevFilePath, pkg2DevFileContent)

      let
        currentDir = getCurrentDir()
        pkg1DevFileAbsPath = currentDir / pkg1DevFilePath
        pkg2DevFileAbsPath = currentDir / pkg2DevFilePath
        pkg3AbsPath = currentDir / "pkg3"
        pkg32AbsPath = currentDir / "pkg3.2"

      cd "pkg1":
        cleanFile "pkg1".addFileExt(ExeExt)
        let (output, exitCode) = execNimble("run", "-n")
        check exitCode == QuitFailure
        var lines = output.processOutput
        check lines.inLinesOrdered(failedToLoadFileMsg(pkg1DevFileAbsPath))
        check lines.inLinesOrdered(pkgFoundMoreThanOnceMsg("pkg3",
          [(pkg3AbsPath.Path, pkg1DevFileAbsPath.Path),
           (pkg32AbsPath.Path, pkg2DevFileAbsPath.Path)].toHashSet))

  test "relative include paths are followed from the file's directory":
    cd dependentPkgPath:
      const includeFilePath = &"../{includeFileName}"
      cleanFiles includeFilePath, developFileName, dependentPkgName.addFileExt(ExeExt)
      const developFileContent = developFile(@[includeFilePath], @[])
      writeFile(developFileName, developFileContent)
      const includeFileContent = developFile(@[], @["./dependency2/"])
      writeFile(includeFilePath, includeFileContent)
      let (_, errorCode) = execNimble("run", "-n")
      check errorCode == QuitSuccess

  test "filter not used included develop dependencies":
    # +--------------------------+                +--------------------------+
    # |           pkg1           |  +------------>|           pkg2           |
    # +--------------------------+  | dependency  +--------------------------+
    # | requires "pkg2", "pkg3"  |  |             |      nimble.develop      |
    # +--------------------------+  |             +--------------------------+
    # |      nimble.develop      |--+                           |
    # +--------------------------+                     includes |
    #                                                           v
    #                                                   +---------------+
    #                                                   | develop.json  |
    #                                                   +---------------+
    #                                                           |
    #                                                dependency |
    #                                                           v
    #                                                +---------------------+
    #                                                |         pkg3        |
    #                                                +---------------------+
    #                                                |  version = "0.2.0"  |
    #                                                +---------------------+

    # Here the build must fail because "pkg3" coming from develop file included
    # in "pkg2"'s develop file is not a dependency of "pkg2" itself and it must
    # be filtered. In this way "pkg1"'s dependency to "pkg3" is not satisfied.

    cd "develop":
      const
        pkg1DevFilePath = "pkg1" / developFileName
        pkg2DevFilePath = "pkg2.2" / developFileName
        freeDevFileName = "develop.json"
        pkg1DevFileContent = developFile(@[], @["../pkg2.2"])
        pkg2DevFileContent = developFile(@[&"../{freeDevFileName}"], @[])
        freeDevFileContent = developFile(@[], @["./pkg3.2"])

      cleanFiles pkg1DevFilePath, pkg2DevFilePath, freeDevFileName
      writeFile(pkg1DevFilePath, pkg1DevFileContent)
      writeFile(pkg2DevFilePath, pkg2DevFileContent)
      writeFile(freeDevFileName, freeDevFileContent)

      cd "pkg1":
        cleanFile "pkg1".addFileExt(ExeExt)
        let (output, exitCode) = execNimble("run", "-n")
        check exitCode == QuitFailure
        var lines = output.processOutput
        check lines.inLinesOrdered(
          pkgDepsAlreadySatisfiedMsg(("pkg2", anyVersion)))
        check lines.inLinesOrdered(pkgNotFoundMsg(("pkg3", anyVersion)))

  test "do not filter used included develop dependencies":
    # +--------------------------+                +--------------------------+
    # |           pkg1           |  +------------>+           pkg2           |
    # +--------------------------+  | dependency  +--------------------------+
    # | requires "pkg2", "pkg3"  |  |             | requires "pkg3"          |
    # +--------------------------+  |             +--------------------------+
    # |      nimble.develop      |--+             |      nimble.develop      |
    # +--------------------------+                +--------------------------+
    #                                                          |
    #                                                 includes |
    #                                                          v
    #                                                  +---------------+
    #                                                  | develop.json  |
    #                                                  +---------------+
    #                                                          |
    #                                               dependency |
    #                                                          v
    #                                                +---------------------+
    #                                                |        pkg3         |
    #                                                +---------------------+
    #                                                |  version = "0.2.0"  |
    #                                                +---------------------+

    # Here the build must pass because "pkg3" coming form develop file included
    # in "pkg2"'s develop file is a dependency of "pkg2" and it will be used,
    # in this way satisfying also "pkg1"'s requirements.

    cd "develop":
      const
        pkg1DevFilePath = "pkg1" / developFileName
        pkg2DevFilePath = "pkg2" / developFileName
        freeDevFileName = "develop.json"
        pkg1DevFileContent = developFile(@[], @["../pkg2"])
        pkg2DevFileContent = developFile(@[&"../{freeDevFileName}"], @[])
        freeDevFileContent = developFile(@[], @["./pkg3.2"])

      cleanFiles pkg1DevFilePath, pkg2DevFilePath, freeDevFileName
      writeFile(pkg1DevFilePath, pkg1DevFileContent)
      writeFile(pkg2DevFilePath, pkg2DevFileContent)
      writeFile(freeDevFileName, freeDevFileContent)

      cd "pkg1":
        cleanFile "pkg1".addFileExt(ExeExt)
        let (output, exitCode) = execNimble("run", "-n")
        check exitCode == QuitSuccess
        var lines = output.processOutput
        check lines.inLinesOrdered(
          pkgDepsAlreadySatisfiedMsg(("pkg2", anyVersion)))
        check lines.inLinesOrdered(
          pkgDepsAlreadySatisfiedMsg(("pkg3", anyVersion)))
        check lines.inLinesOrdered(
          pkgDepsAlreadySatisfiedMsg(("pkg3", anyVersion)))

  test "no version clash with filtered not used included develop dependencies":
    # +--------------------------+                +--------------------------+
    # |           pkg1           |  +------------>|           pkg2           |
    # +--------------------------+  | dependency  +--------------------------+
    # | requires "pkg2", "pkg3"  |  |             |      nimble.develop      |
    # +--------------------------+  |             +--------------------------+
    # |      nimble.develop      |--+                           |
    # +--------------------------+                     includes |
    #             |                                             v
    #    includes |                                     +---------------+
    #             v                                     | develop2.json |
    #     +---------------+                             +-------+-------+
    #     | develop1.json |                                     |
    #     +---------------+                          dependency |
    #             |                                             v
    #  dependency |                                  +---------------------+
    #             v                                  |        pkg3         |
    #   +-------------------+                        +---------------------+
    #   |       pkg3        |                        |  version = "0.2.0"  |
    #   +-------------------+                        +---------------------+
    #   | version = "0.1.0" |
    #   +-------------------+

    # Here the build must pass because only the version of "pkg3" included via
    # "develop1.json" must be taken into account, since "pkg2" does not depend
    # on "pkg3" and the version coming from "develop2.json" must be filtered.

    cd "develop":
      const
        pkg1DevFilePath = "pkg1" / developFileName
        pkg2DevFilePath = "pkg2.2" / developFileName
        freeDevFile1Name = "develop1.json"
        freeDevFile2Name = "develop2.json"
        pkg1DevFileContent = developFile(
          @[&"../{freeDevFile1Name}"], @["../pkg2.2"])
        pkg2DevFileContent = developFile(@[&"../{freeDevFile2Name}"], @[])
        freeDevFile1Content = developFile(@[], @["./pkg3"])
        freeDevFile2Content = developFile(@[], @["./pkg3.2"])

      cleanFiles pkg1DevFilePath, pkg2DevFilePath,
                 freeDevFile1Name, freeDevFile2Name
      writeFile(pkg1DevFilePath, pkg1DevFileContent)
      writeFile(pkg2DevFilePath, pkg2DevFileContent)
      writeFile(freeDevFile1Name, freeDevFile1Content)
      writeFile(freeDevFile2Name, freeDevFile2Content)

      cd "pkg1":
        cleanFile "pkg1".addFileExt(ExeExt)
        let (output, exitCode) = execNimble("run", "-n")
        check exitCode == QuitSuccess
        var lines = output.processOutput
        check lines.inLinesOrdered(
          pkgDepsAlreadySatisfiedMsg(("pkg2", anyVersion)))
        check lines.inLinesOrdered(
          pkgDepsAlreadySatisfiedMsg(("pkg3", anyVersion)))

  test "version clash with used included develop dependencies":
    # +--------------------------+                +--------------------------+
    # |           pkg1           |  +------------>|           pkg2           |
    # +--------------------------+  | dependency  +--------------------------+
    # | requires "pkg2", "pkg3"  |  |             | requires "pkg3"          |
    # +--------------------------+  |             +--------------------------+
    # |      nimble.develop      |--+             |      nimble.develop      |
    # +--------------------------+                +--------------------------+
    #             |                                             |
    #    includes |                                    includes |
    #             v                                             v
    #     +-------+-------+                             +---------------+
    #     | develop1.json |                             | develop2.json |
    #     +-------+-------+                             +---------------+
    #             |                                             |
    #  dependency |                                  dependency |
    #             v                                             v
    #   +-------------------+                        +---------------------+
    #   |       pkg3        |                        |         pkg3        |
    #   +-------------------+                        +---------------------+
    #   | version = "0.1.0" |                        |  version = "0.2.0"  |
    #   +-------------------+                        +---------------------+

    # Here the build must fail because since "pkg3" is dependency of both "pkg1"
    # and "pkg2", both versions coming from "develop1.json" and "develop2.json"
    # must be taken into account, but they are different."
    
    cd "develop":
      const
        pkg1DevFilePath = "pkg1" / developFileName
        pkg2DevFilePath = "pkg2" / developFileName
        freeDevFile1Name = "develop1.json"
        freeDevFile2Name = "develop2.json"
        pkg1DevFileContent = developFile(
          @[&"../{freeDevFile1Name}"], @["../pkg2"])
        pkg2DevFileContent = developFile(@[&"../{freeDevFile2Name}"], @[])
        freeDevFile1Content = developFile(@[], @["./pkg3"])
        freeDevFile2Content = developFile(@[], @["./pkg3.2"])

      cleanFiles pkg1DevFilePath, pkg2DevFilePath,
                 freeDevFile1Name, freeDevFile2Name
      writeFile(pkg1DevFilePath, pkg1DevFileContent)
      writeFile(pkg2DevFilePath, pkg2DevFileContent)
      writeFile(freeDevFile1Name, freeDevFile1Content)
      writeFile(freeDevFile2Name, freeDevFile2Content)

      cd "pkg1":
        cleanFile "pkg1".addFileExt(ExeExt)
        let (output, exitCode) = execNimble("run", "-n")
        check exitCode == QuitFailure
        var lines = output.processOutput
        check lines.inLinesOrdered(failedToLoadFileMsg(
          getCurrentDir() / developFileName))

        let
          pkg3Path = (".." / "pkg3").Path
          pkg32Path = (".." / "pkg3.2").Path
          freeDevFile1Path = (".." / freeDevFile1Name).Path
          freeDevFile2Path = (".." / freeDevFile2Name).Path

        check lines.inLinesOrdered(pkgFoundMoreThanOnceMsg("pkg3",
          [(pkg3Path, freeDevFile1Path),
           (pkg32Path, freeDevFile2Path)].toHashSet))

  test "create an empty develop file with default name in the current dir":
    cd dependentPkgPath:
      cleanFile developFileName
      let (output, errorCode) = execNimble("develop", "-c")
      check errorCode == QuitSuccess
      check parseFile(developFileName) == parseJson(emptyDevelopFileContent)
      check output.processOutput.inLines(
        emptyDevFileCreatedMsg(developFileName))

  test "create an empty develop file in some dir":
    cleanDir installDir
    let filePath = installDir / "develop.json"
    cleanFile filePath
    createDir installDir
    let (output, errorCode) = execNimble("develop", &"-c:{filePath}")
    check errorCode == QuitSuccess
    check parseFile(filePath) == parseJson(emptyDevelopFileContent)
    check output.processOutput.inLines(emptyDevFileCreatedMsg(filePath))

  test "try to create an empty develop file with already existing name":
    cd dependentPkgPath:
      cleanFile developFileName
      const developFileContent = developFile(@[], @[depPath])
      writeFile(developFileName, developFileContent)
      let
        filePath = getCurrentDir() / developFileName
        (output, errorCode) = execNimble("develop", &"-c:{filePath}")
      check errorCode == QuitFailure
      check output.processOutput.inLines(fileAlreadyExistsMsg(filePath))
      check parseFile(developFileName) == parseJson(developFileContent)

  test "try to create an empty develop file in not existing dir":
    let filePath = installDir / "some/not/existing/dir/develop.json"
    cleanFile filePath
    let (output, errorCode) = execNimble("develop", &"-c:{filePath}")
    check errorCode == QuitFailure
    check output.processOutput.inLines(&"cannot open: {filePath}")

  test "partial success when some operations in single command failed":
    cleanDir installDir
    cd dependentPkgPath:
      usePackageListFile &"../{pkgListFileName}":
        const
          dep2DevelopFilePath = dep2Path / developFileName
          includeFileContent = developFile(@[], @[dep2Path])
          invalidInclFilePath = "/some/not/existing/file/path".normalizedPath

        cleanFiles developFileName, includeFileName, dep2DevelopFilePath
        writeFile(includeFileName, includeFileContent)

        let
          developFilePath = getCurrentDir() / developFileName
          (output, errorCode) = execNimble("develop", &"-p:{installDir}",
            pkgAName,                    # fail because not a direct dependency
             "-c",                       # success
            &"-a:{depPath}",             # success
            &"-a:{dep2Path}",            # fail because of names collision
            &"-i:{includeFileName}",     # fail because of names collision
            &"-n:{depName}",             # success
            &"-c:{developFilePath}",     # fail because the file already exists
            &"-a:{dep2Path}",            # success
            &"-i:{includeFileName}",     # success
            &"-i:{invalidInclFilePath}", # fail
            &"-c:{dep2DevelopFilePath}") # success

        check errorCode == QuitFailure
        var lines = output.processOutput
        check lines.inLinesOrdered(pkgSetupInDevModeMsg(
          pkgAName, installDir / pkgAName))
        check lines.inLinesOrdered(emptyDevFileCreatedMsg(developFileName))
        check lines.inLinesOrdered(
          pkgAddedInDevModeMsg(depNameAndVersion, depPath))
        check lines.inLinesOrdered(
          pkgAlreadyPresentAtDifferentPathMsg(depName, depPath))
        check lines.inLinesOrdered(
          failedToInclInDevFileMsg(includeFileName, developFilePath))
        check lines.inLinesOrdered(pkgFoundMoreThanOnceMsg(depName,
          [(depPath.Path, developFilePath.Path),
           (dep2Path.Path, includeFileName.Path)].toHashSet))
        check lines.inLinesOrdered(
          pkgRemovedFromDevModeMsg(depNameAndVersion, depPath))
        check lines.inLinesOrdered(fileAlreadyExistsMsg(developFilePath))
        check lines.inLinesOrdered(
          pkgAddedInDevModeMsg(depNameAndVersion, dep2Path))
        check lines.inLinesOrdered(inclInDevFileMsg(includeFileName))
        check lines.inLinesOrdered(failedToLoadFileMsg(invalidInclFilePath))
        check lines.inLinesOrdered(emptyDevFileCreatedMsg(dep2DevelopFilePath))
        check parseFile(dep2DevelopFilePath) ==
              parseJson(emptyDevelopFileContent)
        check lines.inLinesOrdered(notADependencyErrorMsg(
          &"{pkgAName}@0.6.0", dependentPkgNameAndVersion))
        const expectedDevelopFileContent = developFile(
          @[includeFileName], @[dep2Path])
        check parseFile(developFileName) ==
              parseJson(expectedDevelopFileContent)
