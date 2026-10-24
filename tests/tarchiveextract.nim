{.used.}
import std/[unittest, os, tempfiles, tables]
import nimblepkg/downloadnim
import zippy/ziparchives
when not defined(windows):
  import std/osproc
  import zippy

suite "Compiler archive extraction":
  test "ZIP archive in a path containing spaces":
    let workDir = createTempDir("nimble zip ", "")
    defer: removeDir(workDir)
    let archive = workDir / "compiler archive.zip"
    let destination = workDir / "extracted compiler"
    writeFile(archive, createZipArchive({"package/bin/hello": "archive-ok"}.toTable))
    extract(archive, destination)
    check readFile(destination / "bin" / "hello") == "archive-ok"

  when not defined(windows):
    test "tar formats preserve executable permissions and symbolic links":
      let tarExe = findExe("tar")
      if tarExe == "":
        skip()
      else:
        let workDir = createTempDir("nimble tar ", "")
        defer: removeDir(workDir)
        let source = workDir / "archive source"
        createDir(source / "package" / "bin")
        let executable = source / "package" / "bin" / "hello"
        writeFile(executable, "#!/bin/sh\necho archive-ok\n")
        setFilePermissions(executable, {fpUserRead, fpUserWrite, fpUserExec})
        createSymlink("bin/hello", source / "package" / "hello-link")
        let tarPath = workDir / "compiler archive.tar"
        let created = execCmdEx(tarExe.quoteShell & " cf " & tarPath.quoteShell &
          " -C " & source.quoteShell & " package")
        checkpoint(created.output)
        require created.exitCode == 0
        writeFile(tarPath & ".gz", compress(readFile(tarPath), dataFormat = dfGzip))
        var archives = @[tarPath, tarPath & ".gz"]
        let xzExe = findExe("xz")
        if xzExe != "":
          let compressed = execCmdEx(xzExe.quoteShell & " -k " & tarPath.quoteShell)
          checkpoint(compressed.output)
          require compressed.exitCode == 0
          archives.add(tarPath & ".xz")
        for index, archive in archives:
          checkpoint(archive)
          let destination = workDir / ("extracted compiler " & $index)
          extract(archive, destination)
          check readFile(destination / "bin" / "hello") == "#!/bin/sh\necho archive-ok\n"
          check fpUserExec in getFilePermissions(destination / "bin" / "hello")
          check symlinkExists(destination / "hello-link")
          check readFile(destination / "hello-link") == readFile(executable)
        # Exercise the library fallback with no external archive tools on PATH.
        block:
          let tools = workDir / "empty tools"
          createDir(tools)
          let previousPath = getEnv("PATH")
          defer: putEnv("PATH", previousPath)
          putEnv("PATH", tools)
          check not canExtractNimXz()
          for index, archive in [tarPath, tarPath & ".gz"]:
            let destination = workDir / ("library extraction " & $index)
            extract(archive, destination)
            check readFile(destination / "bin" / "hello") == readFile(executable)
            check fpUserExec in getFilePermissions(destination / "bin" / "hello")
            check symlinkExists(destination / "hello-link")

    test "xz extraction without unxz uses tar directly":
      let tarExe = findExe("tar")
      let xzExe = findExe("xz")
      if tarExe == "" or xzExe == "":
        skip()
      else:
        let workDir = createTempDir("nimble xz ", "")
        defer: removeDir(workDir)
        createDir(workDir / "source" / "package")
        writeFile(workDir / "source" / "package" / "hello", "archive-ok")
        let archive = workDir / "compiler.tar"
        let created = execCmdEx(tarExe.quoteShell & " cf " & archive.quoteShell &
          " -C " & (workDir / "source").quoteShell & " package")
        checkpoint(created.output)
        require created.exitCode == 0
        let compressed = execCmdEx(xzExe.quoteShell & " " & archive.quoteShell)
        checkpoint(compressed.output)
        require compressed.exitCode == 0
        let tools = workDir / "tools"
        createDir(tools)
        createSymlink(tarExe, tools / "tar")
        createSymlink(xzExe, tools / "xz")
        let previousPath = getEnv("PATH")
        defer: putEnv("PATH", previousPath)
        putEnv("PATH", tools)
        check findExe("unxz") == ""
        check canExtractNimXz()
        extract(archive & ".xz", workDir / "extracted")
        check readFile(workDir / "extracted" / "hello") == "archive-ok"
