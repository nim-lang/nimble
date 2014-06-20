import osproc, unittest, strutils, os

const path = "../src/babel"

discard execCmdEx("nimrod c " & path)

template cd*(dir: string, body: stmt) =
  ## Sets the current dir to ``dir``, executes ``body`` and restores the
  ## previous working dir.
  let lastDir = getCurrentDir()
  setCurrentDir(dir)
  body
  setCurrentDir(lastDir)

test "can install packagebin2":
  let (outp, exitCode) = execCmdEx(path & " install -y https://github.com/babel-test/packagebin2.git")
  check exitCode == QuitSuccess

test "can reject same version dependencies":
  let (outp, exitCode) = execCmdEx(path & " install -y https://github.com/babel-test/packagebin.git")
  #echo outp
  # TODO: outp is not in the correct order.
  let ls = outp.strip.splitLines()
  check exitCode != QuitSuccess
  check ls[ls.len-1] == "Error: unhandled exception: Cannot satisfy the dependency on PackageA 0.2.0 and PackageA 0.5.0 [EBabel]"

test "can update":
  let (outp, exitCode) = execCmdEx(path & " update")
  check exitCode == QuitSuccess

test "issue #27":
  # Install b
  cd "issue27/b":
    check execCmdEx("../../" & path & " install -y").exitCode == QuitSuccess

  # Install a
  cd "issue27/a":
    check execCmdEx("../../" & path & " install -y").exitCode == QuitSuccess

  cd "issue27":
    check execCmdEx("../" & path & " install -y").exitCode == QuitSuccess
