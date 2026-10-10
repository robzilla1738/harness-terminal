#!/usr/bin/env python3
"""Run each packaged archive in its locked runtime image without Swift installed."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--context'); parser.add_argument('--artifacts', type=Path, default=root / 'dist/linux'); parser.add_argument('--architectures', nargs='+', choices=['x86_64', 'arm64'], default=['x86_64', 'arm64']); args = parser.parse_args()
    artifacts = args.artifacts.resolve(); lock = json.loads((root / 'packaging/linux-lock.json').read_text()); docker = ['docker'] + (['--context', args.context] if args.context else [])
    for architecture in args.architectures:
        name = 'harness-linux-' + architecture; archive = artifacts / (name + '.tar.gz'); metadata = json.loads((artifacts / (name + '.json')).read_text())
        checksum = (artifacts / (archive.name + '.sha256')).read_text().split()[0]
        if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum or metadata.get('architecture') != architecture: raise RuntimeError('Artifact metadata/checksum mismatch')
        packages = []
        for package, version in metadata['runtime_packages'].items():
            if not re.fullmatch(r'[a-z0-9.+-]+(?::(?:amd64|arm64))?', package) or not re.fullmatch(r'[A-Za-z0-9.+:~_-]+', version): raise RuntimeError('Invalid package identity in artifact metadata')
            packages.append(package + '=' + version)
        pin = lock['architectures'][architecture]
        script = 'set -euo pipefail\napt-get -qq update\napt-get -qq install --no-install-recommends python3 ca-certificates "$@"\ncommand -v swift && exit 1\npython3 /source/Scripts/prove-linux-inside.py\n'
        command = docker + ['run', '--rm', '--platform', pin['platform'], '--volume', str(root) + ':/source:ro', '--volume', str(artifacts) + ':/artifacts:ro', '--env', 'HARNESS_ARCHIVE=/artifacts/' + archive.name, '--env', 'HARNESS_ARCHIVE_SHA256=' + checksum, '--env', 'HARNESS_ARCHITECTURE=' + architecture, pin['runtime'], 'bash', '-c', script, '--'] + packages
        subprocess.run(command, check=True)

if __name__ == '__main__': main()
