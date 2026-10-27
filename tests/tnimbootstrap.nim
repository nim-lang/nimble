{.used.}
import std/unittest
when not defined(windows):
  import std/[os, tempfiles]
import nimblepkg/nimenv
when defined(illumos):
  import std/[options, strutils]
  import chronos
  import nimblepkg/[options, version, downloadnim, common]

suite "Nim source bootstrap policy":
  test "csources build command selection":
    when defined(windows):
      check getCsourcesBuildCommand() == "build.bat"
    else:
      let tools = createTempDir("nimble build tools ", "")
      defer: removeDir(tools)
      let previousPath = getEnv("PATH")
      defer: putEnv("PATH", previousPath)
      putEnv("PATH", tools)
      check getCsourcesBuildCommand() == "sh build.sh"
      # These executables must only be selected, never run.
      for name in ["make", "gmake"]:
        writeFile(tools / name, "#!/bin/sh\nexit 99\n")
        setFilePermissions(tools / name, {fpUserRead, fpUserWrite, fpUserExec})
      when defined(illumos) or defined(bsd):
        check getCsourcesBuildCommand() == (tools / "gmake").quoteShell
        removeFile(tools / "gmake")
        check getCsourcesBuildCommand() == "sh build.sh"
      else:
        check getCsourcesBuildCommand() == (tools / "make").quoteShell

  when defined(illumos):
    test "source compilation fails clearly before fetching csources":
      let workDir = createTempDir("nimble bootstrap ", "")
      defer: removeDir(workDir)
      let dest = workDir / "nim-unbuilt"
      createDir(dest)
      try:
        waitFor compileNim(initOptions(), dest, parseVersionRange("2.2.6"))
        check false
      except NimbleError as error:
        check "not yet supported on illumos" in error.msg
        check "--useSystemNim" in error.msg
      check not dirExists(workDir / "csources_v3")
      check not fileExists(dest / "activate.sh")

    test "automatic install refuses release and devel sources before download":
      let workDir = createTempDir("nimble bootstrap download ", "")
      defer: removeDir(workDir)
      var opts = initOptions()
      opts.nimBinariesDir = workDir / "binaries"
      for version in [newVersion("2.2.6"), newVersion("#devel")]:
        expect NimbleError:
          discard waitFor downloadAndExtractNim(version, opts)
      check not dirExists(opts.nimBinariesDir)

    test "an already-built native compiler can still be reused":
      let nativeNim = findExe("nim")
      require nativeNim != ""
      let nativeVersion = getNimVersionFromBin(nativeNim)
      require nativeVersion.isSome
      let workDir = createTempDir("nimble native reuse ", "")
      defer: removeDir(workDir)
      var opts = initOptions()
      opts.nimBinariesDir = workDir
      let dest = getNimInstallationDir(opts, nativeVersion.get)
      createDir(dest / "bin")
      createSymlink(nativeNim, dest / "bin" / "nim")
      waitFor compileNim(opts, dest, nativeVersion.get.toVersionRange)
      let reused = waitFor downloadAndExtractNim(nativeVersion.get, opts)
      require reused.isSome
      check reused.get == dest
