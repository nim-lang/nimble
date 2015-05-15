# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
import parsecfg, streams, strutils, os

import tools, version, nimbletypes

type
  Config* = object
    nimbleDir*: string
    chcp*: bool # Whether to change the code page in .cmd files on Win.
    

proc initConfig(): Config =
  if getNimrodVersion() > newVersion("0.9.6"):
    result.nimbleDir = getHomeDir() / ".nimble"
  else:
    result.nimbleDir = getHomeDir() / ".babel"

  result.chcp = true

proc parseConfigFile(confFile: string, curr: Config): Config =
  result = curr # return same, but with overrides
  var f = newFileStream(confFile, fmRead)
  var p: CfgParser
  open(p, f, confFile)
  while true:
    var e = next(p)
    case e.kind
    of cfgEof:
      break
    of cfgSectionStart: discard
    of cfgKeyValuePair, cfgOption:
      case e.key.normalize
      of "nimbledir":
        # Ensure we don't restore the deprecated nimble dir.
        if e.value != getHomeDir() / ".babel":
          result.nimbleDir = e.value
      of "chcp":
        result.chcp = parseBool(e.value)
      else:
        raise newException(NimbleError, "Unable to parse config file:" &
                                    " Unknown key: " & e.key)
    of cfgError:
      raise newException(NimbleError, "Unable to parse config file: " & e.msg)
  close(p)
  close(f)

proc readable(fname: string): bool =
  # TODO: Make this simpler.
  var f = newFileStream(fname, fmRead)
  if f != nil:
    result = true
    close(f)

proc parseConfig*(): Config =
  result = initConfig()
  var confFile = getConfigDir() / "nimble" / "nimble.ini"

  if (not readable(confFile)):
    # Try the old deprecated babel.ini
    confFile = getConfigDir() / "babel" / "babel.ini"
    if (not readable(confFile)):
      return
    echo("[Warning] Using deprecated config file at ", confFile)
  
  echo("Reading from config file at ", confFile)
  result = parseConfigFile(confFile, result)
