#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${LINKIT_VERSION:?Set LINKIT_VERSION, for example 0.4.0}"
BUILD_NUMBER="${LINKIT_BUILD:?Set LINKIT_BUILD, for example 4}"
ASSET_URL="${LINKIT_UPDATE_ASSET_URL:-}"

if [[ -z "$ASSET_URL" ]]; then
  BASE_URL="${LINKIT_UPDATE_ASSET_BASE_URL:-}"
  if [[ -z "$BASE_URL" ]]; then
    echo "Set LINKIT_UPDATE_ASSET_URL or LINKIT_UPDATE_ASSET_BASE_URL." >&2
    exit 1
  fi
  ASSET_URL="${BASE_URL%/}/linkit-macos.zip"
fi

export LINKIT_VERSION="$VERSION"
export LINKIT_BUILD="$BUILD_NUMBER"

APP_DIR="$("$ROOT/scripts/build-macos-app.sh" | tail -n 1)"
ZIP="$ROOT/dist/linkit-macos.zip"
MANIFEST="$ROOT/dist/linkit-macos-update.json"

/bin/rm -f "$ZIP" "$MANIFEST"
/usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP"
SHA256="$(/usr/bin/shasum -a 256 "$ZIP" | /usr/bin/awk '{print $1}')"

cat > "$MANIFEST" <<JSON
{
  "platform": "macos",
  "version": "$VERSION",
  "build": $BUILD_NUMBER,
  "url": "$ASSET_URL",
  "sha256": "$SHA256",
  "minimumSystemVersion": "13.0",
  "releaseNotes": ""
}
JSON

printf '%s\n%s\n' "$ZIP" "$MANIFEST"
