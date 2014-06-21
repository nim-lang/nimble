# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
import parsecfg, streams, strutils, os

import tools

type
  TConfig* = object
    babelDir*: string

proc initConfig(): TConfig =
  result.babelDir = getHomeDir() / ".babel"

proc parseConfig*(): TConfig =
  result = initConfig()
  let confFile = getConfigDir() / "babel" / "babel.ini"

  var f = newFileStream(confFile, fmRead)
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
        of "babeldir":
          result.babelDir = e.value
        else:
          raise newException(EBabel, "Unable to parse config file:" &
                                     " Unknown key: " & e.key)
      of cfgError:
        raise newException(EBabel, "Unable to parse config file: " & e.msg)
    close(p)
