import compiler/[ast, idents, lineinfos, options, syntaxes, llstream]

export syntaxes except parseAll, setupParser, openParser
export llstream

proc parseAll*(p: var Parser): PNode {.raises: [CatchableError], gcsafe.} =
  # TODO fix upstream
  {.cast(gcsafe).}:
    {.cast(raises: [CatchableError]).}:
      syntaxes.parseAll(p)

proc setupParser*(p: var Parser; fileIdx: FileIndex; cache: IdentCache;
                   config: ConfigRef): bool {.raises: [CatchableError], gcsafe.} =
  {.cast(gcsafe).}:
    {.cast(raises: [CatchableError]).}:
      syntaxes.setupParser(p, fileIdx, cache, config)

proc openParser*(p: var Parser; fileIdx: FileIndex; inputStream: PLLStream;
                 cache: IdentCache; config: ConfigRef) {.raises: [CatchableError], gcsafe.} =
  {.cast(gcsafe).}:
    {.cast(raises: [CatchableError]).}:
      syntaxes.openParser(p, fileIdx, inputStream, cache, config)