#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${APP_DIR:-$ROOT/dist/telegent.app}"
CORE_DST="$APP_DIR/Contents/MacOS/telegent-core"
TMP_BIN="$ROOT/.telegent-core.tmp"

if [[ ! -d "$APP_DIR" ]]; then
  echo "App bundle not found: $APP_DIR"
  echo "Run scripts/build_macos_app.sh once first."
  exit 1
fi

if [[ ! -f "$CORE_DST" ]]; then
  echo "Core target not found: $CORE_DST"
  exit 1
fi

cd "$ROOT"
go build -o "$TMP_BIN" ./cmd/telegent
install -m 755 "$TMP_BIN" "$CORE_DST"
rm -f "$TMP_BIN"

if [[ "${ENABLE_CODESIGN:-0}" == "1" ]]; then
  SIGN_ID="${CODESIGN_IDENTITY:--}"
  codesign --force --sign "$SIGN_ID" "$CORE_DST"
  echo "Re-signed core with identity: $SIGN_ID"
fi

echo "Updated core only:"
echo "  $CORE_DST"
echo "Main app bundle unchanged:"
echo "  $APP_DIR"
