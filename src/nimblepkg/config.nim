# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
import parsecfg, streams, strutils, os

import tools, version

type
  TConfig* = object
    nimbleDir*: string

proc initConfig(): TConfig =
  if getNimrodVersion() > newVersion("0.9.6"):
    result.nimbleDir = getHomeDir() / ".nimble"
  else:
    result.nimbleDir = getHomeDir() / ".babel"

proc parseConfig*(): TConfig =
  result = initConfig()
  var confFile = getConfigDir() / "nimble" / "nimble.ini"

  var f = newFileStream(confFile, fmRead)
  if f == nil:
    # Try the old deprecated babel.ini
    confFile = getConfigDir() / "babel" / "babel.ini"
    f = newFileStream(confFile, fmRead)
    if f != nil:
      echo("[Warning] Using deprecated config file at ", confFile)
  
  if f != nil:
    echo("Reading from config file at ", confFile)
    var p: TCfgParser
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
          result.nimbleDir = e.value
        else:
          raise newException(ENimble, "Unable to parse config file:" &
                                     " Unknown key: " & e.key)
      of cfgError:
        raise newException(ENimble, "Unable to parse config file: " & e.msg)
    close(p)
