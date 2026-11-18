#!/usr/bin/env python3
"""Verify allocator boundaries against the already built private Nelibc archive.

Run in the Nelibc-authorized build environment after MEMORY_IMPL=nelibc build.
"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
config = shlex.split(os.environ.get('PG_CONFIG', 'pg_config'))
include = subprocess.check_output(config + ['--includedir'], text=True).strip()
library = subprocess.check_output(config + ['--libdir'], text=True).strip()
archive = root / 'build/nelibc-private.a'
if not archive.is_file():
    raise SystemExit('Build MEMORY_IMPL=nelibc first')
with tempfile.TemporaryDirectory(prefix='nc-memory-ownership-') as tmp:
    binary = Path(tmp) / 'test'
    subprocess.run(shlex.split(os.environ.get('CC', 'cc')) + [
        '-std=gnu11', '-O2', '-g', '-Wall', '-Wextra', '-Werror',
        '-DNC_APP_C', '-DNC_MEMORY_NELIBC', '-ffunction-sections', '-fdata-sections',
        '-I' + str(root / 'src'), '-I' + include,
        '-L' + library, '-Wl,-rpath,' + library,
        *[str(root / p) for p in ('src/request.c', 'src/bcrypt.c', 'src/serialize_c.c',
                                  'src/json_scan.c', 'src/json_dispatch.c', 'tests/memory_ownership.c')],
        '-Wl,--gc-sections', '-pthread', '-lpq', '-lcrypto', '-lcrypt',
        '-Wl,--wrap=nc_nelibc_nelibc_free',
        '-Wl,--exclude-libs,nelibc-private.a', str(archive), '-ldl', '-lm', '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
