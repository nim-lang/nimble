import "babel/parser", "babel/version", osproc, strutils, re, os, parseutils

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
          var conf   = parseBabel(path)
          var verRet = conf.verify()
          if verRet == "":
            if withinRange(newVersion(conf.version), verRange):
              return True
          else:
            raise newException(EInstall, "Package has an invalid .babel file: " &
                               verRet)

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

  if proj.library:
    # TODO: How will we handle multiple versions?
    var projDir = babelDir / "lib" / proj.name # $babel/lib/name
    dirs.add(projDir)
    createDirs(dirs)
    # Copy the files
    for i in items(proj.modules):
      var file = proj.confDir / i.addFileExt("nim")
      stdout.write("Copying " & file & "...")
      copyFile(file, projDir / i.addFileExt("nim"))
      echo(" Done!")
    if proj.files.len > 0:
      for i in items(proj.files):
        var file = proj.confDir / i
        stdout.write("Copying " & file & "...")
        copyFile(file, projDir / i)
        echo(" Done!")      

    # Copy the .babel file into the packages folder.
    var babelFile = proj.confDir / proj.name.addFileExt("babel")
    stdout.write("Copying " & babelFile & "...")
    copyFile(babelFile, babelDir / "packages" / babelFile)
    echo(" Done!")

  elif proj.executable:
    # TODO: Copy files for executable.
    assert(false)
  

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
