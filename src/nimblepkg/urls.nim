import std/pegs

proc isURL*(name: string): bool =
  name.startsWith(peg" @'://' ") or name.startsWith(peg"\ident+'@'@':'.+")
