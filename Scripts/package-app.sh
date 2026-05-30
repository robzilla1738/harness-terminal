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

# Transparent brand logo for onboarding + settings (loaded via Bundle.main).
LOGO="$ROOT/Apps/Harness/Resources/HarnessLogo.png"
if [[ -f "$LOGO" ]]; then
  cp "$LOGO" "$APP/Contents/Resources/HarnessLogo.png"
fi

chmod +x "$APP/Contents/MacOS/"*

echo "Created $APP"
