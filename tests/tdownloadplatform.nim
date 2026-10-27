{.used.}
import std/unittest
import nimblepkg/downloadnim
when not (defined(windows) or defined(linux) or defined(macosx) or
          defined(freebsd) or defined(openbsd) or defined(haiku)):
  import std/json
when defined(illumos) and defined(amd64):
  import std/[os, tempfiles]
  import nimblepkg/options

suite "Compiler download platform selection":
  test "release platform key":
    when defined(windows):
      check getPlatformString(64) == "windows_x64"
    elif defined(linux):
      check getPlatformString(64) == "linux_x64"
    elif defined(macosx):
      check getPlatformString(64) in ["macosx_x64", "macosx_arm64"]
    else:
      check getPlatformString(64) == "source_tar"
      check getPlatformString(32) == "source_tar"

  test "unsupported nightly platforms do not select foreign binaries":
    when not (defined(windows) or defined(linux) or defined(macosx) or
              defined(freebsd) or defined(openbsd) or defined(haiku)):
      let releases = parseJson("""[
        {"name": "devel", "tag_name": "latest-devel", "assets": [
          {"name": "linux_x64.tar.xz", "browser_download_url": "https://example.invalid/linux"},
          {"name": "windows_x64.zip", "browser_download_url": "https://example.invalid/windows"}
        ]}
      ]""")
      check getNightliesUrl(releases, 64) == ("", "")
      check getNightliesUrl(releases, 32) == ("", "")
    else:
      skip()

  test "illumos amd64 GCC probe uses 64-bit output":
    when defined(illumos) and defined(amd64):
      # Isolate the probe's fixed archtest filename from the working tree.
      let workDir = createTempDir("nimble-gcc-arch-", "")
      let previousDir = getCurrentDir()
      defer:
        setCurrentDir(previousDir)
        removeDir(workDir)
      setCurrentDir(workDir)
      require findExe("gcc") != ""
      check getGccArch(initOptions()) == 64
      check not fileExists("archtest")
    else:
      skip()
