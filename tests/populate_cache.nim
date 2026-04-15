## Prepopulates a package cache directory for faster test runs.
## Uses nimble's getCacheDownloadDir to compute cache directory names,
## ensuring the naming stays in sync with nimble's download logic.
##
## Usage:
##   nim c -r tests/populate_cache.nim [cacheDir]
##   # Default cacheDir: /tmp/nimble_fallback_cache

import os, osproc, strutils
import ../src/nimblepkg/nimblesat
import ../src/nimblepkg/options
import ../src/nimblepkg/version

const packages = [
  # Core test packages (used across 7+ test files)
  "https://github.com/jmgomez/packagea.git",
  "https://github.com/jmgomez/packageb.git",
  "https://github.com/jmgomez/packagebin.git",
  "https://github.com/jmgomez/packagebin2.git",
  "https://github.com/nimble-test/multi",
  # Commonly pulled transitive dependencies
  "https://github.com/GULPF/timezones",
  # Heavy real-world packages (used in SAT/declarative/lock tests)
  "https://github.com/zedeus/nitter",
  "https://github.com/dom96/jester",
  "https://github.com/cheatfate/asynctools",
  "https://github.com/jiro4989/nimtetris",
  "https://github.com/dom96/httpbeast",
]

proc main() =
  let cacheDir = if paramCount() >= 1: paramStr(1)
                 else: "/tmp/nimble_fallback_cache"
  createDir(cacheDir)

  var options = Options()
  options.pkgCachePath = cacheDir

  let verRange = VersionRange(kind: verAny)

  echo "=== Populating fallback cache: ", cacheDir, " ==="
  var count = 0
  for url in packages:
    let destDir = getCacheDownloadDir(url, verRange, options)
    if dirExists(destDir) and dirExists(destDir / ".git"):
      echo "  [cached] ", destDir.splitPath.tail
      inc count
      continue

    echo "  [clone]  ", destDir.splitPath.tail, " <- ", url
    removeDir(destDir)
    let (output, exitCode) = execCmdEx(
      "git clone --config core.autocrlf=false --config core.eol=lf " &
      "--recurse-submodules -q " & quoteShell(url) & " " & quoteShell(destDir))
    if exitCode != 0:
      echo "  [FAIL]   ", destDir.splitPath.tail
      if output.len > 0: echo "           ", output.strip
      removeDir(destDir)
    else:
      inc count

  echo "=== Done: ", count, " packages cached ==="

when isMainModule:
  main()
