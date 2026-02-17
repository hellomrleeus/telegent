#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${APP_DIR:-$ROOT/dist/telegent.app}"
APP_BIN="$APP_DIR/Contents/MacOS/telegent"

if [[ ! -d "$APP_DIR" ]]; then
  echo "App bundle not found: $APP_DIR"
  exit 1
fi

if [[ ! -x "$APP_BIN" ]]; then
  echo "App executable not found: $APP_BIN"
  exit 1
fi

if pgrep -f "$APP_BIN" >/dev/null 2>&1; then
  pkill -f "$APP_BIN" || true
  sleep 1
fi

open "$APP_DIR"
sleep 2

echo "Running processes:"
pgrep -af "$APP_DIR/Contents/MacOS/telegent" || true
