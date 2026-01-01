# https://github.com/nim-lang/Nim/pull/25399
import std/pegs

export pegs except peg

func peg*(s: string): Peg {.raises: [EInvalidPeg], gcsafe.} =
  {.cast(raises: [EInvalidPeg]).}:
    pegs.peg(s)
