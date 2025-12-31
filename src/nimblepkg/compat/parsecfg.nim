import std/[parsecfg, streams]

export parsecfg except open, close

proc open*(c: var CfgParser, input: Stream, filename: string,
           lineOffset = 0) =
  {.cast(raises: [CatchableError]).}:
    parsecfg.open(c, input, filename, lineOffset)

proc close*(c: var CfgParser) =
  {.cast(raises: [CatchableError]).}:
    parsecfg.close(c)