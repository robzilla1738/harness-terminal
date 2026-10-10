#!/usr/bin/env python3
"""Adopt a complete staged macOS bundle, preserving the prior bundle on failure.

The caller owns the staging directory and removes it only after success. This
helper never signals programs, writes service definitions, or follows destination
symlinks. Both directories must be on the same filesystem.
"""
import ctypes
import os
from pathlib import Path
import platform
import stat
import sys

def adopt(stage, destination):
    if platform.system() != 'Darwin': raise RuntimeError('Bundle exchange requires macOS')
    for path in (stage, destination.parent):
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid(): raise RuntimeError('Bundle staging and destination parent must be owned directories')
    if stage.stat().st_dev != destination.parent.stat().st_dev: raise RuntimeError('Bundle adoption requires one filesystem')
    if os.path.lexists(destination):
        info = destination.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid(): raise RuntimeError('Bundle destination is not an owned directory')
        library = ctypes.CDLL(None, use_errno=True); function = library.renamex_np
        function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]; function.restype = ctypes.c_int
        if function(os.fsencode(stage), os.fsencode(destination), 2): raise OSError(ctypes.get_errno(), 'Complete bundle exchange failed')
    else: os.rename(stage, destination)
    for parent in {stage.parent, destination.parent}:
        descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try: os.fsync(descriptor)
        finally: os.close(descriptor)

if __name__ == '__main__':
    if len(sys.argv) != 3: raise SystemExit('Usage: atomic-bundle.py STAGED_BUNDLE DESTINATION')
    adopt(*map(Path, sys.argv[1:]))
