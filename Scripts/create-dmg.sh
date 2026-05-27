#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Harness.app"
DMG="$ROOT/Harness.dmg"
VOLUME="Harness"

if [[ ! -d "$APP" ]]; then
  echo "Run Scripts/build-release.sh first." >&2
  exit 1
fi

STAGING="$ROOT/.dmg-staging"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Harness.app"

# Optional background: place Scripts/dmg-background.png (600×400) for create-dmg
BG="$ROOT/Scripts/dmg-background.png"

if command -v create-dmg &>/dev/null; then
  DMG_ARGS=(
    --volname "$VOLUME"
    --window-pos 200 120
    --window-size 600 400
    --icon-size 100
    --app-drop-link 450 185
    --hide-extension "Harness.app"
  )
  if [[ -f "$BG" ]]; then
    DMG_ARGS+=(--background "$BG")
  fi
  create-dmg "${DMG_ARGS[@]}" "$DMG" "$STAGING"
else
  rm -f "$STAGING/Applications"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create -volname "$VOLUME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
fi

rm -rf "$STAGING"
echo "Created $DMG"
