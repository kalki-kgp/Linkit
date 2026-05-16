#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$("$ROOT/scripts/build-macos-app.sh" | tail -n 1)"
TARGET="/Applications/Linkit.app"

rm -rf "$TARGET"
cp -R "$APP_DIR" "$TARGET"

echo "$TARGET"
