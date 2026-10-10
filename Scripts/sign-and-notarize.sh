#!/usr/bin/env bash
set -euo pipefail
# Sign and notarize Harness.app for distribution.
#
# Required:
#   SIGNING_IDENTITY  — e.g. "Developer ID Application: Your Name (TEAMID)"
#
# Notarization (required for distribution — omit ONLY with --sign-only / SIGN_ONLY=1).
# Provide ONE of:
#   App Store Connect API key (recommended for CI):
#     ASC_ISSUER_ID=<issuer-uuid>
#     ASC_KEY_ID=<key-id>
#     ASC_KEY=/path/to/AuthKey_<key-id>.p8   # defaults to ~/Downloads/AuthKey_<key-id>.p8
#   …or an Apple ID app-specific password:
#     APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
#
# Usage: make sign   or   ./Scripts/sign-and-notarize.sh [--sign-only]
#   --sign-only / SIGN_ONLY=1 : sign locally and skip notarization without failing.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${HARNESS_SIGNING_APP:-$ROOT/Harness.app}"
# Require an explicit identity so a release is never signed with the wrong or
# ambiguous one. Use SIGNING_IDENTITY=- for an ad-hoc (unsigned) local build.
IDENTITY="${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID (or '-' for an ad-hoc local build).}"

SIGN_ONLY="${SIGN_ONLY:-0}"
if [[ "${1:-}" == "--sign-only" ]]; then SIGN_ONLY=1; fi
# An ad-hoc identity ('-') can't be notarized, so treat it as an implicit sign-only build.
if [[ "$IDENTITY" == "-" ]]; then SIGN_ONLY=1; fi

if [[ ! -d "$APP" ]]; then
  echo "Run Scripts/build-release.sh first." >&2
  exit 1
fi

echo "Signing $APP..."
python3 "$ROOT/Scripts/package-macos-tools.py" "$APP"
HISTORY_ENTITLEMENTS="$(mktemp -d -t harness-history-entitlements)"
trap 'rm -rf "$HISTORY_ENTITLEMENTS"' EXIT
python3 "$ROOT/Scripts/prepare-macos-signing.py" "$APP" "$IDENTITY" "${APPLE_TEAM_ID:-}" \
  "${HARNESS_PROVISIONING_PROFILE_DIRECTORY:-}" "$HISTORY_ENTITLEMENTS"
# Sign inside-out (NOT --deep). Sparkle ships nested helpers — XPC services, Updater.app,
# and the Autoupdate tool — that each need their own hardened-runtime signature. `--deep`
# signs them with the app's identity but not correctly (Sparkle explicitly forbids it), so
# the updater is rejected at runtime. Sign the deepest components first, then the framework,
# then the embedded tools, then the app bundle.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  echo "  Signing Sparkle.framework components..."
  # XPC services and helper apps/tools live under Versions/<letter>; glob so a version
  # bump (B -> C ...) keeps working.
  for component in \
    "$SPARKLE"/Versions/*/XPCServices/*.xpc \
    "$SPARKLE"/Versions/*/Updater.app \
    "$SPARKLE"/Versions/*/Autoupdate; do
    [[ -e "$component" ]] || continue
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$component"
  done
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE"
fi

# codesign does not expand Xcode entitlement variables. Derive the access-group
# prefix from supplied signing metadata before signing every cooperating component.
for component in HarnessSessionHost HarnessDaemon harness-cli; do
  codesign --force --options runtime --timestamp --entitlements "$HISTORY_ENTITLEMENTS/$component.plist" \
    --sign "$IDENTITY" "$APP/Contents/Helpers/$component.app"
done
# Seal the app bundle last (no --deep — nested code is already signed above).
codesign --force --options runtime --timestamp --entitlements "$HISTORY_ENTITLEMENTS/Harness.plist" --sign "$IDENTITY" "$APP"

# Verify the whole bundle (nested helpers + app) before we go any further — a broken nested
# signature can pass signing yet fail notarization/Gatekeeper later, so catch it here.
echo "Verifying signatures..."
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ "$SIGN_ONLY" == "1" ]]; then
  echo "Signed only (notarization skipped via --sign-only / ad-hoc identity)."
  exit 0
fi

NOTARY_AUTH=()
if [[ -n "${ASC_ISSUER_ID:-}" ]]; then
  KEY_ID="${ASC_KEY_ID:?Set ASC_KEY_ID to your App Store Connect API key id when using ASC_ISSUER_ID}"
  KEY="${ASC_KEY:-$HOME/Downloads/AuthKey_${KEY_ID}.p8}"
  [[ -f "$KEY" ]] || { echo "API key not found: $KEY" >&2; exit 1; }
  NOTARY_AUTH=(--key "$KEY" --key-id "$KEY_ID" --issuer "$ASC_ISSUER_ID")
  echo "Notarizing with App Store Connect API key $KEY_ID (issuer $ASC_ISSUER_ID)."
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
  NOTARY_AUTH=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
  echo "Notarizing with Apple ID $APPLE_ID (team $APPLE_TEAM_ID)."
else
  cat >&2 <<'MSG'
ERROR: notarization credentials missing. A distributed build MUST be notarized.
Set EITHER:
  ASC_ISSUER_ID=<issuer-uuid> ASC_KEY_ID=<key-id> [ASC_KEY=/path/to/AuthKey.p8]
or:
  APPLE_ID=<email> APPLE_TEAM_ID=<team-id> APPLE_APP_PASSWORD=<app-specific-password>

Re-run with --sign-only only for local, non-distributed builds.
MSG
  exit 1
fi

ZIP="$ROOT/Harness-notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait
xcrun stapler staple "$APP"
# Re-verify after stapling so a corrupt ticket can't slip through.
codesign --verify --deep --strict --verbose=2 "$APP"
rm -f "$ZIP"
echo "Notarized and stapled."
