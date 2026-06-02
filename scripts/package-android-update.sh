#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_NAME="${LINKIT_ANDROID_VERSION_NAME:-${LINKIT_VERSION:?Set LINKIT_VERSION or LINKIT_ANDROID_VERSION_NAME, for example 0.2.0}}"
VERSION_CODE="${LINKIT_ANDROID_VERSION_CODE:-${LINKIT_VERSION_CODE:?Set LINKIT_VERSION_CODE or LINKIT_ANDROID_VERSION_CODE, for example 2}}"
ASSET_URL="${LINKIT_ANDROID_UPDATE_ASSET_URL:-}"

if [[ -z "$ASSET_URL" ]]; then
  BASE_URL="${LINKIT_ANDROID_UPDATE_ASSET_BASE_URL:-}"
  if [[ -z "$BASE_URL" ]]; then
    echo "Set LINKIT_ANDROID_UPDATE_ASSET_URL or LINKIT_ANDROID_UPDATE_ASSET_BASE_URL." >&2
    exit 1
  fi
  ASSET_URL="${BASE_URL%/}/linkit-release.apk"
fi

export LINKIT_ANDROID_VERSION_NAME="$VERSION_NAME"
export LINKIT_ANDROID_VERSION_CODE="$VERSION_CODE"

APK="$("$ROOT/scripts/build-android-release.sh" | tail -n 1)"
MANIFEST="$ROOT/dist/linkit-android-update.json"
SHA256="$(/usr/bin/shasum -a 256 "$APK" | /usr/bin/awk '{print $1}')"

cat > "$MANIFEST" <<JSON
{
  "platform": "android",
  "versionName": "$VERSION_NAME",
  "versionCode": $VERSION_CODE,
  "url": "$ASSET_URL",
  "sha256": "$SHA256",
  "releaseNotes": ""
}
JSON

printf '%s\n%s\n' "$APK" "$MANIFEST"
