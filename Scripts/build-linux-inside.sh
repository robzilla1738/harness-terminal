#!/usr/bin/env bash
# Runs only inside the locked Linux toolchain container; no service is installed.
set -euo pipefail
test "$(uname -s)" = Linux
test -n "${HARNESS_PACKAGE_ARCH:?}"
test -n "${HARNESS_SQLITE_VERSION:?}"
test "${HARNESS_BUILD_JOBS:?}" = 6
swift --version | head -1 | python3 -c 'import sys; assert "Swift version 6.0.3" in sys.stdin.read(), "Unexpected toolchain"'
apt-get -qq update
apt-get -qq install --no-install-recommends "libsqlite3-dev=$HARNESS_SQLITE_VERSION"
cd /source
# Linux's manifest declares exactly the three packaged executables. Build the
# shared graph once, retaining one consistent compiler plan for all components.
swift build --jobs "$HARNESS_BUILD_JOBS" -c release --static-swift-stdlib --disable-automatic-resolution --scratch-path /cache/build \
  -Xswiftc -debug-prefix-map -Xswiftc /source=/harness/source
products="$(swift build -c release --scratch-path /cache/build --show-bin-path)"
mkdir -p /output/bin
for product in HarnessSessionHost HarnessDaemon harness-cli; do
  install -m 755 "$products/$product" "/output/bin/$product"
  # Release products retain runtime reflection, unwind tables and ordinary
  # symbols, but omit DWARF and compiler-only incremental module fingerprints.
  # These vary across clean/cached builds without changing any runtime section.
  objcopy --strip-debug --remove-section=.swift_modhash "/output/bin/$product"
  ldd "/output/bin/$product" > "/output/$product.dependencies"
  if grep -E 'not found|libswift' "/output/$product.dependencies" >/dev/null; then
    echo "Unresolved or dynamic Swift dependency in $product" >&2; exit 1
  fi
done
mkdir -p /output/licenses
for package in /cache/build/checkouts/*; do
  test -d "$package" || continue
  for license in "$package"/LICENSE "$package"/LICENSE.txt "$package"/COPYING; do
    test -f "$license" || continue
    install -m 644 "$license" "/output/licenses/$(basename "$package")-$(basename "$license")"
  done
done
python3 /source/Scripts/linux-artifact-metadata.py /output
