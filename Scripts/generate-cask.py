#!/usr/bin/env python3
"""Print a cask from supplied artifact metadata. Never publish or change workflows."""
import argparse
import json
import re
import sys
from urllib.parse import urlsplit

def literal(value):
    # Ruby single quotes do not interpolate metadata containing #{...}.
    return "'" + value.replace('\\', '\\\\').replace("'", "\\'") + "'"

def generate(value):
    if value.get('schema') != 1 or set(value) - {'schema', 'version', 'url', 'sha256'}:
        raise ValueError('Supply schema, version, HTTPS artifact URL and SHA-256 only')
    version, url, checksum = value.get('version'), value.get('url'), value.get('sha256')
    if not isinstance(version, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,3}(?:[-+][A-Za-z0-9.-]+)?', version): raise ValueError('Invalid explicit artifact version')
    if not isinstance(url, str) or len(url.encode()) > 4096 or any(ord(c) < 32 for c in url): raise ValueError('Invalid artifact URL')
    parsed = urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.fragment or parsed.query: raise ValueError('Use a stable HTTPS artifact URL without credentials, query or fragment')
    if not isinstance(checksum, str) or not re.fullmatch(r'[0-9a-f]{64}', checksum): raise ValueError('Provide the verified SHA-256 from supplied artifact metadata')
    return '''cask "harness" do
  version VERSION
  sha256 CHECKSUM

  url ARTIFACT_URL
  name "Harness"
  desc "Native terminal and durable agent workspaces"
  homepage "https://github.com/robzilla1738/harness-terminal"
  depends_on macos: ">= :sequoia"

  app "Harness.app"
  binary "#{appdir}/Harness.app/Contents/MacOS/harness-cli", target: "harness-cli"

  # The PTY owner and copied tools have an independent lifecycle. No launchctl,
  # signal, wildcard deletion or history zap runs on a GUI upgrade/uninstall.
  caveats <<~EOS
    Opening Harness configures its guarded per-user session service.
    Shells remain owned by that service when the GUI closes or is upgraded.
    To remove the service and copied tools, close your shells, then run:
      harness-cli uninstall --if-empty
    Run that before brew uninstall --cask harness if complete tool removal is wanted.
    Settings, layout, credentials, worktrees and recorded history are preserved.
    Explicit destructive shutdown requires harness-cli uninstall --force.
  EOS
end
'''.replace('VERSION', literal(version)).replace('CHECKSUM', literal(checksum)).replace('ARTIFACT_URL', literal(url))

def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--metadata', required=True); args = parser.parse_args()
    with open(args.metadata, 'rb') as stream: data = stream.read(16385)
    if len(data) > 16384: raise ValueError('Metadata exceeds its bound')
    sys.stdout.write(generate(json.loads(data)))

if __name__ == '__main__':
    try: main()
    except (ValueError, OSError, TypeError) as error: print(str(error), file=sys.stderr); raise SystemExit(1)
