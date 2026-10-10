#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="${1:-$ROOT/Harness.dmg}"

if [[ ! -f "$DMG" ]]; then
  echo "Usage: Scripts/smoke-dmg.sh [path/to/Harness.dmg]" >&2
  echo "DMG not found: $DMG" >&2
  exit 2
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/harness-dmg-smoke.XXXXXX")"
mountpoint="$workdir/mount"
install_dir="$workdir/install"
home_dir="$workdir/home"
app_log="$workdir/Harness.log"
daemon_log="$home_dir/logs/daemon.log"
app_pid=""

cleanup() {
  if [[ -n "${app_pid:-}" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  if [[ -d "$mountpoint" ]]; then
    hdiutil detach "$mountpoint" -quiet -force >/dev/null 2>&1 || true
  fi
  rm -rf "$workdir"
}
trap cleanup EXIT

mkdir -p "$mountpoint" "$install_dir" "$home_dir"

echo "==> Verifying DMG container..."
hdiutil verify "$DMG"

echo "==> Mounting DMG..."
hdiutil attach "$DMG" -quiet -nobrowse -readonly -mountpoint "$mountpoint"

mounted_app="$mountpoint/Harness.app"
if [[ ! -d "$mounted_app" ]]; then
  echo "Harness.app not found in mounted DMG." >&2
  find "$mountpoint" -maxdepth 2 -print >&2
  exit 1
fi

app="$install_dir/Harness.app"
echo "==> Copying app to temp install location..."
ditto "$mounted_app" "$app"

plist="$app/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")"
echo "    Harness $version ($build), macOS $minimum+"

for binary in Harness HarnessSessionHost HarnessDaemon harness-cli; do
  path="$app/Contents/MacOS/$binary"
  [[ -x "$path" ]] || { echo "Missing executable: $path" >&2; exit 1; }
  if ! lipo -archs "$path" | grep -qw arm64; then
    echo "$binary is not arm64." >&2
    lipo -archs "$path" >&2
    exit 1
  fi
done

if find "$app/Contents/Resources" -maxdepth 1 -name '*.bundle' -print | grep -q .; then
  echo "Unexpected resource bundle in Harness.app:" >&2
  find "$app/Contents/Resources" -maxdepth 1 -name '*.bundle' -print >&2
  exit 1
fi

echo "==> Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$app"

echo "==> Exercising bundled theme catalog through shipped CLI..."
HARNESS_HOME="$home_dir" "$app/Contents/MacOS/harness-cli" theme-preview --all >/dev/null

echo "==> Launching Harness.app from temp install location..."
HARNESS_HOME="$home_dir" "$app/Contents/MacOS/Harness" >"$app_log" 2>&1 &
app_pid=$!

for attempt in {1..40}; do
  if ! kill -0 "$app_pid" 2>/dev/null; then
    echo "Harness exited during smoke launch." >&2
    echo "--- Harness stdout/stderr ---" >&2
    sed -n '1,160p' "$app_log" >&2 || true
    echo "--- daemon log ---" >&2
    sed -n '1,160p' "$daemon_log" >&2 || true
    exit 1
  fi

  if HARNESS_HOME="$home_dir" "$app/Contents/MacOS/harness-cli" ping >/dev/null 2>&1; then
    echo "==> Smoke launch passed."
    exit 0
  fi

  sleep 0.25
done

echo "Harness launched but daemon did not answer ping." >&2
echo "--- Harness stdout/stderr ---" >&2
sed -n '1,160p' "$app_log" >&2 || true
echo "--- daemon log ---" >&2
sed -n '1,160p' "$daemon_log" >&2 || true
exit 1
