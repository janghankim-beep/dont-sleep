#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$SCRIPT_DIR/dist/Don't Sleep.app"
BUILD_SCRIPT="$SCRIPT_DIR/scripts/build_app.sh"
HELPER_DEST="/Library/PrivilegedHelperTools/local.dontsleep.pmset-helper"

echo "Don't Sleep을 재시작합니다..."

if [[ ! -d "$APP_PATH" ]]; then
  echo "앱 번들이 없어 먼저 빌드합니다."
  "$BUILD_SCRIPT" >/dev/null
fi

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
    echo "기존 앱이 아직 종료되지 않아 새로 열지 않았습니다."
    echo "메뉴바에서 관리자 권한 확인 또는 오류 메시지를 확인하세요."
    exit 1
  fi
fi

/usr/bin/open "$APP_PATH"

echo "완료: 메뉴바의 노트북 아이콘을 확인하세요."
