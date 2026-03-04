#!/bin/sh
set -e

# --- Detection ---
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$OS" in
  linux) OS_NAME="linux" ;;
  darwin) OS_NAME="macosx" ;;
  *) echo "Unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
  x86_64|amd64) ARCH_NAME="x64" ;;
  aarch64|arm64) ARCH_NAME="aarch64" ;;
  i386|i686) ARCH_NAME="x32" ;;
  armv7l) ARCH_NAME="armv7l" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# --- Find latest version ---
if [ -n "$GITHUB_TOKEN" ]; then
  RESPONSE=$(curl -s -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/repos/nim-lang/nimble/releases/latest)
else
  RESPONSE=$(curl -s https://api.github.com/repos/nim-lang/nimble/releases/latest)
fi

# Fallback for Apple Silicon if native arm64 build is not available in the release
if [ "$OS_NAME" = "macosx" ] && [ "$ARCH_NAME" = "aarch64" ]; then
  if ! echo "$RESPONSE" | grep -q "nimble-macosx_aarch64.tar.gz"; then
    ARCH_NAME="x64"
  fi
fi

VERSION=$(echo "$RESPONSE" | grep '"tag_name":' | cut -d '"' -f 4)

if [ -z "$VERSION" ]; then
  echo "Could not find latest version."
  if echo "$RESPONSE" | grep -q "rate limit exceeded"; then
    echo "GitHub API rate limit exceeded. Please set GITHUB_TOKEN to increase limits."
  fi
  exit 1
fi

ASSET_NAME="nimble-${OS_NAME}_${ARCH_NAME}.tar.gz"
DOWNLOAD_URL="https://github.com/nim-lang/nimble/releases/download/${VERSION}/${ASSET_NAME}"

# --- Setup ---
INSTALL_DIR="$HOME/.nimble/bin"
mkdir -p "$INSTALL_DIR"

TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"

# --- Download & Install ---
echo "Downloading Nimble ${VERSION} for ${OS_NAME} ${ARCH_NAME}..."
curl -L "$DOWNLOAD_URL" -o nimble.tar.gz

echo "Extracting..."
tar -xzf nimble.tar.gz

echo "Installing to $INSTALL_DIR..."
mv nimble "$INSTALL_DIR/nimble"
chmod +x "$INSTALL_DIR/nimble"

# --- Cleanup ---
cd - > /dev/null
rm -rf "$TMP_DIR"

# --- Success Message ---
echo ""
echo "Nimble installed successfully to $INSTALL_DIR/nimble"
echo ""
echo "Next steps:"
echo "1. Add Nimble to your PATH (if not already):"
echo "   export PATH="\$HOME/.nimble/bin:\$PATH""
echo "2. Install Nim globally:"
echo "   nimble install -g nim"
echo "3. (Optional) Set up development tools:"
echo "   nimble install -g nimlangserver nph"
echo ""
echo "Note: You may need to restart your terminal for PATH changes to take effect."
