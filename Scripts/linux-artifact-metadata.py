#!/usr/bin/env python3
"""Collect actual ELF/runtime metadata inside the locked builder; no installs."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

output = Path(sys.argv[1])
packages = {}
dependencies = {}
for binary in sorted((output / 'bin').iterdir()):
    data = binary.read_bytes()
    if data[:4] != b'\x7fELF' or data[4] != 2 or data[5] != 1:
        raise RuntimeError('Expected little-endian 64-bit ELF executable')
    machine = int.from_bytes(data[18:20], 'little')
    expected = 62 if os.environ['HARNESS_PACKAGE_ARCH'] == 'x86_64' else 183
    if machine != expected:
        raise RuntimeError('Executable architecture does not match archive')
    lines = (output / (binary.name + '.dependencies')).read_text()
    if 'not found' in lines or 'libswift' in lines:
        raise RuntimeError('Unresolved or dynamic Swift runtime dependency')
    libraries = []
    for path in re.findall(r'(?:=>\s*)?(/[^\s]+)', lines):
        library = Path(path).resolve()
        libraries.append(library.name)
        result = subprocess.run(['dpkg-query', '-S', str(library)], capture_output=True, text=True)
        if result.returncode:
            # usrmerge aliases may be the path registered in dpkg.
            alias = str(library).replace('/usr/lib/', '/lib/', 1)
            result = subprocess.run(['dpkg-query', '-S', alias], capture_output=True, text=True, check=True)
        package = result.stdout.split(': /', 1)[0].splitlines()[0]
        version = subprocess.check_output(['dpkg-query', '-W', '-f=${Version}', package], text=True)
        packages[package] = version
    dependencies[binary.name] = sorted(set(libraries))
    (output / (binary.name + '.dependencies')).unlink()
manifest = {
    'schema': 1, 'architecture': os.environ['HARNESS_PACKAGE_ARCH'],
    'source_sha256': os.environ['HARNESS_SOURCE_SHA256'],
    'toolchain_image': os.environ['HARNESS_BUILDER_IMAGE'],
    'swift_version': '6.0.3', 'swift_linkage': 'static', 'build_jobs': int(os.environ['HARNESS_BUILD_JOBS']),
    'runtime_baseline': 'Ubuntu 22.04 / glibc >= 2.35; declared distribution libraries',
    'runtime_packages': dict(sorted(packages.items())), 'dynamic_libraries': dependencies,
    'binaries': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((output / 'bin').iterdir())}
}
(output / 'artifact.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
