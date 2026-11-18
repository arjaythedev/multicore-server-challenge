#!/usr/bin/env python3
"""Check live request accounting with host/private Nelibc ownership."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sanitize', action='store_true')
parser.add_argument('--memory', choices=('host', 'nelibc'), default='host')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='nc-request-budget-') as tmp:
    for cache in (0, 1):
        binary = Path(tmp) / str(cache)
        flags = ['-std=gnu11', '-O1' if args.sanitize else '-O2', '-g', '-Wall', '-Wextra', '-Werror',
                 '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
                 '-I' + str(root / 'src'), '-DNC_BUFFER_CACHE=' + str(cache)]
        libraries = ['-pthread', '-lcrypto', '-lcrypt']
        if args.memory == 'nelibc':
            flags += ['-DNC_MEMORY_NELIBC']
            archive = root / 'build/nelibc-private.a'
            if not archive.is_file():
                raise SystemExit('Build MEMORY_IMPL=nelibc first')
            libraries += ['-Wl,--exclude-libs,nelibc-private.a', str(archive), '-ldl', '-lm']
        if args.sanitize:
            flags += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
        subprocess.run(shlex.split(os.environ.get('CC', 'cc')) + flags + [
            str(root / 'tests/request_budget.c'), str(root / 'src/request.c'),
            str(root / 'src/bcrypt.c'), *libraries, '-o', str(binary)], check=True)
        print(f'memory={args.memory} cache={cache}', flush=True)
        env = {**os.environ, 'REQUEST_MEMORY_MB': '1', 'ASAN_OPTIONS': 'detect_leaks=1'}
        subprocess.run([str(binary)], check=True, timeout=60, env=env)
        for invalid in ('0', '4097', 'bad', '-1', '18446744073709551616'):
            subprocess.run([str(binary), 'invalid'], check=True, timeout=5,
                           env={**env, 'REQUEST_MEMORY_MB': invalid})
