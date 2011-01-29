import parser, version, osproc, strutils, re, os, parseutils, streams

type
  EInstall = object of EBase

  TDepend = tuple[name: String, verRange: PVersionRange]

proc getBabelDir(): string =
  when defined(windows):
    result = getHomeDir() / "babel"
  else:
    result = getHomeDir() / ".babel"

proc getNimVersion(cmd: string = "nimrod"): String =
  var output = execProcess(cmd & " -v")
  var line = splitLines(output)[0]

  # Thanks Araq :)
  var i = 0
  var nimrodVersion = ""
  i = skipIgnoreCase(line, "Nimrod Compiler Version ")
  if i <= 0: raise newException(EInstall, "Cannot detect Nimrod's version")
  i = parseToken(line, nimrodVersion, {'.', '0'..'9'}, i)
  if nimrodVersion.len == 0: 
    raise newException(EInstall, "Cannot detect Nimrod's version")

  return nimrodVersion

proc compile*(file: string, flags: string = "") =
  var args: string = flags & "c " & file
  echo("Compiling " & file & "...")
  var code = execShellCmd(findExe("nimrod") & " " & args)
  if code != quitSuccess:
    raise newException(EInstall, "Compilation failed: Nimrod returned exit code " &
                       $code)

proc dependExists(name: string, verRange: PVersionRange): Bool =
  if name == "nimrod":
    var nimVer = getNimVersion()
    if not withinRange(newVersion(nimVer), verRange):
      raise newException(EInstall, "Nimrod version doesn't satisfy dependency: " &
                         nimVer & " " & $verRange)
    else: return True
  else:
    for kind, path in walkDir(getBabelDir() / "packages"):
      if kind == pcFile:
        var file = path.extractFilename()
        if file == name.addFileExt("babel"):
          if verRange.kind != verAny:
            var conf   = parseBabel(path)
            var verRet = conf.verify()
            if verRet == "":
              if withinRange(newVersion(conf.version), verRange):
                return True
            else:
              raise newException(EInstall, "Package has an invalid .babel file: " &
                                 verRet)
          else: return True

  return False

proc verifyDepends(proj: TProject): seq[TDepend] =
  result = @[]
  for i in items(proj.depends):
    var spl = i.split()
    var nameStr = ""
    var verStr  = ""
    if spl.len == 1:
      nameStr = spl[0]
    elif spl.len > 1:
      nameStr = spl[0]
      spl.delete(0)
      verStr  = join(spl, " ")
    else:
      raise newException(EInstall, "Incorrect dependency got: " & i)
    
    var verRange: PVersionRange
    if verStr == "":
      new(verRange)
      verRange.kind = verAny
    else:
      verRange = parseVersionRange(verStr)

    if not dependExists(nameStr, verRange):
      result.add((nameStr, verRange))

proc createDirs(dirs: seq[string]) =
  for i in items(dirs):
    createDir(i)

proc copyFiles(proj: TProject) =
  # This will create a $home/.babel and lib/ or bin/. It will also copy all the
  # files listed in proj.modules and proj.files and the .babel file.
  var babelDir = getBabelDir()

  var dirs = @[babelDir, babelDir / "lib", babelDir / "bin", babelDir / "packages"]
  createDirs(dirs)
  if proj.library:
    # TODO: How will we handle multiple versions?
    var projDir = babelDir / "lib" / proj.name # $babel/lib/name
    createDir(projDir)
    # Copy the files
    for i in items(proj.modules):
      var file   = proj.confDir / i.addFileExt("nim")
      var copyTo = projDir / i.addFileExt("nim")
      stdout.write("Copying " & file & " to " & copyTo & "...")
      copyFile(file, copyTo)
      echo(" Done!")
    if proj.files.len > 0:
      for i in items(proj.files):
        var file   = proj.confDir / i
        var copyTo = projDir / i
        stdout.write("Copying " & file & " to " & copyTo & "...")
        copyFile(file, copyTo)
        echo(" Done!")

  elif proj.executable:
    var exeSrcFile = proj.confDir / proj.exeFile.addFileExt("nim")
    # Compile
    compile(exeSrcFile)
    
    var exeCmpFile = exeSrcFile.changeFileExt(ExeExt)
    var copyTo = babelDir / "bin" / proj.exeFile.addFileExt(ExeExt)
    stdout.write("Copying " & exeCmpFile & " to " & copyTo & "...")
    copyFile(exeCmpFile, copyTo)
    echo(" Done!")

  # Copy the .babel file into the packages folder.
  var babelFile = proj.confDir / proj.name.addFileExt("babel")
  var copyTo    = babelDir / "packages" / proj.name.addFileExt("babel")
  stdout.write("Copying " & babelFile & " to " & copyTo & "...")
  copyFile(babelFile, copyTo)
  echo(" Done!")

proc install*(name: string, filename: string = "") =
  ## Install package by the name of ``name``, filename specifies where to look for it
  ## if left as "", the current working directory will be assumed.
  # TODO: Add a `debug` variable? If true the status messages get echo-ed,
  # vice-versa if false?
  var babelFile: TProject
  var path = ""
  if filename == "":
    path = name.addFileExt("babel")
  else:
    path = filename / name.addFileExt("babel")

  echo("Reading ", path, "...")
  babelFile = parseBabel(path)

  var ret = babelFile.verify()
  if ret != "":
    raise newException(EInstall, "Verifying the .babel file failed: " & ret)

  # Check whether this package is already installed
  # TODO: Different versions
  # TODO: Commented for testing -- Uncomment.
  #if dependExists(babelFile.name, newVRAny()):
  #  raise newException(EInstall, 
  #          "This package is already installed: TODO: different versions.")

  if babelFile.depends.len == 1:
    echo("Verifying 1 dependency...")
  else:
    echo("Verifying ", babelFile.depends.len(), " dependencies...")
  var dependsNeeded = babelFile.verifyDepends()
  if dependsNeeded.len() > 0:
    raise newException(EInstall, "TODO: Download & Install dependencies.")
  else:
    echo("All dependencies verified!")

  echo("Installing " & babelFile.name & "...")
  babelFile.copyFiles()

  echo("Package " & babelFile.name & " successfully installed.")

when isMainModule:
  install(paramStr(1))
