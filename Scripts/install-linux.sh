#!/usr/bin/env bash
# Build and install the headless Harness daemon + CLI on a Linux (or other non-macOS) host.
#
# Requires a Swift 6 toolchain (https://www.swift.org/install/linux/). Builds the daemon and CLI in
# release mode, then runs `harness-cli install`, which copies the binaries under the Harness home and
# registers a systemd --user service so the daemon survives logout (with lingering) and restarts on
# failure.
#
# Usage:  Scripts/install-linux.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift not found. Install a Swift 6 toolchain: https://www.swift.org/install/linux/" >&2
  exit 1
fi

echo "==> Building HarnessDaemon + harness-cli (release)"
swift build -c release --product HarnessDaemon
swift build -c release --product harness-cli

CLI="$(swift build -c release --show-bin-path)/harness-cli"
echo "==> Installing via $CLI install"
"$CLI" install

cat <<'EOF'

Done. The daemon is registered as a systemd --user service (harness-daemon.service).

  systemctl --user status harness-daemon      # check it
  loginctl enable-linger "$USER"              # keep it running after you log out (headless hosts)

From your Mac, add this host and attach:

  harness-cli remote add --name <name> --ssh <user@this-host>
  harness-cli --host <name> list-sessions
  harness-cli --host <name> attach --surface <id>
EOF
