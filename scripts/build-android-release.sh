#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT/android"
KEYSTORE="$ANDROID_DIR/linkit-release.keystore"
PROPS="$ANDROID_DIR/keystore.properties"
LOCAL_PROPS="$ANDROID_DIR/local.properties"
DIST="$ROOT/dist"
APK="$DIST/linkit-release.apk"

if [[ -z "${ANDROID_HOME:-}" && ! -f "$LOCAL_PROPS" ]]; then
  echo "Set ANDROID_HOME or create android/local.properties with sdk.dir=..." >&2
  exit 1
fi

if [[ ! -f "$LOCAL_PROPS" && -n "${ANDROID_HOME:-}" ]]; then
  printf 'sdk.dir=%s\n' "$ANDROID_HOME" > "$LOCAL_PROPS"
fi

if [[ ! -f "$KEYSTORE" ]]; then
  echo "Creating local release keystore at $KEYSTORE"
  keytool -genkey -v \
    -keystore "$KEYSTORE" \
    -alias linkit \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -storepass linkit \
    -keypass linkit \
    -dname "CN=Linkit, OU=Dev, O=Kalki, L=Local, ST=Local, C=US"
fi

if [[ ! -f "$PROPS" ]]; then
  cat > "$PROPS" <<'EOF'
storeFile=linkit-release.keystore
storePassword=linkit
keyAlias=linkit
keyPassword=linkit
EOF
fi

cd "$ANDROID_DIR"
./gradlew assembleRelease

mkdir -p "$DIST"
cp "$ANDROID_DIR/app/build/outputs/apk/release/app-release.apk" "$APK"

printf '%s\n' "$APK"
