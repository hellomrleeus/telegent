#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="telegent.app"
OUT_DIR="$ROOT/dist"
APP_DIR="$OUT_DIR/$APP_NAME"
MACOS="$APP_DIR/Contents/MacOS"
RES="$APP_DIR/Contents/Resources"
VERSION_FILE="$ROOT/VERSION"
APP_VERSION="0.1.0"
if [[ -f "$VERSION_FILE" ]]; then
  APP_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
fi
if [[ -z "$APP_VERSION" ]]; then
  APP_VERSION="0.1.0"
fi
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

cd "$ROOT"
mkdir -p "$OUT_DIR"
rm -rf "$APP_DIR"
go build -o telegent ./cmd/telegent

mkdir -p "$MACOS" "$RES"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>telegent</string>
  <key>CFBundleExecutable</key>
  <string>telegent</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.xlee.telegent</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>telegent</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

clang -fobjc-arc "$ROOT/app/telegent/main.m" -framework Cocoa -framework AVFoundation -framework ApplicationServices -o "$MACOS/telegent"
cp "$ROOT/telegent" "$MACOS/telegent-core"
cp "$ROOT/scripts/transcribe_faster_whisper.py" "$MACOS/transcribe_faster_whisper.py"
rm -f "$ROOT/telegent"

chmod +x "$MACOS/telegent" "$MACOS/telegent-core" "$MACOS/transcribe_faster_whisper.py"

if [[ -f "$ROOT/images/AppIcon.icns" ]]; then
  cp "$ROOT/images/AppIcon.icns" "$RES/AppIcon.icns"
fi
for icon in status-icon-running.png status-icon-running@2x.png status-icon-stopped.png status-icon-stopped@2x.png status-icon-error.png status-icon-error@2x.png; do
  if [[ -f "$ROOT/images/$icon" ]]; then
    cp "$ROOT/images/$icon" "$RES/$icon"
  fi
done

xattr -cr "$APP_DIR"
if [[ "${ENABLE_CODESIGN:-0}" == "1" ]]; then
  codesign --force --deep -s - "$APP_DIR"
fi

echo "Built: $APP_DIR"
echo "Version: ${APP_VERSION} (${BUILD_NUMBER})"
