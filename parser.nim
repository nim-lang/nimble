import parsecfg, streams, strutils, version

type
  TProject* = object
    name*: String     # Req
    version*: String  # Req
    author*: String   # Req
    category*: String # Req
    desc*: String     # Req
    license*: String  
    homepage*: String

    library*: bool
    depends*: seq[string] # Dependencies
    modules*: seq[string] # ExtraModules
    files*: seq[string]   # files

    executable*: bool

    unknownFields*: seq[string] # TODO:
    
  EParseErr* = object of EIO

proc initProj*(): TProject =
  result.name = ""
  result.version = ""
  result.author = ""
  result.category = ""
  result.desc = ""
  result.license = ""
  result.homepage = ""

  result.library    = False
  result.executable = False
  result.depends = @[]
  result.modules = @[]
  result.files   = @[]
  
  result.unknownFields = @[]
  

proc parseList(s: string): seq[string] =
  result = @[]  
  var many = s.split({',', ';'})
  for i in items(many):
    result.add(i.strip())
    
proc parseErr(p: TCfgParser, msg: string) =
  raise newException(EParseErr, "(" & $p.getLine() & ", " &
                                $p.getColumn() & ") " & msg)

proc parseBabel*(file: string): TProject =
  var f = newFileStream(file, fmRead)
  if f != nil:
    var p: TCfgParser
    open(p, f, file)
    
    var section: String = ""
    while true:
      var e = next(p)
      case e.kind
      of cfgEof:
        break
      of cfgKeyValuePair:
        case section
        of "":
          case normalize(e.key):
          of "name":
            result.name = e.value
          of "version":
            result.version = e.value
          of "author":
            result.author = e.value
          of "category":
            result.category = e.value
          of "description":
            result.desc = e.value
          of "homepage":
            result.homepage = e.value
          of "license":
            result.license = e.value
          else:
            p.parseErr("Unknown key: " & e.key)
        of "library":
          case normalize(e.key)
          of "depends":
            result.depends = e.value.parseList()
          of "files":
            result.files = e.value.parseList()
          of "exposedmodules":
            result.modules = e.value.parseList()
          else:
            p.parseErr("Unknown key: " & e.key)
        of "executable":
          case normalize(e.key)
          of "depends":
            result.depends = e.value.parseList()
          of "extrafiles":
            result.files = e.value.parseList()
          else:
            p.parseErr("Unknown key: " & e.key)

        else:
          p.parseErr("Unknown section: " & section)

      of cfgSectionStart:
        section = normalize(e.section)
        case normalize(e.section):
        of "library":
          result.library = True
        of "bin":
          result.executable = True
        else:
          p.parseErr("Unknown section: " & section)

      of cfgError:
        p.parseErr(e.msg)

      of cfgOption:
        p.parseErr("Unknown option: " & e.key)

    close(p)
  else:
    raise newException(EIO, "Cannot open " & file)

proc isEmpty*(s: string): Bool = return s == ""

proc verify*(proj: TProject): tuple[b: Bool, reason: string] =
  ## Checks whether the required fields have been specified.
  if isEmpty(proj.name) or isEmpty(proj.version) or isEmpty(proj.author) or
     isEmpty(proj.category) or isEmpty(proj.desc):
    return (False, "Missing required fields.")
  elif proj.library == false and proj.executable == false:
    return (False, "Either a valid Library needs to be specified or a valid Bin.")
  elif proj.library == true and proj.modules.len() == 0:
    return (False, "A valid library needs at least one ExposedModule listed.")
  # TODO: Rules for Bin.

  return (True, "")

when isMainModule:
  for i in items(parseList("test, asdasd >sda;       jsj, kk          >>, sd")):
    echo(i)
  var project = parseBabel("babel.babel")
  echo project.library
