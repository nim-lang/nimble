import std/[os, sugar, strutils, osproc]
import std/private/globs


const
  blockList = ["nimcache", "htmldocs"] # Folders to explicitly ignore.
  baseCmd = " doc --project --docroot --outdir:htmldocs --styleCheck:hint " # nim doc command part that never changes
  jsDocOpts =  # nim doc command part that changes for JS compat.
    when defined(fusionDocJs): "-b:js "
    else: ""
  docComand = baseCmd & jsDocOpts


iterator findNimSrcFiles*(dir: string): string =
  func follow(a: PathEntry): bool =
    a.path.lastPathPart notin blockList

  for entry in walkDirRecFilter(dir, follow = follow):
    if entry.path.splitFile.ext == ".nim" and entry.kind == pcFile:
      yield entry.path


proc genCodeImportAll*(dir: string): string =
  result = "{.warning[UnusedImport]: off.}\n"
  var name, prefix: string
  for nimfile in findNimSrcFiles(dir):
    name = nimfile.extractFilename
    prefix =
      if name.startsWith "js":
        "when defined(js): import "
      else:
        "when not defined(js): import "
    result.add prefix & "".dup(addQuoted(nimfile)) & "\n"


proc genDocs(dir: string, nim = "", args: seq[string]) =
  let code = genCodeImportAll(dir)
  let extra = quoteShellCommand(args)
  let nim = if nim.len == 0: getCurrentCompilerExe() else: nim
  let ret = execCmdEx(nim & docComand & extra & " - ", input = code)
  if ret.exitCode != 0:
    doAssert false, ret.output & '\n' & code


when isMainModule:
  let args = commandLineParams()
  doAssert args.len >= 1
  let dir = args[0]
  genDocs(dir, nim="", args[1..^1])
