#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PREVIEW_HOME="$ROOT/.harness-preview"
APP="$PREVIEW_HOME/HarnessPreview.app"
mkdir -p "$PREVIEW_HOME"

echo "Building debug preview..."
swift build --product Harness
swift build --product HarnessDaemon
swift build --product harness-cli

BUILD_DIR="$ROOT/.build/debug"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$ROOT/.build/debug/Harness" "$APP/Contents/MacOS/Harness"
cp "$ROOT/.build/debug/HarnessDaemon" "$APP/Contents/MacOS/HarnessDaemon"
cp "$ROOT/.build/debug/harness-cli" "$APP/Contents/MacOS/harness-cli"
chmod +x "$APP/Contents/MacOS/"*
for bundle in "$BUILD_DIR"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
FRAMEWORK="$BUILD_DIR/Sparkle.framework"
if [[ ! -d "$FRAMEWORK" ]]; then
  FRAMEWORK="$(find "$ROOT/.build/artifacts" "$ROOT/.build" -name Sparkle.framework -type d 2>/dev/null | head -n1 || true)"
fi
if [[ -z "$FRAMEWORK" || ! -d "$FRAMEWORK" ]]; then
  echo "error: Sparkle.framework not found under .build — build the Harness product first." >&2
  exit 1
fi
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP/Contents/MacOS/Harness" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Harness"
fi
if [[ -f "$ROOT/Apps/Harness/Resources/Harness.icns" ]]; then
  cp "$ROOT/Apps/Harness/Resources/Harness.icns" "$APP/Contents/Resources/Harness.icns"
fi
if [[ -f "$ROOT/Apps/Harness/Resources/HarnessLogo.png" ]]; then
  cp "$ROOT/Apps/Harness/Resources/HarnessLogo.png" "$APP/Contents/Resources/HarnessLogo.png"
fi
# Bundled "Symbols Nerd Font Mono" (MIT) — auto-activated via ATSApplicationFontsPath below
# so Nerd Font / Powerline glyphs render in the preview too.
if [[ -d "$ROOT/Apps/Harness/Resources/Fonts" ]]; then
  ditto "$ROOT/Apps/Harness/Resources/Fonts" "$APP/Contents/Resources/Fonts"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Harness</string>
  <key>CFBundleIconFile</key>
  <string>Harness</string>
  <key>CFBundleIdentifier</key>
  <string>com.robert.harness.preview</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Harness Preview</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.0.0-preview</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>ATSApplicationFontsPath</key>
  <string>Fonts</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>HarnessPreviewHome</key>
  <string>$PREVIEW_HOME</string>
</dict>
</plist>
PLIST

codesign --force --sign - --deep "$APP" >/dev/null

cat <<EOF

Launching Harness preview.
State directory:
  $PREVIEW_HOME

This does not install Harness, create a DMG, or write to:
  ~/Library/Application Support/Harness

Preview CLI while it is running:
  HARNESS_HOME="$PREVIEW_HOME" "$ROOT/.build/debug/harness-cli" ping

EOF

open -n "$APP"
