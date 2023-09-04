## Compatibility pragmas for keeping up with Nim's evolution.
## This is an ``include`` file, do not ``import`` it!

when (NimMajor, NimMinor) < (1, 2):
  # ARC/ORC related pragmas:
  {.pragma: cursor.}
  {.pragma: nosinks.}

  # DrNim related pragmas:
  {.pragma: assert.}
  {.pragma: assume.}
  {.pragma: requires.}
  {.pragma: ensures.}
  {.pragma: invariant.}


