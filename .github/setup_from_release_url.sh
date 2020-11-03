#!/usr/bin/env bash
#
#                Simple tool to setup a Nim environment
#                      Copyright (C) 2020 Leorize
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <https://www.gnu.org/licenses/>.

#----------------------------------------------------------
# This has been modified from github.com/alaviss/setup-nim
# to build from a particular commit instead of the latest
# devel branch.  Once alaviss/setup-nim supports building a
# particular commit, this can be removed in favor of using
# that.
#----------------------------------------------------------
set -eu
set -o pipefail

_releases_url=https://github.com/nim-lang/nightlies/releases
_download_url=$_releases_url/download

print-help() {
  cat <<EOF
Usage: $0 [option] archive-prefix release-url

Downloads and install the latest Nim nightly from a release URL.
The compiler can then be found in the 'bin' folder relative to the output
directory.

This script is tailored for CI use, as such it's very barebones and make
assumptions about the system such as having a working C compiler.

Options:
    -o dir     Set the output directory to 'dir'. The compiler will be
               extracted to this directory. Defaults to \$PWD/nim.
    -h         Print this help message.
EOF
}

get-archive-name() {
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
      arch=arm64
      ;;
    armv7l)
      arch=arm
      ;;
    i*86)
      arch=x32
      ;;
    x86_64)
      arch=x64
      ;;
  esac

  echo "${os}_$arch$ext"
}

has-release() {
  local url=$1
  curl -f -I "$_releases_url/$url" >/dev/null 2>&1
}

msg() {
  echo $'\e[1m\e[36m--\e[0m' "$@"
}

ok() {
  echo $'\e[1m\e[32m--\e[0m' "$@"
}

err() {
  echo $'\e[1m\e[31mError:\e[0m' "$@"
}

out=$PWD/nim
tag=
while getopts 'o:h' opt; do
  case "$opt" in
    'o')
      out=$OPTARG
      ;;
    'h')
      print-help
      exit 0
      ;;
    *)
      print-help
      exit 1
      ;;
  esac
done
unset opt

shift $((OPTIND - 1))
[[ $# -gt 0 ]] && prefix=$1 && tag=$2
if [[ -z "$prefix" ]] || [[ -z "$tag" ]]; then
  print-help
  exit 1
fi

mkdir -p "$out"
cd "$out"

if has-release "$tag"; then
  archive="$prefix-$(get-archive-name)"
  url="$_download_url/$tag/$archive"
  msg "Downloading prebuilt archive '$archive' for tag '$tag' from '$url'"
  if ! curl -f -LO "$url"; then
    err "Archive '$archive' could not be found and/or downloaded. Maybe your OS/architecture does not have any prebuilt available?"
    exit 1
  fi
  msg "Extracing '$archive'"
  if [[ $archive == *.zip ]]; then
    # Create a temporary directory
    tmpdir=$(mktemp -d)
    # extract archive to temporary dir
    7z x "$archive" "-o$tmpdir"
    # collect the extracted file names
    extracted=( "$tmpdir"/* )
    # use the first name collected, which should be the nim-<version> folder.
    # This allows us to strip the first component of the path.
    mv "${extracted[0]}/"* .
    # remove the temporary dir afterwards
    rm -rf "$tmpdir"
    unset tmpdir
  else
    tar -xf "$archive" --strip-components 1
  fi
else
  err "Could not find any release at '$tag'."
  exit 1
fi

ok "Installation to '$PWD' completed! The compiler and associated tools can be found at '$PWD/bin'"
