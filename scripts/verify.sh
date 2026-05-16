#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT/macos"
swift test
swift build --product LinkitMacMenu

cd "$ROOT/android"
./gradlew testDebugUnitTest assembleDebug
