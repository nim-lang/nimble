import std/pegs, std/strutils

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
