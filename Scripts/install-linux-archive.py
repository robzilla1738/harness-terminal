#!/usr/bin/env python3
"""Verified, atomic Linux binary-directory installation with rollback/recovery.

Requires Python 3 and a kernel/libc supporting renameat2(RENAME_EXCHANGE).
Does not stop or replace a running Harness process. Service changes use the
installed CLI's guarded existing systemd integration only when explicitly requested.
"""
import argparse
import ctypes
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import stat
import subprocess
import tarfile
import tempfile
import uuid

BINARIES = ('HarnessSessionHost', 'HarnessDaemon', 'harness-cli')
MAXIMUM = 512 << 20

def owned(path, directory=False):
    info = path.lstat()
    if info.st_uid != os.getuid() or (directory and not stat.S_ISDIR(info.st_mode)) or (not directory and not stat.S_ISREG(info.st_mode)):
        raise RuntimeError('Refusing nonregular or non-owned installation path: ' + str(path))
    return info

def read(path, limit=MAXIMUM, owner=True):
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if (owner and info.st_uid != os.getuid()) or not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise RuntimeError('Invalid private installation file')
        with os.fdopen(fd, 'rb', closefd=False) as stream: return stream.read(limit + 1)
    finally: os.close(fd)

def sync(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try: os.fsync(fd)
    finally: os.close(fd)

def write(path, data, mode=0o600):
    temporary = path.parent / ('.' + path.name + '.' + uuid.uuid4().hex)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(fd, 'wb', closefd=False) as stream: stream.write(data); stream.flush(); os.fsync(fd)
        os.replace(temporary, path); sync(path.parent)
    finally:
        os.close(fd)
        if temporary.exists(): temporary.unlink()

def json_write(path, value): write(path, (json.dumps(value, sort_keys=True, indent=2) + '\n').encode())

def hashes(directory):
    owned(directory, directory=True)
    return {name: hashlib.sha256(read(directory / name)).hexdigest() if (directory / name).exists() else None for name in BINARIES}

def directory_identity(directory):
    owned(directory, directory=True); result = {}
    entries = list(directory.iterdir())
    if len(entries) > 512: raise RuntimeError('Binary directory preservation budget exceeded')
    for path in entries:
        info = path.lstat()
        if info.st_uid != os.getuid(): raise RuntimeError('Non-owned binary directory entry')
        if stat.S_ISREG(info.st_mode): result[path.name] = ['file', stat.S_IMODE(info.st_mode), hashlib.sha256(read(path)).hexdigest()]
        elif stat.S_ISLNK(info.st_mode): result[path.name] = ['link', os.readlink(path)]
        else: raise RuntimeError('Unsupported binary directory entry')
    return result

def exchange(a, b):
    library = ctypes.CDLL(None, use_errno=True)
    function = getattr(library, 'renameat2', None)
    if function is None: raise RuntimeError('Atomic directory exchange is unsupported by this libc; installation was not changed')
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]; function.restype = ctypes.c_int
    if function(-100, os.fsencode(a), -100, os.fsencode(b), 2): raise OSError(ctypes.get_errno(), 'Atomic binary-directory exchange failed')
    sync(a.parent)

def journal_path(home): return home / '.harness-install-journal.json'

def recover(home):
    journal = journal_path(home)
    if not journal.exists(): return
    value = json.loads(read(journal, 1 << 20))
    identifier = str(uuid.UUID(value['id']))
    if value.get('schema') != 1 or value['stage'] != '.bin-stage-' + identifier or value['backup'] != '.bin-backup-' + identifier:
        raise RuntimeError('Invalid installation recovery identity; no directories were changed')
    stage, backup, destination = home / value['stage'], home / value['backup'], home / 'bin'
    current = directory_identity(destination) if destination.exists() else None
    if current == value['old_snapshot']:
        if not stage.exists() or directory_identity(stage) != value['new_snapshot']: raise RuntimeError('Prepared installation is unavailable or changed; retain the current binaries')
        if destination.exists(): exchange(stage, destination)
        else: os.rename(stage, destination); sync(home)
        current = directory_identity(destination)
    if current != value['new_snapshot']: raise RuntimeError('Installed files changed during recovery; refusing automatic replacement')
    if value['old'] is not None:
        if stage.exists():
            if directory_identity(stage) != value['old_snapshot'] or backup.exists(): raise RuntimeError('Rollback staging changed; refusing to replace a directory')
            os.rename(stage, backup); sync(home)
        if not backup.exists() or directory_identity(backup) != value['old_snapshot']: raise RuntimeError('Rollback binaries are unavailable; recovery remains recorded')
        info = owned(backup, directory=True)
        previous_path = home / '.harness-rollback.json'
        previous = json.loads(read(previous_path, 1 << 20)) if previous_path.exists() else None
        json_write(previous_path, {'schema': 1, 'id': identifier, 'backup': backup.name, 'old': value['old'], 'new': value['new'], 'old_snapshot': value['old_snapshot'], 'new_snapshot': value['new_snapshot'], 'device': info.st_dev, 'inode': info.st_ino})
        if previous and previous.get('backup') != backup.name:
            try:
                previous_id = str(uuid.UUID(previous['id'])); obsolete = home / previous['backup']
                if previous['backup'] == '.bin-backup-' + previous_id and obsolete.exists():
                    old_info = owned(obsolete, directory=True)
                    if (old_info.st_dev, old_info.st_ino) == (previous['device'], previous['inode']) and directory_identity(obsolete) == previous['old_snapshot']: shutil.rmtree(obsolete); sync(home)
            except (OSError, ValueError, KeyError, RuntimeError): pass  # altered/user-edited backups are preserved
    journal.unlink(); sync(home)

def copy_unrelated(source, target):
    if not source.exists(): return
    owned(source, directory=True)
    files = list(source.iterdir())
    if len(files) > 512: raise RuntimeError('Existing bin directory exceeds the bounded preservation budget')
    for entry in files:
        if entry.name in BINARIES or entry.name in {'.harness-artifact.json', '.harness-install-id'}: continue
        info = entry.lstat()
        if info.st_uid != os.getuid(): raise RuntimeError('Existing bin entry is not owned by this user')
        if stat.S_ISLNK(info.st_mode): os.symlink(os.readlink(entry), target / entry.name)
        elif stat.S_ISREG(info.st_mode) and info.st_size <= 16 << 20:
            write(target / entry.name, read(entry, 16 << 20), stat.S_IMODE(info.st_mode))
        else: raise RuntimeError('Preservation of this bin entry needs an explicit move before installation: ' + str(entry))

def validate_archive(archive, expected):
    data = read(archive, owner=False)
    if len(expected) != 64 or any(c not in '0123456789abcdef' for c in expected) or hashlib.sha256(data).hexdigest() != expected:
        raise RuntimeError('Archive checksum verification failed; installation was not changed')
    members = {}
    with tarfile.open(fileobj=__import__('io').BytesIO(data), mode='r:gz') as tar:
        total = 0
        for count, entry in enumerate(tar):
            if count >= 256: raise RuntimeError('Archive member budget exceeded')
            path = PurePosixPath(entry.name)
            if path.is_absolute() or '..' in path.parts or not path.parts or any(ord(c) < 32 for c in entry.name) or not (entry.isdir() or entry.isfile()):
                raise RuntimeError('Unsafe archive entry')
            if entry.isfile():
                if entry.name in members or entry.size < 0: raise RuntimeError('Duplicate/invalid archive file')
                total += entry.size
                if total > MAXIMUM: raise RuntimeError('Archive expansion budget exceeded')
                members[entry.name] = tar.extractfile(entry).read(entry.size + 1)
                if len(members[entry.name]) != entry.size: raise RuntimeError('Incomplete archive member')
    manifest = json.loads(members['artifact.json'])
    arch = {'x86_64': 'x86_64', 'amd64': 'x86_64', 'aarch64': 'arm64', 'arm64': 'arm64'}.get(platform.machine())
    if manifest.get('schema') != 1 or manifest.get('architecture') != arch or set(manifest.get('binaries', {})) != set(BINARIES):
        raise RuntimeError('Archive architecture/schema/components do not match this host')
    for name in BINARIES:
        binary = members['bin/' + name]
        if binary[:6] != b'\x7fELF\x02\x01' or int.from_bytes(binary[18:20], 'little') != (62 if arch == 'x86_64' else 183) or hashlib.sha256(binary).hexdigest() != manifest['binaries'][name]:
            raise RuntimeError('Executable identity/checksum verification failed')
    return manifest, members

def install(home, manifest, members):
    identifier = str(uuid.uuid4()); stage = home / ('.bin-stage-' + identifier); stage.mkdir(mode=0o700)
    prepared = False
    try:
        old_snapshot = directory_identity(home / 'bin') if (home / 'bin').exists() else None
        copy_unrelated(home / 'bin', stage)
        for name in BINARIES: write(stage / name, members['bin/' + name], 0o755)
        write(stage / '.harness-artifact.json', members['artifact.json'])
        write(stage / '.harness-install-id', identifier.encode())
        if hashes(stage) != manifest['binaries']: raise RuntimeError('Staged verification failed')
        # Dynamic dependencies must already exist; no root package installation is hidden.
        for name in BINARIES:
            result = subprocess.run(['ldd', str(stage / name)], capture_output=True, text=True, timeout=10)
            if result.returncode or 'not found' in result.stdout or 'libswift' in result.stdout:
                raise RuntimeError('Runtime dependency check failed. Install the declared distribution packages first: ' + ', '.join(manifest['runtime_packages']))
        old = hashes(home / 'bin') if (home / 'bin').exists() else None
        if ((directory_identity(home / 'bin') if (home / 'bin').exists() else None) != old_snapshot): raise RuntimeError('Existing bin files changed during preparation; no installation was applied')
        json_write(journal_path(home), {'schema': 1, 'id': identifier, 'stage': stage.name, 'backup': '.bin-backup-' + identifier, 'old': old, 'new': manifest['binaries'], 'old_snapshot': old_snapshot, 'new_snapshot': directory_identity(stage)}); prepared = True
        recover(home)
    finally:
        if not prepared and stage.exists(): shutil.rmtree(stage)

def rollback(home):
    record = home / '.harness-rollback.json'
    if not record.exists(): raise RuntimeError('No previous binary directory is retained')
    value = json.loads(read(record, 1 << 20)); identifier = str(uuid.UUID(value['id']))
    if value.get('schema') != 1 or value['backup'] != '.bin-backup-' + identifier: raise RuntimeError('Invalid rollback identity')
    backup = home / value['backup']; info = owned(backup, directory=True)
    if (info.st_dev, info.st_ino) != (value['device'], value['inode']) or directory_identity(backup) != value['old_snapshot'] or directory_identity(home / 'bin') != value['new_snapshot']:
        raise RuntimeError('Installed or rollback binaries changed; refusing to overwrite them')
    # Journal rollback through the same recovery reducer, retaining the newer set.
    next_id = str(uuid.uuid4()); stage = home / ('.bin-stage-' + next_id); stage.mkdir(mode=0o700)
    prepared = False
    try:
        for path in backup.iterdir():
            if path.is_symlink(): os.symlink(os.readlink(path), stage / path.name)
            else: write(stage / path.name, read(path), stat.S_IMODE(path.stat().st_mode))
        if directory_identity(stage) != value['old_snapshot']: raise RuntimeError('Rollback staging verification failed')
        json_write(journal_path(home), {'schema': 1, 'id': next_id, 'stage': stage.name, 'backup': '.bin-backup-' + next_id, 'old': value['new'], 'new': value['old'], 'old_snapshot': value['new_snapshot'], 'new_snapshot': value['old_snapshot']}); prepared = True
        recover(home)
    finally:
        if not prepared and stage.exists(): shutil.rmtree(stage)

def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--archive', type=Path); parser.add_argument('--sha256'); parser.add_argument('--home', type=Path); parser.add_argument('--service', action='store_true'); parser.add_argument('--rollback', action='store_true'); parser.add_argument('--recover', action='store_true'); args = parser.parse_args()
    if platform.system() != 'Linux': raise RuntimeError('Linux archives install only on Linux')
    default = Path(os.environ.get('HARNESS_HOME') or str(Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share'))) / 'harness'))
    home = (args.home or default).absolute(); home.mkdir(parents=True, exist_ok=True, mode=0o700); owned(home, directory=True)
    fd = os.open(home / '.install.lock', os.O_WRONLY | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid(): raise RuntimeError('Invalid installation lock')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        recover(home)
        if args.rollback: rollback(home)
        elif not args.recover:
            if args.archive is None or args.sha256 is None: raise RuntimeError('Provide --archive and --sha256 from trusted artifact metadata')
            manifest, members = validate_archive(args.archive, args.sha256); install(home, manifest, members)
        print('Verified binaries: ' + str(home / 'bin') + '; running programs were not restarted')
        if args.service:
            if args.home or os.environ.get('HARNESS_HOME'): raise RuntimeError('Explicit homes do not modify shared systemd configuration. Run the binaries directly or configure a separate reviewed service')
            subprocess.run([str(home / 'bin/harness-cli'), 'install'], check=True)
    finally: os.close(fd)

if __name__ == '__main__':
    try: main()
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print('Harness installation: ' + str(error), file=__import__('sys').stderr); raise SystemExit(1)
