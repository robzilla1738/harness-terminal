#!/usr/bin/env bash
set -euo pipefail
# Sign and notarize Harness.app for distribution.
#
# Required:
#   SIGNING_IDENTITY  — e.g. "Developer ID Application: Your Name (TEAMID)"
#
# Optional (omit to sign only, skip notarization):
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD (app-specific password)
#
# Usage: make sign   or   ./Scripts/sign-and-notarize.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Harness.app"
IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"

if [[ ! -d "$APP" ]]; then
  echo "Run Scripts/build-release.sh first." >&2
  exit 1
fi

echo "Signing $APP..."
codesign --force --deep --options runtime --sign "$IDENTITY" \
  "$APP/Contents/MacOS/HarnessDaemon" \
  "$APP/Contents/MacOS/harness-cli" \
  "$APP/Contents/MacOS/Harness"
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"

if [[ -z "${APPLE_ID:-}" || -z "${APPLE_TEAM_ID:-}" || -z "${APPLE_APP_PASSWORD:-}" ]]; then
  echo "Set APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD to notarize."
  exit 0
fi

ZIP="$ROOT/Harness-notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --wait
xcrun stapler staple "$APP"
echo "Notarized and stapled."
