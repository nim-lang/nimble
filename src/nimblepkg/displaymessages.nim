# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

## This module contains procedures producing some of the displayed by Nimble
## error messages in order to facilitate testing by removing the requirement
## the message to be repeated both in Nimble and the testing code.

import strformat, strutils
import version

const
  validationFailedMsg* = "Validation failed."

  pathGivenButNoPkgsToDownloadMsg* =
    "Path option is given but there are no given packages for download."
  
  developOptionsOutOfPkgDirectoryMsg* =
    "Options 'add', 'remove', 'include' and 'exclude' cannot be given " &
    "when develop is being executed out of a valid package directory."

  dependencyNotInRangeErrorHint* =
    "Update the version of the dependency package in its Nimble file or " &
    "update its required version range in the dependent's package Nimble file."

  notADependencyErrorHint* =
    "Add the dependency package as a requirement to the Nimble file of the " &
    "dependent package."

  multiplePathOptionsGivenMsg* = "Multiple path options are given."

  updatingTheLockFileMsg* = "Updating the lock file..."
  generatingTheLockFileMsg* = "Generating the lock file..."
  lockFileIsUpdatedMsg* = "The lock file is updated."
  lockFileIsGeneratedMsg* = "The lock file is generated."

proc fileAlreadyExistsMsg*(path: string): string =
  &"Cannot create file \"{path}\" because it already exists."

proc emptyDevFileCreatedMsg*(path: string): string =
  &"An empty develop file \"{path}\" has been created."

proc pkgSetupInDevModeMsg*(pkgName, pkgPath: string): string =
  &"\"{pkgName}\" set up in develop mode successfully to \"{pkgPath}\"."

proc pkgInstalledMsg*(pkgName: string): string =
  &"{pkgName} installed successfully."

proc pkgNotFoundMsg*(pkg: PkgTuple): string = &"Package {pkg} not found."

proc pkgDepsAlreadySatisfiedMsg*(dep: PkgTuple): string =
  &"Dependency on {dep} already satisfied"

proc invalidPkgMsg*(path: string): string =
  &"The package at \"{path}\" is invalid."

proc invalidDevFileMsg*(path: string): string =
  &"The develop file \"{path}\" is invalid."

proc notAValidDevFileJsonMsg*(devFilePath: string): string =
  &"The file \"{devFilePath}\" has not a valid develop file JSON schema."

proc pkgAlreadyPresentAtDifferentPathMsg*(pkgName, otherPath: string): string =
  &"A package with a name \"{pkgName}\" at different path \"{otherPath}\" " &
   "is already present in the develop file."

proc pkgAddedInDevModeMsg*(pkg, path: string): string =
  &"The package \"{pkg}\" at path \"{path}\" is added as a develop mode " &
   "dependency."

proc pkgAlreadyInDevModeMsg*(pkg, path: string): string =
  &"The package \"{pkg}\" at path \"{path}\" is already in develop mode."

proc pkgRemovedFromDevModeMsg*(pkg, path: string): string =
  &"The package \"{pkg}\" at path \"{path}\" is removed from the develop file."

proc pkgPathNotInDevFileMsg*(path: string): string =
  &"The path \"{path}\" is not in the develop file."

proc pkgNameNotInDevFileMsg*(pkgName: string): string =
  &"A package with name \"{pkgName}\" is not in the develop file."

proc failedToInclInDevFileMsg*(inclFile, devFile: string): string =
  &"Failed to include \"{inclFile}\" to \"{devFile}\""

proc inclInDevFileMsg*(path: string): string =
  &"The develop file \"{path}\" is successfully included into the current " &
   "project's develop file."

proc alreadyInclInDevFileMsg*(path: string): string =
  &"The develop file \"{path}\" is already included in the current project's " &
   "develop file."

proc exclFromDevFileMsg*(path: string): string =
  &"The develop file \"{path}\" is successfully excluded from the current " &
   "project's develop file."

proc notInclInDevFileMsg*(path: string): string =
  &"The develop file \"{path}\" is not included in the current project's " &
   "develop file."

proc failedToLoadFileMsg*(path: string): string =
  &"Failed to load \"{path}\"."

proc cannotUninstallPkgMsg*(pkgName: string, pkgVersion: Version,
                            deps: seq[string]): string =
  assert deps.len > 0, "The sequence must have at least one package."
  result = &"Cannot uninstall {pkgName} ({pkgVersion}) because\n"
  result &= deps.join("\n")
  result &= "\ndepend" & (if deps.len == 1: "s" else: "") & " on it"

proc promptRemovePkgsMsg*(pkgs: seq[string]): string =
  assert pkgs.len > 0, "The sequence must have at least one package."
  result = "The following packages will be removed:\n"
  result &= pkgs.join("\n")
  result &= "\nDo you wish to continue?"

proc pkgWorkingCopyNeedsSyncingMsg*(pkgName, pkgPath: string): string =
  &"Package \"{pkgName}\" working copy at path \"{pkgPath}\" needs syncing."

proc pkgWorkingCopyIsSyncedMsg*(pkgName, pkgPath: string): string =
  &"Working copy of package  \"{pkgName}\" at \"{pkgPath}\" is synced."

proc notInRequiredRangeMsg*(
    dependencyPkgName, dependencyPkgPath, dependencyPkgVersion,
    dependentPkgName, dependentPkgPath, requiredVersionRange: string): string =
  &"The version of the package \"{dependencyPkgName}\" at " &
  &"\"{dependencyPkgPath}\" is \"{dependencyPkgVersion}\" and it does not " &
  &"match the required by the package \"{dependentPkgName}\" at " &
  &"\"{dependentPkgPath}\" version \"{requiredVersionRange}\"."
  
proc invalidDevelopDependenciesVersionsMsg*(errors: seq[string]): string =
  result = "Some of the develop mode dependencies are with versions which " &
           "are not in the required by other package's Nimble file range."
  for error in errors:
    result &= "\n"
    result &= error
