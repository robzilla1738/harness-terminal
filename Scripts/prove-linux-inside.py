#!/usr/bin/env python3
"""Disposable runtime/install proof, entered only in the selected Linux container."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

def main():
    assert shutil.which('swift') is None, 'Runtime image unexpectedly has Swift installed'
    spec = importlib.util.spec_from_file_location('installer', '/source/Scripts/install-linux-archive.py'); installer = importlib.util.module_from_spec(spec); spec.loader.exec_module(installer)
    archive = Path(os.environ['HARNESS_ARCHIVE']); checksum = os.environ['HARNESS_ARCHIVE_SHA256']
    manifest, members = installer.validate_archive(archive, checksum)
    with tempfile.TemporaryDirectory(prefix='hlp-', dir='/tmp') as directory:
        home = Path(directory); (home / 'bin').mkdir(); (home / 'bin/unrelated').write_text('preserved user content')
        installer.install(home, manifest, members)
        assert (home / 'bin/unrelated').read_text() == 'preserved user content'
        original_id = (home / 'bin/.harness-install-id').read_text()
        original_exchange = installer.exchange
        def interrupted(a, b):
            original_exchange(a, b)
            raise SystemExit('Fixture process interruption after atomic exchange')
        installer.exchange = interrupted
        try: installer.install(home, manifest, members)
        except SystemExit: pass
        finally: installer.exchange = original_exchange
        assert installer.journal_path(home).exists()
        installer.recover(home)
        assert not installer.journal_path(home).exists()
        assert (home / 'bin/.harness-install-id').read_text() != original_id
        installer.rollback(home)
        assert (home / 'bin/.harness-install-id').read_text() == original_id
        assert (home / 'bin/unrelated').read_text() == 'preserved user content'
        assert installer.hashes(home / 'bin') == manifest['binaries']
        before = installer.directory_identity(home / 'bin')
        try: installer.validate_archive(archive, '0' * 64)
        except RuntimeError: pass
        else: raise AssertionError('Invalid checksum was accepted')
        assert installer.directory_identity(home / 'bin') == before
        opposite = archive.parent / ('harness-linux-' + ('x86_64' if os.environ['HARNESS_ARCHITECTURE'] == 'arm64' else 'arm64') + '.tar.gz')
        opposite_checked = False
        if opposite.exists():
            digest = __import__('hashlib').sha256(opposite.read_bytes()).hexdigest()
            try: installer.validate_archive(opposite, digest)
            except RuntimeError as error: assert 'architecture' in str(error)
            else: raise AssertionError('Other architecture was accepted')
            opposite_checked = True
        for name in installer.BINARIES:
            result = subprocess.run(['ldd', str(home / 'bin' / name)], capture_output=True, text=True, check=True)
            assert 'not found' not in result.stdout and 'libswift' not in result.stdout
        subprocess.run([str(home / 'bin/harness-cli'), 'version'], check=True)
        try:
            subprocess.run(['python3', '/source/Scripts/prove-session-survival.py', '--bin-dir', str(home / 'bin')], check=True)
        except subprocess.CalledProcessError:
            # Only this disposable container's synthetic proof logs, never an
            # existing user home. Preserve enough evidence to diagnose startup.
            for log in sorted(Path('/tmp').glob('hproof-*-failure.log')):
                print(log.read_bytes()[-16384:].decode('utf-8', errors='replace'), flush=True)
            raise
        print(json.dumps({'architecture': os.environ['HARNESS_ARCHITECTURE'], 'runtime_without_swift': True, 'atomic_install': True, 'interrupted_exchange_recovery': True, 'rollback': True, 'unrelated_files_preserved': True, 'bad_checksum_refused': True, 'other_architecture_refused': opposite_checked, 'actual_dynamic_dependencies_resolved': True}, sort_keys=True))

if __name__ == '__main__': main()
