import std/os


template withDir*(dir: string, body: untyped): untyped =
  ## Changes the current directory to `dir` temporarily.
  ## Usage example:
  ##
  ## .. code-block:: nim
  ##   withDir "foo":
  ##     # inside foo directory
  ##   # back to last directory
  let curDir = getCurrentDir()
  try:
    setCurrentDir(dir)
    body
  finally:
    setCurrentDir(curDir)
