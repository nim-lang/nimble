import parser, version, osproc, strutils, re, os, parseutils

type
  EInstall = object of EBase

  TDepend = tuple[name: String, verRange: PVersionRange]

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
      raise newException(EInstall, "Nimrod version(" & 
                         nimVer & ") doesn't satisfy dependency")
    else: return True
  else:
    # TODO: Figure out how to check whether a package has been installed...
    # ... Perhaps a list of all the packages that have been installed?
    # ... or just look for the package in PATH + $nimrod/lib/babel/packageName
    assert(False)

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
      spl.del(0)
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
  # files listed in proj.modules and proj.files.
  when defined(windows):
    var babelDir = getHomeDir() / "babel"
  else:
    var babelDir = getHomeDir() / ".babel"

  var dirs = @[babelDir, babelDir / "lib", babelDir / "bin"]

  if proj.library:
    var projDir = babelDir / "lib" / (proj.name & "-" & proj.version)
    dirs.add(projDir)
    createDirs(dirs)
    # Copy the files
    for i in items(proj.modules):
      stdout.write("Copying " & i.addFileExt("nim") & "...")
      copyFile(i.addFileExt("nim"), projDir / i.addFileExt("nim"))
      echo(" Done!")
    if proj.files.len > 0:
      for i in items(proj.files):
        stdout.write("Copying " & i.addFileExt("nim") & "...")
        copyFile(i, projDir / i)
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

  echo("Installing " & name & "...")
  babelFile.copyFiles()

  echo("Package " & name & " successfully installed.")

when isMainModule:
  install("babel")
