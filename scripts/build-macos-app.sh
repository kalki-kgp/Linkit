#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS_DIR="$ROOT/macos"
APP_DIR="$ROOT/dist/Linkit.app"
CONTENTS="$APP_DIR/Contents"
MACOS_BIN="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICON_SOURCE="$MACOS_DIR/Resources/Linkit.icns"
VERSION="${LINKIT_VERSION:-0.3.0}"
BUILD_NUMBER="${LINKIT_BUILD:-3}"
UPDATE_MANIFEST_URL="${LINKIT_UPDATE_MANIFEST_URL:-https://github.com/kalki-kgp/Linkit/releases/latest/download/linkit-macos-update.json}"

xml_escape() {
  printf '%s' "$1" \
    | sed \
      -e 's/&/\&amp;/g' \
      -e 's/</\&lt;/g' \
      -e 's/>/\&gt;/g' \
      -e 's/"/\&quot;/g' \
      -e "s/'/\&apos;/g"
}

UPDATE_MANIFEST_URL_XML="$(xml_escape "$UPDATE_MANIFEST_URL")"

cd "$MACOS_DIR"
swift build -c release --product LinkitMacMenu

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Missing macOS icon: $ICON_SOURCE" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_BIN" "$RESOURCES"
cp "$MACOS_DIR/.build/release/LinkitMacMenu" "$MACOS_BIN/Linkit"
cp "$ICON_SOURCE" "$RESOURCES/Linkit.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
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
  <key>CFBundleIconFile</key>
  <string>Linkit</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LinkitUpdateManifestURL</key>
  <string>$UPDATE_MANIFEST_URL_XML</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Linkit uses Bluetooth to route phone call audio to your Mac speakers and microphone.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Linkit receives files from your paired Android device on your local network.</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_linkit._tcp</string>
  </array>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
</dict>
</plist>
PLIST

# Ad-hoc code signature (free; no Apple Developer ID required).
# This does NOT notarize the app, so Gatekeeper still warns on first open of a
# downloaded copy (see docs/SETUP.md). It DOES give the bundle a stable code
# identity — steadier Keychain ACLs and Local Network permission, and it avoids
# the "app is damaged" hard-fail that unsigned bundles can hit. Diagnostics go to
# stderr so stdout stays just the app path for callers.
codesign --force --sign - "$APP_DIR" 1>&2
codesign --verify --strict "$APP_DIR" 1>&2
echo "ad-hoc signed $APP_DIR" 1>&2

printf '%s\n' "$APP_DIR"
