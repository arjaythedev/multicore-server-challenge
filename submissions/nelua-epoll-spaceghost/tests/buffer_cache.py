#!/usr/bin/env python3
"""Check bounded storage reuse; private Nelibc checks require its build host."""
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
with tempfile.TemporaryDirectory(prefix='nc-buffer-cache-') as tmp:
    for cache, shape in ((0, 0), (1, 0), (1, 1)):
        binary = Path(tmp) / f'c{cache}-s{shape}'
        flags = ['-std=gnu11', '-O1' if args.sanitize else '-O2', '-g', '-Wall', '-Wextra', '-Werror',
                 '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections', '-I' + str(root / 'src'),
                 '-DNC_BUFFER_CACHE=' + str(cache), '-DNC_MEMORY_SHAPE=' + str(shape)]
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
            str(root / 'tests/buffer_cache.c'), str(root / 'src/request.c'),
            str(root / 'src/bcrypt.c'), *libraries, '-o', str(binary)], check=True)
        print(f'memory={args.memory} cache={cache} shape={shape}', flush=True)
        subprocess.run([str(binary)], check=True, timeout=60,
                       env={**os.environ, 'ASAN_OPTIONS': 'detect_leaks=1'})
