#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS_DIR="$ROOT/macos"
APP_DIR="$ROOT/dist/Linkit.app"
CONTENTS="$APP_DIR/Contents"
MACOS_BIN="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

cd "$MACOS_DIR"
swift build -c release --product LinkitMacMenu

rm -rf "$APP_DIR"
mkdir -p "$MACOS_BIN" "$RESOURCES"
cp "$MACOS_DIR/.build/release/LinkitMacMenu" "$MACOS_BIN/Linkit"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Linkit</string>
  <key>CFBundleIdentifier</key>
  <string>tech.kalkikgp.Linkit</string>
  <key>CFBundleName</key>
  <string>Linkit</string>
  <key>CFBundleDisplayName</key>
  <string>Linkit</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2.0</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Linkit receives files from your paired Android device on your local network.</string>
</dict>
</plist>
PLIST

echo "$APP_DIR"
