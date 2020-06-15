# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import strutils

type
  NimbleLink* = object
    nimbleFilePath*: string
    packageDir*: string

const
  nimbleLinkFileExt* = ".nimble-link"

proc readNimbleLink*(nimbleLinkPath: string): NimbleLink =
  let s = readFile(nimbleLinkPath).splitLines()
  result.nimbleFilePath = s[0]
  result.packageDir = s[1]
