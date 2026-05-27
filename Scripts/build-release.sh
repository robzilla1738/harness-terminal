#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Resolving dependencies..."
swift package resolve

echo "Building release binaries..."
swift build -c release --product Harness
swift build -c release --product HarnessDaemon
swift build -c release --product harness-cli

echo "Packaging Harness.app..."
"$ROOT/Scripts/package-app.sh" release

echo "Done. App bundle: $ROOT/Harness.app"
