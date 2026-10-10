#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PREVIEW_HOME="${HARNESS_PREVIEW_HOME:-$ROOT/.harness-preview}"
PREVIEW_BUNDLE_ID="${HARNESS_PREVIEW_BUNDLE_ID:-com.robert.harness.preview}"
FINAL_APP="$PREVIEW_HOME/HarnessPreview.app"
mkdir -p "$PREVIEW_HOME"
STAGE_ROOT="$(mktemp -d "$PREVIEW_HOME/.HarnessPreview.XXXXXX")"
APP="$STAGE_ROOT/HarnessPreview.app"
trap 'rm -rf "$STAGE_ROOT"' EXIT

# Stop any GUI instance launched by a previous `make preview`. We use `open -n` below (a fresh
# instance every time), so without this each run would stack another preview app — each with its
# own status item and its own window list — making visual testing unreliable (e.g. a menu click
# can't deminiaturize a window owned by a different instance). The daemon is left running so
# sessions persist across rebuilds.
PREVIEW_MATCH="$(python3 -c 'import os,re,sys; paths={sys.argv[1], os.path.realpath(sys.argv[1])}; print("^(" + "|".join(re.escape(path) for path in sorted(paths)) + ")( |$)")' "$FINAL_APP/Contents/MacOS/Harness")"
pkill -f "$PREVIEW_MATCH" 2>/dev/null || true

echo "Building debug preview..."
swift build --product Harness
swift build --product HarnessSessionHost
swift build --product HarnessDaemon
swift build --product harness-cli

BUILD_DIR="$(swift build --show-bin-path)"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BUILD_DIR/Harness" "$APP/Contents/MacOS/Harness"
cp "$BUILD_DIR/HarnessSessionHost" "$APP/Contents/MacOS/HarnessSessionHost"
cp "$BUILD_DIR/HarnessDaemon" "$APP/Contents/MacOS/HarnessDaemon"
cp "$BUILD_DIR/harness-cli" "$APP/Contents/MacOS/harness-cli"
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
python3 - "$APP/Contents/Info.plist" "$PREVIEW_BUNDLE_ID" "$PREVIEW_HOME" <<'PYPLIST'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({
        'CFBundleDevelopmentRegion': 'en', 'CFBundleExecutable': 'Harness',
        'CFBundleIconFile': 'Harness', 'CFBundleIdentifier': sys.argv[2],
        'CFBundleInfoDictionaryVersion': '6.0', 'CFBundleName': 'Harness Preview',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.0.0-preview',
        'CFBundleVersion': '1', 'LSMinimumSystemVersion': '15.0',
        'NSHighResolutionCapable': True, 'ATSApplicationFontsPath': 'Fonts',
        'NSPrincipalClass': 'NSApplication', 'HarnessPreviewHome': sys.argv[3],
    }, output)
PYPLIST

python3 "$ROOT/Scripts/package-macos-tools.py" "$APP"

if [[ -n "${HARNESS_PREVIEW_SIGNING_IDENTITY:-}" ]]; then
  HARNESS_SIGNING_APP="$APP" SIGNING_IDENTITY="$HARNESS_PREVIEW_SIGNING_IDENTITY" \
    bash "$ROOT/Scripts/sign-and-notarize.sh" --sign-only
else
  codesign --force --sign - --deep "$APP" >/dev/null
fi

# Keep the prior complete bundle until the replacement is verified and signed.
# Existing daemon/owner executable inodes remain live through this exchange.
python3 "$ROOT/Scripts/atomic-bundle.py" "$APP" "$FINAL_APP"

APP="$FINAL_APP"

cat <<EOF

Launching Harness preview.
State directory:
  $PREVIEW_HOME

This does not install Harness, create a DMG, or write to:
  ~/Library/Application Support/Harness

Preview CLI while it is running:
  HARNESS_HOME="$PREVIEW_HOME" "$APP/Contents/MacOS/harness-cli" ping

EOF

# PREVIEW_SIGNPOSTS=1: turn on the frame signposter (FrameSignposter). `open` strips the shell
# environment, so the flag travels as a launch argument (NSArgumentDomain → UserDefaults).
if [[ "${PREVIEW_SIGNPOSTS:-0}" == "1" ]]; then
  open -n "$APP" --args -HARNESS_FRAME_SIGNPOSTS 1
else
  open -n "$APP"
fi
