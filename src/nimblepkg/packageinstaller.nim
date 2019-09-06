# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
import os, strutils, sets, json

# Local imports
import cli, options, tools

when defined(windows):
  import version

when not declared(initHashSet) or not declared(toHashSet):
  import common

when defined(windows):
  # This is just for Win XP support.
  # TODO: Drop XP support?
  from winlean import WINBOOL, DWORD
  type
    OSVERSIONINFO* {.final, pure.} = object
      dwOSVersionInfoSize*: DWORD
      dwMajorVersion*: DWORD
      dwMinorVersion*: DWORD
      dwBuildNumber*: DWORD
      dwPlatformId*: DWORD
      szCSDVersion*: array[0..127, char]

  proc GetVersionExA*(VersionInformation: var OSVERSIONINFO): WINBOOL{.stdcall,
    dynlib: "kernel32", importc: "GetVersionExA".}

proc setupBinSymlink*(symlinkDest, symlinkFilename: string,
                      options: Options): seq[string] =
  result = @[]
  let currentPerms = getFilePermissions(symlinkDest)
  setFilePermissions(symlinkDest, currentPerms + {fpUserExec})
  when defined(unix):
    display("Creating", "symlink: $1 -> $2" %
            [symlinkDest, symlinkFilename], priority = MediumPriority)
    if existsFile(symlinkFilename):
      let msg = "Symlink already exists in $1. Replacing." % symlinkFilename
      display("Warning:", msg, Warning, HighPriority)
      removeFile(symlinkFilename)

    createSymlink(symlinkDest, symlinkFilename)
    result.add symlinkFilename.extractFilename
  elif defined(windows):
    # There is a bug on XP, described here:
    # http://stackoverflow.com/questions/2182568/batch-script-is-not-executed-if-chcp-was-called
    # But this workaround brakes code page on newer systems, so we need to detect OS version
    var osver = OSVERSIONINFO()
    osver.dwOSVersionInfoSize = cast[DWORD](sizeof(OSVERSIONINFO))
    if GetVersionExA(osver) == WINBOOL(0):
      raise newException(NimbleError,
        "Can't detect OS version: GetVersionExA call failed")
    let fixChcp = osver.dwMajorVersion <= 5

    # Create cmd.exe/powershell stub.
    let dest = symlinkFilename.changeFileExt("cmd")
    display("Creating", "stub: $1 -> $2" % [symlinkDest, dest],
            priority = MediumPriority)
    var contents = "@"
    if options.config.chcp:
      if fixChcp:
        contents.add "chcp 65001 > nul && "
      else: contents.add "chcp 65001 > nul\n@"
    contents.add "\"" & symlinkDest & "\" %*\n"
    writeFile(dest, contents)
    result.add dest.extractFilename
    # For bash on Windows (Cygwin/Git bash).
    let bashDest = dest.changeFileExt("")
    display("Creating", "Cygwin stub: $1 -> $2" %
            [symlinkDest, bashDest], priority = MediumPriority)
    writeFile(bashDest, "\"" & symlinkDest & "\" \"$@\"\n")
    result.add bashDest.extractFilename
  else:
    {.error: "Sorry, your platform is not supported.".}

proc saveNimbleMeta*(pkgDestDir, url, vcsRevision: string,
                    filesInstalled, bins: HashSet[string],
                    isLink: bool = false) =
  ## Saves the specified data into a ``nimblemeta.json`` file inside
  ## ``pkgDestDir``.
  ##
  ## filesInstalled - A list of absolute paths to files which have been
  ##                  installed.
  ## bins - A list of binary filenames which have been installed for this
  ##        package.
  ##
  ## isLink - Determines whether the installed package is a .nimble-link.
  var nimblemeta = %{"url": %url}
  if vcsRevision.len > 0:
    nimblemeta["vcsRevision"] = %vcsRevision
  let files = newJArray()
  nimblemeta["files"] = files
  for file in filesInstalled:
    files.add(%changeRoot(pkgDestDir, "", file))
  let binaries = newJArray()
  nimblemeta["binaries"] = binaries
  for bin in bins:
    binaries.add(%bin)
  nimblemeta["isLink"] = %isLink
  writeFile(pkgDestDir / "nimblemeta.json", $nimblemeta)

proc saveNimbleMeta*(pkgDestDir, pkgDir, vcsRevision, nimbleLinkPath: string) =
  ## Overload of saveNimbleMeta for linked (.nimble-link) packages.
  ##
  ## pkgDestDir - The directory where the package has been installed.
  ##              For example: ~/.nimble/pkgs/jester-#head/
  ##
  ## pkgDir - The directory where the original package files are.
  ##          For example: ~/projects/jester/
  saveNimbleMeta(pkgDestDir, "file://" & pkgDir, vcsRevision,
                 toHashSet[string]([nimbleLinkPath]), initHashSet[string](), true)