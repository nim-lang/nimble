import parser, version, osproc, strutils, re, os

type
  EInstall = object of EBase

  TDepend = tuple[name: String, verRange: PVersionRange]

proc getNimVersion(cmd: string = "nimrod"): String =
  var output = execProcess(cmd & " -v")
  # TODO: Fix this. Don't know why it doesn't work.
  ##echo(splitlines(output)[0])
  # :\
  if splitlines(output)[0] =~ re"(Version\s.+?\s)":
    echo(matches[0])
    for i in items(matches):
      echo(i)
  else: 
    nil
    #echo(":(")
  
  return "0.8.10"

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

proc verifyDepends*(proj: TProject): seq[TDepend] =
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

proc install*(name: string, filename: string = "") =
  ## Install package by the name of ``name``, filename specifies where to look for it
  ## if left as "", the current working directory will be assumed.
  # TODO: Add a `debug` variable? If true the status messages get echo-ed,
  # vice-versa if false?
  var babelFile: TProject = initProj()
  var path = ""
  if filename == "":
    path = name.addFileExt("babel")
  else:
    path = filename / name.addFileExt("babel")

  echo("Reading ", path, "...")
  babelFile = parseBabel(path)

  var ret = babelFile.verify()
  if not ret.b:
    raise newException(EInstall, "Verifying the .babel file failed: " & ret.reason)
  
  if babelFile.depends.len == 1:
    echo("Verifying 1 dependency...")
  else:
    echo("Verifying ", babelFile.depends.len(), " dependencies...")
  var dependsNeeded = babelFile.verifyDepends()
  if dependsNeeded.len() > 0:
    raise newException(EInstall, "TODO: Download & Install dependencies.")
  else:
    echo("All dependencies verified!")

  echo("Installing " & name)
  # TODO: Install.

when isMainModule:
  install("babel")
