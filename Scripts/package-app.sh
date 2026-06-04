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

# Guard: HarnessVersion.swift is the daemon/CLI's view of the version (the app reads
# Bundle.main, but the launchd daemon can't). It is bumped by hand alongside Info.plist;
# v1.3.0/v1.3.1 missed it, shipping daemons that reported 1.2.0 — and the daemon↔app build
# handshake depends on it. Fail the package step if the two disagree.
PLIST_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
VERSION_SWIFT="$ROOT/Packages/HarnessCore/Sources/HarnessCore/HarnessVersion.swift"
CODE_SHORT="$(sed -n 's/.*static let short = "\([^"]*\)".*/\1/p' "$VERSION_SWIFT")"
CODE_BUILD="$(sed -n 's/.*static let build = \([0-9]*\).*/\1/p' "$VERSION_SWIFT")"
if [[ "$PLIST_SHORT" != "$CODE_SHORT" || "$PLIST_BUILD" != "$CODE_BUILD" ]]; then
  echo "error: HarnessVersion.swift ($CODE_SHORT/$CODE_BUILD) does not match Info.plist ($PLIST_SHORT/$PLIST_BUILD)." >&2
  echo "       Bump HarnessVersion.short/build to match Info.plist before packaging." >&2
  exit 1
fi

# SwiftPM resource bundles (for example HarnessTheme's bundled themes.json) are
# emitted next to the built products. The app is assembled by this script rather
# than by Xcode, so copy those bundles into Contents/Resources explicitly.
for bundle in "$BUILD_DIR"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done

# Embed Sparkle.framework (the only external dependency, GUI-only). SwiftPM links it via
# `@rpath`, so the app binary needs an rpath into Contents/Frameworks. `ditto` preserves the
# framework's version symlinks + nested code signatures (a plain `cp` would flatten them).
# SwiftPM normally drops it at .build/$CONFIG/Sparkle.framework; fall back to the artifacts
# cache for older/newer SwiftPM layouts. A missing framework is FATAL — the app links Sparkle
# at compile time, so shipping without it crashes the moment the menu touches SparkleUpdater.
FRAMEWORK="$BUILD_DIR/Sparkle.framework"
if [[ ! -d "$FRAMEWORK" ]]; then
  FRAMEWORK="$(find "$ROOT/.build/artifacts" "$ROOT/.build" -name Sparkle.framework -type d 2>/dev/null | head -n1 || true)"
fi
if [[ -z "$FRAMEWORK" || ! -d "$FRAMEWORK" ]]; then
  echo "error: Sparkle.framework not found under .build — build the Harness product first (the app would crash without it)." >&2
  exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP/Contents/MacOS/Harness" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Harness"
fi
# Verify the embed actually took (framework present + rpath wired), or fail before we ship.
if [[ ! -d "$APP/Contents/Frameworks/Sparkle.framework" ]] \
   || ! otool -l "$APP/Contents/MacOS/Harness" | grep -q "@executable_path/../Frameworks"; then
  echo "error: Sparkle embed verification failed (framework or @rpath missing)." >&2
  exit 1
fi

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

# Bundled "Symbols Nerd Font Mono" (MIT) — auto-activated via Info.plist's
# ATSApplicationFontsPath = Fonts so Nerd Font / Powerline glyphs always have a coverage font
# even when the user's primary font isn't a Nerd Font. Copied verbatim (incl. its LICENSE).
FONTS="$ROOT/Apps/Harness/Resources/Fonts"
if [[ -d "$FONTS" ]]; then
  ditto "$FONTS" "$APP/Contents/Resources/Fonts"
fi

chmod +x "$APP/Contents/MacOS/"*

echo "Created $APP"
