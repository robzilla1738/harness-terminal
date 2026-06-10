#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Resolving dependencies..."
swift package resolve

# SwiftPM does not reliably remove resource bundles left in a restored .build cache after a
# target stops declaring resources. Clear them before building so package-app.sh can only copy
# bundles produced by the current package graph.
rm -rf "$ROOT/.build/release"/*.bundle

echo "Building release binaries..."
# Cross-module-optimization experiment (roadmap PR-37, strictly bench-gated): opt in with
# HARNESS_CMO=1. Keep only if `make bench-check` shows wins beyond noise with the full
# suite green, and record the compile-time cost in the PR/release notes. Off by default —
# release artifacts stay byte-stable until the measurement says otherwise.
# Plain string (word-split deliberately below): an empty array + `set -u` errors on the
# bash 3.2 macOS ships.
CMO_FLAGS=""
if [ "${HARNESS_CMO:-0}" = "1" ]; then
  echo "  (cross-module optimization ON — bench-gated experiment)"
  CMO_FLAGS="-Xswiftc -cross-module-optimization"
fi
# shellcheck disable=SC2086
swift build -c release --product Harness $CMO_FLAGS
# shellcheck disable=SC2086
swift build -c release --product HarnessDaemon $CMO_FLAGS
# shellcheck disable=SC2086
swift build -c release --product harness-cli $CMO_FLAGS

echo "Packaging Harness.app..."
"$ROOT/Scripts/package-app.sh" release

echo "Done. App bundle: $ROOT/Harness.app"
