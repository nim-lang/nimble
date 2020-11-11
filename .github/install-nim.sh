#!/bin/bash
# Heavily borrowed from https://github.com/alaviss/setup-nim/blob/master/setup.sh
# So I guess that makes this GPL?  Can someone add a license here if it's needed.

usage() {
  cat <<EOF
This script will install Nim for GitHub Actions from a variety of
sources.  Provide a single command-line argument of the following
format:

  From source by downloading a tarball:

    $0 sourcetar:https://github.com/nim-lang/nightlies/releases/download/latest-version-1-0/source.tar.xz
  
  From a published release version:

    $0 release:1.4.0
  
  From a prebuilt nightly binary:
  
    $0 nightly:https://github.com/nim-lang/nightlies/releases/latest-version-1-0/
    $0 nightly:https://github.com/nim-lang/nightlies/releases/tag/2020-10-26-version-1-0-0ca09f64cf6ecf2050b58bc26ebc622f856b4dc2
  
  From a specific Git SHA or branch of the github.com/nim-lang/Nim.git repo:
  
    $0 git:2382937843092342342556456
    $0 git:devel

Set NIMDIR=path/where/nim/will/be
EOF
}
set +x
NIMDIR=${NIMDIR:-nim}

guess_archive_name() {
  # Guess the archive name 
  local ext=.tar.xz
  local os; os=$(uname)
  os=$(tr '[:upper:]' '[:lower:]' <<< "$os")
  case "$os" in
    'darwin')
      os=macosx
      ;;
    'windows_nt'|mingw*)
      os=windows
      ext=.zip
      ;;
  esac
  local arch; arch=$(uname -m)
  case "$arch" in
    aarch64)
      arch=arm64 ;;
    armv7l)
      arch=arm ;;
    i*86)
      arch=x32 ;;
    x86_64)
      arch=x64 ;;
  esac
  echo "${os}_${arch}${ext}"
}

unpack_prebuilt() {
  archive_url=$1
  archive_name=${archive_url##*/}
  echo "archive name: $archive_name"

  echo "Creating output dir..."
  mkdir -p "$NIMDIR"
  cd "$NIMDIR"

  echo "Downloading $archive_url ..."
  if ! curl -f -LO "$archive_url"; then
    echo "Failed to download"
    exit 1
  fi
  echo "Extracting $archive_name to $(pwd)"
  if [[ $archive_name == *.zip ]]; then
    tmpdir=$(mktemp -d)
    7z x "$archive_name" "-o$tmpdir"
    extracted=( "$tmpdir"/* )
    mv "${extracted[0]}/"* .
    rm -rf "$tmpdir"
    unset tmpdir
  else
    tar -xf "$archive_name" --strip-components 1
  fi
}

build_nim() {
  if [ -e build.sh ]; then
    sh build.sh
  else
    sh build_all.sh
  fi
  bin/nim c koch
  ./koch boot -d:release
}

#------------------------------------------------
# Install a published released version of Nim
#------------------------------------------------
install_release() {
  version=$1
  echo "Installing Nim ${version}"
  local os; os=$(uname)
  if [ "$os" == "Darwin" ]; then
    # macos: install from source
    install_sourcetar "https://nim-lang.org/download/nim-${version}.tar.xz"
  elif [ "$os" == "Linux" ]; then
    # linux: install from binary
    archive_name=$(guess_archive_name)
    echo "Archive pattern: $archive_name"
    url="https://nim-lang.org/download/nim-${version}-${archive_name}"
    echo "Guessed URL: $url"
    unpack_prebuilt "$url"
  else
    # windows: install from binary
    archive_name=$(guess_archive_name)
    if echo "$archive_name" | grep x64; then
      url="https://nim-lang.org/download/nim-${version}_x64.zip"
    else
      url="https://nim-lang.org/download/nim-${version}_x32.zip"
    fi
    echo "Guessed URL: $url"
    unpack_prebuilt "$url"
  fi
}

#------------------------------------------------
# Install from a git SHA/branch
#------------------------------------------------
install_git() {
  shalike=$1
  echo "Installing from Git: ${shalike}"
  git clone -n https://github.com/nim-lang/Nim.git "$NIMDIR"
  cd "$NIMDIR"
  git checkout "$shalike"
  ls -al
  build_nim
}

#------------------------------------------------
# Install from a source tarball URL
#------------------------------------------------
install_sourcetar() {
  tarurl=$1
  echo "Installing from source: $tarurl"
  curl -L -o source.tar.xz "$tarurl"
  mkdir -p nimtmp
  tar xf source.tar.xz -C nimtmp
  cd nimtmp
  mv $(ls) "../$NIMDIR"
  cd ..
  rm source.tar.xz
  rm -r nimtmp
  cd "$NIMDIR"
  build_nim
}

#------------------------------------------------
# Install nightly prebuild binaries
# from a GitHub release URL
#------------------------------------------------
install_nightly() {
  url=${1%/}
  echo "Installing prebuilt binaries from: $url"
  archive_name=$(guess_archive_name)
  echo "Archive pattern: $archive_name"
  local archive_url; archive_url=
  tag=${url##*/}
  echo "tag: $tag"
  archive_url=$(curl -H "Accept: application/vnd.github.v3+json" "https://api.github.com/repos/nim-lang/nightlies/releases/tags/$tag" | grep '"browser_download_url"' | grep "$archive_name" | head -n1 | cut -d'"' -f4)
  if [ -z "$archive_url" ]; then
    echo "ERROR: unable to find archive for $archive_name"
    exit 1
  fi
  echo "archive url: $archive_url"
  unpack_prebuilt "$archive_url"
}

#------------------------------------------------
# main
#------------------------------------------------
set -e
TARGET=$1
if [ -z "$TARGET" ]; then
  usage
  exit 1
fi

install_type=$(echo "$TARGET" | cut -d: -f1)
install_arg=$(echo "$TARGET" | cut -d: -f2-)

#------------------------------------------------
# Install Nim
#------------------------------------------------
echo "Installing Nim into dir: $NIMDIR"
echo "Install type: $install_type"
echo "       param: $install_arg"
(install_${install_type} "${install_arg}")

#------------------------------------------------
# Set up PATH
#------------------------------------------------
if [ -z "$GITHUB_PATH" ]; then
  echo "Not setting up PATH since GITHUB_PATH is not defined"
else
  echo "Setting up PATH"
  abspath() {
    python -c "import os; import sys; print(os.path.realpath(sys.argv[1]))" "$1"
  }
  add-path() {
    echo "$1" >> "$GITHUB_PATH"
    echo "Directory '$1' has been added to PATH."
  }
  add-path "$(abspath "$NIMDIR/bin")"
  add-path "$(pwd)/$NIMDIR/bin"
  add-path "$HOME/.nimble/bin"
fi
