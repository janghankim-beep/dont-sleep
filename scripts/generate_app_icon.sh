#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/tools"
CLANG="${CLANG:-$(xcrun --find clang)}"
SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"
ARCH="$(uname -m)"

mkdir -p "$BUILD_DIR"

"$CLANG" \
  -fobjc-arc \
  -isysroot "$SDKROOT" \
  -arch "$ARCH" \
  -mmacosx-version-min=13.0 \
  -framework Cocoa \
  "$ROOT_DIR/scripts/generate_app_icon.m" \
  -o "$BUILD_DIR/generate_app_icon"

cd "$ROOT_DIR"
"$BUILD_DIR/generate_app_icon"
