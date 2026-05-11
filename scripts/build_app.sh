#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Don't Sleep"
BUNDLE_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
HELPER_RESOURCES_DIR="$CONTENTS_DIR/Library/PrivilegedHelperTools"

cd "$ROOT_DIR"

BUILD_DIR="$ROOT_DIR/.build/release"
BIN_PATH="$BUILD_DIR/DontSleep"
HELPER_BIN_PATH="$BUILD_DIR/DontSleepPmsetHelper"
CLANG="${CLANG:-$(xcrun --find clang)}"
SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"
ARCH="$(uname -m)"

mkdir -p "$BUILD_DIR"

if [[ ! -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  "$ROOT_DIR/scripts/generate_app_icon.sh" >/dev/null
fi

"$CLANG" \
  -fobjc-arc \
  -isysroot "$SDKROOT" \
  -arch "$ARCH" \
  -mmacosx-version-min=13.0 \
  -framework Cocoa \
  -framework IOKit \
  "$ROOT_DIR/Sources/DontSleep/main.m" \
  -o "$BIN_PATH"

"$CLANG" \
  -isysroot "$SDKROOT" \
  -arch "$ARCH" \
  -mmacosx-version-min=13.0 \
  "$ROOT_DIR/Sources/DontSleepHelper/main.c" \
  -o "$HELPER_BIN_PATH"

/usr/bin/codesign --force --sign - "$HELPER_BIN_PATH" >/dev/null 2>&1 || true

rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$HELPER_RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/DontSleep"
cp "$HELPER_BIN_PATH" "$HELPER_RESOURCES_DIR/local.dontsleep.pmset-helper"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi
if [[ -f "$ROOT_DIR/Resources/MenuBarIcon.svg" ]]; then
  cp "$ROOT_DIR/Resources/MenuBarIcon.svg" "$RESOURCES_DIR/MenuBarIcon.svg"
fi
if [[ -f "$ROOT_DIR/Resources/MenuBarIconOn.svg" ]]; then
  cp "$ROOT_DIR/Resources/MenuBarIconOn.svg" "$RESOURCES_DIR/MenuBarIconOn.svg"
fi
chmod +x "$MACOS_DIR/DontSleep"
chmod +x "$HELPER_RESOURCES_DIR/local.dontsleep.pmset-helper"

/usr/bin/codesign --force --deep --sign - "$BUNDLE_DIR" >/dev/null 2>&1 || true

echo "$BUNDLE_DIR"
