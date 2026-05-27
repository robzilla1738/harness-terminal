#!/usr/bin/env bash
set -euo pipefail
# Regenerate Harness.icns from Apps/Harness/Resources/Assets.xcassets/AppIcon.appiconset
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$ROOT/Apps/Harness/Resources/Assets.xcassets/AppIcon.appiconset"
OUT="$ROOT/Apps/Harness/Resources/Harness.icns"

if [[ ! -f "$ICONSET/icon_1024x1024.png" ]]; then
  echo "Missing $ICONSET/icon_1024x1024.png — add a 1024×1024 source PNG first." >&2
  exit 1
fi

SRC="$ICONSET/icon_1024x1024.png"
TMP_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/harness-icon.XXXXXX")"
STAGE="$TMP_STAGE/Harness.iconset"
mkdir -p "$STAGE"
trap 'rm -rf "$TMP_STAGE"' EXIT
for spec in "16:icon_16x16.png" "32:icon_16x16@2x.png" "32:icon_32x32.png" "64:icon_32x32@2x.png" \
  "128:icon_128x128.png" "256:icon_128x128@2x.png" "256:icon_256x256.png" "512:icon_256x256@2x.png" \
  "512:icon_512x512.png" "1024:icon_512x512@2x.png"; do
  size="${spec%%:*}"
  file="${spec##*:}"
  sips -z "$size" "$size" "$SRC" --out "$STAGE/$file" >/dev/null
done
iconutil -c icns "$STAGE" -o "$OUT"
echo "Wrote $OUT"
