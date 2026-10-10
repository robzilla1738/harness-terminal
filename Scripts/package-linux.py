#!/usr/bin/env python3
"""Build immutable-toolchain Linux archives locally; no publishing or CI changes."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]

def run(arguments, **kwargs):
    subprocess.run(arguments, check=True, **kwargs)

def snapshot(destination):
    files = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT).split(b'\0')
    selected = []
    for raw in files:
        if not raw:
            continue
        relative = Path(os.fsdecode(raw))
        if relative.parts[0] not in {'Packages', 'Tools', 'Tests', 'Fixtures', 'Vendor', 'Scripts', 'docs', 'packaging', 'Package.swift', 'Package.resolved', 'LICENSE', 'README.md'}:
            continue
        source = ROOT / relative
        if not source.exists():
            continue  # tracked deletions are part of the working tree
        if source.is_symlink() or not source.is_file():
            raise RuntimeError('Source snapshot refuses nonregular files: ' + str(relative))
        selected.append(relative)
    digest = hashlib.sha256()
    for relative in sorted(set(selected)):
        source = ROOT / relative; data = source.read_bytes(); mode = 0o755 if source.stat().st_mode & 0o111 else 0o644
        name = relative.as_posix().encode(); digest.update(len(name).to_bytes(8, 'big') + name + mode.to_bytes(4, 'big') + len(data).to_bytes(8, 'big') + data)
        target = destination / relative; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data); target.chmod(mode); os.utime(target, ns=(0, source.stat().st_mtime_ns))
    return digest.hexdigest()

def archive(directory, target):
    # Stable order, modes, ownership, metadata and gzip timestamp.
    with target.open('wb') as stream, gzip.GzipFile(filename='', mode='wb', fileobj=stream, mtime=0) as compressed, tarfile.open(fileobj=compressed, mode='w', format=tarfile.PAX_FORMAT) as tar:
        for path in sorted(directory.rglob('*')):
            if path.is_symlink():
                raise RuntimeError('Archive refuses symlinks')
            info = tar.gettarinfo(str(path), arcname=path.relative_to(directory).as_posix()); info.uid = info.gid = 0; info.uname = info.gname = ''; info.mtime = 0; info.pax_headers = {}; info.mode = 0o755 if path.is_dir() or path.parent.name == 'bin' or path.name == 'install.py' else 0o644
            if path.is_file():
                with path.open('rb') as source: tar.addfile(info, source)
            else: tar.addfile(info)

def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--context'); parser.add_argument('--architectures', nargs='+', choices=['x86_64', 'arm64'], default=['x86_64', 'arm64']); parser.add_argument('--output', type=Path, default=ROOT / 'dist/linux'); args = parser.parse_args()
    lock = json.loads((ROOT / 'packaging/linux-lock.json').read_text()); output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    work = ROOT / '.build/linux-package'; work.mkdir(parents=True, exist_ok=True)
    temporary = work / ('source-' + os.urandom(8).hex()); temporary.mkdir()
    try:
        source_hash = snapshot(temporary); source = work / ('input-' + source_hash)
        if source.exists(): shutil.rmtree(temporary)
        else: temporary.rename(source)
        docker = ['docker'] + (['--context', args.context] if args.context else [])
        for architecture in args.architectures:
            pin = lock['architectures'][architecture]; stage = work / ('stage-' + architecture)
            if stage.exists(): shutil.rmtree(stage)
            stage.mkdir()
            for path in [source, stage]:
                if ':' in str(path): raise RuntimeError('Docker volume paths cannot contain a colon')
            run(docker + ['run', '--rm', '--platform', pin['platform'], '--volume', str(source) + ':/source:ro', '--volume', 'harness-linux-' + architecture + '-package:/cache', '--volume', str(stage) + ':/output', '--workdir', '/source',
                '--env', 'HARNESS_PACKAGE_ARCH=' + architecture, '--env', 'HARNESS_BUILD_JOBS=' + str(lock['build_jobs']), '--env', 'HARNESS_SQLITE_VERSION=' + lock['sqlite_development_version'], '--env', 'HARNESS_SOURCE_SHA256=' + source_hash, '--env', 'HARNESS_BUILDER_IMAGE=' + pin['builder'], pin['builder'], 'bash', '/source/Scripts/build-linux-inside.sh'])
            licenses = stage / 'licenses'; licenses.mkdir(exist_ok=True); shutil.copyfile(source / 'LICENSE', licenses / 'Harness-LICENSE'); shutil.copyfile(source / 'Vendor/swift-sdk/LICENSE', licenses / 'MCP-SDK-LICENSE'); shutil.copyfile(source / 'docs/THIRD-PARTY-NOTICES.md', licenses / 'THIRD-PARTY-NOTICES.md')
            shutil.copyfile(source / 'Packages/CLua51/COPYRIGHT', licenses / 'Lua-COPYRIGHT'); shutil.copyfile(source / 'Packages/CHarnessImage/LICENSE', licenses / 'CHarnessImage-LICENSE')
            for license in (source / 'packaging/licenses').iterdir(): shutil.copyfile(license, licenses / license.name)
            shutil.copyfile(source / 'docs/LINUX-PACKAGING.md', stage / 'README.md'); shutil.copyfile(source / 'Scripts/install-linux-archive.py', stage / 'install.py')
            target = output / ('harness-linux-' + architecture + '.tar.gz'); archive(stage, target)
            checksum = hashlib.sha256(target.read_bytes()).hexdigest(); (output / (target.name + '.sha256')).write_text(checksum + '  ' + target.name + '\n')
            shutil.copyfile(stage / 'artifact.json', output / ('harness-linux-' + architecture + '.json'))
            print(target, checksum, flush=True)
    finally:
        if temporary.exists(): shutil.rmtree(temporary)

if __name__ == '__main__': main()
