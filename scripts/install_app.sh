#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Don't Sleep"
SOURCE_APP="$ROOT_DIR/dist/$APP_NAME.app"
DEST_APP="/Applications/$APP_NAME.app"
HELPER_NAME="local.dontsleep.pmset-helper"
HELPER_SOURCE="$ROOT_DIR/.build/release/DontSleepPmsetHelper"
HELPER_DEST="/Library/PrivilegedHelperTools/$HELPER_NAME"

"$ROOT_DIR/scripts/build_app.sh" >/dev/null

install_helper_if_needed() {
  local needs_install=1

  if [[ -f "$HELPER_DEST" ]] && /usr/bin/cmp -s "$HELPER_SOURCE" "$HELPER_DEST"; then
    local owner mode
    owner="$(/usr/bin/stat -f '%Su:%Sg' "$HELPER_DEST" 2>/dev/null || true)"
    mode="$(/usr/bin/stat -f '%Mp%Lp' "$HELPER_DEST" 2>/dev/null || true)"
    if [[ "$owner" == "root:wheel" && "$mode" == "4755" ]]; then
      needs_install=0
    fi
  fi

  if [[ "$needs_install" -eq 0 ]]; then
    return
  fi

  echo "최초 1회 관리자 권한으로 Don't Sleep helper를 설치합니다."
  echo "이후 켜짐/꺼짐 전환은 암호 입력 없이 동작합니다."
  /usr/bin/sudo /bin/mkdir -p /Library/PrivilegedHelperTools
  /usr/bin/sudo /usr/bin/install -o root -g wheel -m 4755 "$HELPER_SOURCE" "$HELPER_DEST"
}

install_helper_if_needed

if /usr/bin/pgrep -x DontSleep >/dev/null 2>&1; then
  if [[ -x "$HELPER_DEST" ]]; then
    "$HELPER_DEST" disable >/dev/null 2>&1 || true
  fi

  /usr/bin/osascript -e 'tell application id "local.dontsleep.menubar" to quit' >/dev/null 2>&1 || true

  for _ in {1..80}; do
    if ! /usr/bin/pgrep -x DontSleep >/dev/null 2>&1; then
      break
    fi
    /bin/sleep 0.25
  done

  if /usr/bin/pgrep -x DontSleep >/dev/null 2>&1; then
    echo "기존 앱이 아직 종료되지 않아 설치를 중단합니다."
    echo "메뉴바에서 관리자 권한 확인 또는 오류 메시지를 확인하세요."
    exit 1
  fi
fi

if [[ -d "$DEST_APP" ]]; then
  rm -rf "$DEST_APP"
fi

cp -R "$SOURCE_APP" "$DEST_APP"
xattr -dr com.apple.quarantine "$DEST_APP" >/dev/null 2>&1 || true
open "$DEST_APP"

echo "$DEST_APP"
