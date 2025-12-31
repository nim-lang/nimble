import compat/pegs, std/strutils

proc isURL*(name: string): bool =
  name.startsWith(peg" @'://' ") or name.startsWith(peg"\ident+'@'@':'.+")

proc modifyUrl*(url: string, usingHttps: bool): string =
  result =
    if url.startsWith("git://") and usingHttps:
      "https://" & url[6 .. ^1]
    else:
      url
  # Fixes issue #204
  # github + https + trailing url slash causes a
  # checkout/ls-remote to fail with Repository not found
  if result.contains("github.com") and result.endswith("/"):
    result = result[0 .. ^2]

proc isFileURL*(name: string): bool =
  name.startsWith("file://")

proc extractFilePathFromURL*(url: string): string =
  ## Extracts the file path from a file:// URL
  ## e.g., "file:///path/to/package" -> "/path/to/package"
  ##       "file://./relative/path" -> "./relative/path"
  if url.isFileURL:
    result = url[7..^1]  # Remove "file://" prefix
  else:
    raise newException(ValueError, "Not a file:// URL: " & url)