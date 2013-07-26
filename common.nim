# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import os, osproc

type
  EBabel* = object of EBase

proc copyFileD*(fro, to: string) =
  echo(fro, " -> ", to)
  copyFile(fro, to)

proc copyDirD*(fro, to: string) =
  echo(fro, " -> ", to)
  copyDir(fro, to)