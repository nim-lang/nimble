#!/bin/bash
# Prepopulates a package cache directory for faster test runs.
# Sets NIMBLE_PKGCACHE to the populated directory.
#
# Usage:
#   source tests/populate_cache.sh   # populates and exports NIMBLE_PKGCACHE
#   nimble cibenchmark               # tests use the fallback cache

set -e

CACHE_DIR="${NIMBLE_PKGCACHE:-/tmp/nimble_fallback_cache}"
mkdir -p "$CACHE_DIR"

# Helper: clone a package into the cache using nimble's naming convention.
# Args: url [dirSuffix]
# The dirSuffix is appended for versioned cache entries.
cache_clone() {
  local url="$1"
  local suffix="${2:-}"

  # Build directory name from URL (letters+digits only, matching getCacheDownloadDir)
  local hostname path dirName
  hostname=$(echo "$url" | sed -E 's|https?://||' | cut -d/ -f1 | tr -cd '[:alnum:]')
  path=$(echo "$url" | sed -E 's|https?://[^/]+||' | tr -cd '[:alnum:]')
  dirName="${hostname}_${path}"
  if [ -n "$suffix" ]; then
    dirName="${dirName}_${suffix}"
  fi

  local dest="$CACHE_DIR/$dirName"
  if [ -d "$dest" ] && [ -d "$dest/.git" ]; then
    echo "  [cached] $dirName"
    return
  fi

  echo "  [clone]  $dirName <- $url"
  rm -rf "$dest"
  git clone --depth 1 --config core.autocrlf=false --config core.eol=lf \
    --recurse-submodules -q "$url" "$dest" 2>/dev/null || {
    echo "  [FAIL]   $dirName"
    rm -rf "$dest"
  }
}

echo "=== Populating fallback cache: $CACHE_DIR ==="

# Core nimble-test packages (used across 7+ test files)
cache_clone "https://github.com/jmgomez/packagea.git"
cache_clone "https://github.com/jmgomez/packageb.git"
cache_clone "https://github.com/jmgomez/packagebin.git"
cache_clone "https://github.com/jmgomez/packagebin2.git"
cache_clone "https://github.com/nimble-test/multi"

# Commonly pulled transitive dependencies
cache_clone "https://github.com/GULPF/timezones"

# Heavy real-world packages (used in SAT/declarative/lock tests)
cache_clone "https://github.com/zedeus/nitter"
cache_clone "https://github.com/dom96/jester"
cache_clone "https://github.com/cheatfate/asynctools"
cache_clone "https://github.com/jiro4989/nimtetris"
cache_clone "https://github.com/dom96/httpbeast"

echo "=== Done: $(ls -d "$CACHE_DIR"/*/ 2>/dev/null | wc -l | tr -d ' ') packages cached ==="

export NIMBLE_PKGCACHE="$CACHE_DIR"
