# BSD License. Look at license.txt for more info.
#
# Various miscellaneous common types reside here, to avoid problems with
# recursive imports

type
  NimbleError* = object of Exception
  BuildFailed* = object of NimbleError
