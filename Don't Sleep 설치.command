#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Don't Sleep을 응용 프로그램 폴더에 설치합니다..."
"$SCRIPT_DIR/scripts/install_app.sh"
echo "설치 완료: /Applications/Don't Sleep.app"
