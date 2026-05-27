#!/usr/bin/env bash
set -euo pipefail
CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP="$ROOT/Harness.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BUILD_DIR/Harness" "$APP/Contents/MacOS/Harness"
cp "$BUILD_DIR/HarnessDaemon" "$APP/Contents/MacOS/HarnessDaemon"
cp "$BUILD_DIR/harness-cli" "$APP/Contents/MacOS/harness-cli"
cp "$ROOT/Apps/Harness/Sources/HarnessApp/Resources/Info.plist" "$APP/Contents/Info.plist"

ICON="$ROOT/Apps/Harness/Resources/Harness.icns"
if [[ ! -f "$ICON" ]]; then
  "$ROOT/Scripts/generate-app-icon.sh"
fi
cp "$ICON" "$APP/Contents/Resources/Harness.icns"

chmod +x "$APP/Contents/MacOS/"*

echo "Created $APP"
