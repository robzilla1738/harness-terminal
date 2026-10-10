#!/usr/bin/env bash
# Build and install the headless Harness daemon + CLI on a Linux (or other non-macOS) host.
#
# Requires a Swift 6 toolchain (https://www.swift.org/install/linux/). Builds the daemon and CLI in
# release mode, then runs `harness-cli install`, which copies the binaries under the Harness home and
# registers a systemd --user service so the daemon survives logout (with lingering) and restarts on
# failure.
#
# Usage: Scripts/install-linux.sh --source
#        Scripts/install-linux.sh --archive archive.tar.gz --sha256 TRUSTED_HASH [--service]
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${1:-}" != "--source" ]]; then
  exec python3 Scripts/install-linux-archive.py "$@"
fi
shift
if [[ $# != 0 ]]; then
  echo "error: --source accepts no archive-install arguments" >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift not found. Install a Swift 6 toolchain: https://www.swift.org/install/linux/" >&2
  exit 1
fi

echo "==> Building session host, daemon and CLI from source (release)"
swift build -c release --product HarnessSessionHost
swift build -c release --product HarnessDaemon
swift build -c release --product harness-cli

CLI="$(swift build -c release --show-bin-path)/harness-cli"
echo "==> Installing via $CLI install"
"$CLI" install

SOCKET="$("$CLI" socket-path)"

cat <<EOF

Done. The daemon is registered as a systemd --user service (harness-daemon.service).

  systemctl --user status harness-daemon      # check it
  loginctl enable-linger "\$USER"             # keep it running after you log out (headless hosts)

From your Mac, add this host and attach:

  harness-cli remote add --name <name> --ssh <user@this-host> --socket "$SOCKET"
  harness-cli --host <name> list-sessions
  harness-cli --host <name> attach --surface <id>
EOF
