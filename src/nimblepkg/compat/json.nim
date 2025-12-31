import std/json

export json except parseFile, parseJson

proc parseFile*(filename: string): JsonNode {.raises: [CatchableError], gcsafe.} =
  {.cast(raises: [CatchableError]).}:
    {.cast(gcsafe).}:
      json.parseFile(filename)
proc parseJson*(j: string): JsonNode {.raises: [CatchableError], gcsafe.} =
  {.cast(raises: [CatchableError]).}:
    {.cast(gcsafe).}:
      json.parseJson(j)
