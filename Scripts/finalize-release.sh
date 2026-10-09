#!/usr/bin/env bash
set -euo pipefail
# Finalize a Harness release: notarize the (already Developer-ID-signed) DMG, staple it,
# re-upload to the GitHub release, generate the Sparkle appcast, and (optionally) deploy it to
# the website. This is the one step that needs an Apple credential and a Sparkle signing key —
# secrets that intentionally live with the human or a protected CI environment, not the repo.
#
# Prereq: ./Scripts/build-release.sh && SIGNING_IDENTITY=… ./Scripts/sign-and-notarize.sh && \
#         ./Scripts/create-dmg.sh   (or `make dmg` + `make sign`) so Harness.app + Harness.dmg exist.
#
# Auth — provide ONE of:
#   App Store Connect API key (recommended):
#     ASC_ISSUER_ID=<issuer-uuid>            # App Store Connect → Users and Access → Integrations → Keys
#     ASC_KEY_ID=<key-id>                    # required when ASC_ISSUER_ID is set (no baked-in default)
#     ASC_KEY=~/Downloads/AuthKey_<ASC_KEY_ID>.p8   # defaults to ~/Downloads/AuthKey_<ASC_KEY_ID>.p8
#   …or an Apple ID app-specific password:
#     APPLE_ID=you@example.com APPLE_TEAM_ID=<team-id> APPLE_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx
#
# Optional (all default sensibly — no personal values are hardcoded):
#   TAG=vX.Y.Z                               # release tag; defaults to v<CFBundleShortVersionString>
#   REPO=<owner/name>                        # GitHub repo; defaults to the checkout's `gh` context
#   SIGNING_IDENTITY="Developer ID Application: …"  # defaults to the identity that signed Harness.app
#   DOWNLOAD_URL_PREFIX=https://github.com/<owner>/<repo>/releases/download/<tag>/
#                                             # appcast enclosure URL prefix
#   SPARKLE_EDDSA_PRIVATE_KEY_FILE=/path/to/private-key
#                                             # use Sparkle's --ed-key-file mode instead of keychain
#   DEPLOY_WEBSITE=1 WEBSITE_DIR=~/Code/harness-website   # copy appcast.xml into public/ and `vercel --prod`
#
# Usage:  ASC_ISSUER_ID=<uuid> ASC_KEY_ID=<key-id> ./Scripts/finalize-release.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/Harness.app"
DMG="$ROOT/Harness.dmg"

[[ -d "$APP" ]] || { echo "Harness.app missing — run build-release.sh + sign-and-notarize.sh + create-dmg.sh first." >&2; exit 1; }
[[ -f "$DMG" ]] || { echo "Harness.dmg missing — run create-dmg.sh first." >&2; exit 1; }

# Single-source the version: derive it (and the default release TAG) from the *built* app's
# Info.plist — the one thing that's authoritative about what's actually being shipped — instead of
# hardcoding a literal that silently drifts from the bundle on every bump.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ -n "$VERSION" ]] || { echo "Could not read CFBundleShortVersionString from $APP/Contents/Info.plist" >&2; exit 1; }
TAG="${TAG:-v$VERSION}"

# Repo for the GitHub upload: env override, else auto-detect from the checkout's `gh` context — no
# personal default baked into the script.
REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
[[ -n "$REPO" ]] || { echo "Set REPO=<owner/name> (could not auto-detect via gh)." >&2; exit 1; }

# Re-sign the rebuilt DMG with the same Developer-ID identity that signed the app (read back from its
# signature) unless overridden — so the identity isn't a hardcoded personal string in the repo.
SIGNING_IDENTITY="${SIGNING_IDENTITY:-$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=Developer ID Application/{print substr($0, index($0, "=") + 1); exit}')}"
[[ -n "$SIGNING_IDENTITY" ]] || { echo "Set SIGNING_IDENTITY (could not read it from $APP's signature)." >&2; exit 1; }

# Build the notarytool auth args from whichever credential set is present.
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
No notarization credentials. Set EITHER:
  ASC_ISSUER_ID=<issuer-uuid>  [ASC_KEY_ID=…] [ASC_KEY=…]      (App Store Connect API key)
or:
  APPLE_ID=…  APPLE_TEAM_ID=9F2JXY8TCK  APPLE_APP_PASSWORD=…   (Apple ID app-specific password)
MSG
  exit 1
fi

echo "==> Submitting $DMG to the notary service (this can take a few minutes)…"
xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait

echo "==> Stapling the ticket onto the app and the DMG…"
xcrun stapler staple "$APP"
# Rebuild the DMG so it carries the freshly-stapled app. The rebuilt DMG has a new
# signature/hash, so submit that final archive before stapling it.
"$ROOT/Scripts/create-dmg.sh"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
echo "==> Submitting rebuilt DMG to the notary service…"
xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
xcrun stapler staple "$DMG"
echo "==> Verifying Gatekeeper acceptance…"
# No `|| true` masking: a Gatekeeper rejection here means the DMG would be blocked on users' Macs,
# so fail the release loudly instead of printing the rejection and continuing.
if ! spctl -a -t open --context context:primary-signature -v "$DMG"; then
  echo "Gatekeeper rejected $DMG (spctl). Not publishing." >&2
  exit 1
fi
xcrun stapler validate "$DMG" && echo "    DMG ticket stapled + valid."

echo "==> Re-uploading the notarized DMG to GitHub release ${TAG}…"
gh release upload "$TAG" "$DMG" --clobber --repo "$REPO"

if [[ -n "${SPARKLE_EDDSA_PRIVATE_KEY_FILE:-}" ]]; then
  echo "==> Generating the Sparkle appcast with SPARKLE_EDDSA_PRIVATE_KEY_FILE…"
else
  echo "==> Generating the Sparkle appcast (a keychain 'Allow' prompt may appear — approve it)…"
fi
mkdir -p "$ROOT/dist"
cp "$DMG" "$ROOT/dist/Harness.dmg"
"$ROOT/Scripts/generate-appcast.sh" "$ROOT/dist"

if [[ "${DEPLOY_WEBSITE:-0}" == "1" ]]; then
  WEBSITE_DIR="${WEBSITE_DIR:-$HOME/Code/harness-website}"
  if [[ -d "$WEBSITE_DIR" && -f "$ROOT/dist/appcast.xml" ]]; then
    echo "==> Deploying appcast.xml to the website ($WEBSITE_DIR)…"
    mkdir -p "$WEBSITE_DIR/public"
    cp "$ROOT/dist/appcast.xml" "$WEBSITE_DIR/public/appcast.xml"
    ( cd "$WEBSITE_DIR" && vercel --prod --yes )
    echo "    appcast live at https://thebestterminal.com/appcast.xml — Sparkle auto-update is now wired."
  else
    echo "    Skipped website deploy (set WEBSITE_DIR and ensure dist/appcast.xml exists)." >&2
  fi
else
  echo "==> appcast at dist/appcast.xml. Deploy it: copy to the website's public/appcast.xml and \`vercel --prod\`,"
  echo "    or re-run with DEPLOY_WEBSITE=1. SUFeedURL (https://thebestterminal.com/appcast.xml) then resolves."
  echo "    Ensure DOWNLOAD_URL_PREFIX (${DOWNLOAD_URL_PREFIX:-https://thebestterminal.com/}) points at the live DMG."
fi

echo "Done. Notarized DMG on release $TAG; appcast generated."
