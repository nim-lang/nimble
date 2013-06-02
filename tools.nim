# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.
#
# Various miscellaneous utility functions reside here.
import osproc, pegs, strutils, os
import version

proc getNimrodVersion*: TVersion =
  let vOutput = execProcess("nimrod -v")
  var matches: array[0..MaxSubpatterns, string]
  if vOutput.find(peg"'Version'\s{(\d\.)+\d}", matches) == -1:
    quit("Couldn't find Nimrod version.", QuitFailure)
  newVersion(matches[0])

proc samePaths*(p1, p2: string): bool =
  ## Normalizes path (by adding a trailing slash) and compares.
  let cp1 = if not p1.endsWith("/"): p1 & "/" else: p1
  let cp2 = if not p2.endsWith("/"): p2 & "/" else: p2
  return cmpPaths(cp1, cp2) == 0

proc changeRoot*(origRoot, newRoot, path: string): string =
  ## origRoot: /home/dom/
  ## newRoot:  /home/test/
  ## path:     /home/dom/bar/blah/2/foo.txt
  ## Return value -> /home/test/bar/blah/2/foo.txt
  if path.startsWith(origRoot):
    return newRoot / path[origRoot.len .. -1]
  else:
    raise newException(EInvalidValue,
      "Cannot change root of path: Path does not begin with original root.")