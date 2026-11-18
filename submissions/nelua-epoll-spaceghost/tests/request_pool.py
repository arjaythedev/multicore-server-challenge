#!/usr/bin/env python3
"""Exercise pooling and reservation controls with host/private providers."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--memory', choices=('host', 'nelibc'), default='host')
parser.add_argument('--sanitize', action='store_true')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='nc-request-pool-') as tmp:
    for pool, reserve in ((0, 0), (0, 1), (1, 0), (1, 1)):
        binary = Path(tmp) / f'p{pool}-r{reserve}'
        flags = ['-std=gnu11', '-O1' if args.sanitize else '-O2', '-g', '-Wall', '-Wextra', '-Werror',
                 '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections', '-pthread',
                 '-I'+str(root/'src'), f'-DNC_REQUEST_POOL={pool}', f'-DNC_OUTPUT_RESERVE={reserve}',
                 '-DNC_BUFFER_CACHE=1']
        libraries = ['-lcrypto', '-lcrypt']
        if args.memory == 'nelibc':
            flags += ['-DNC_MEMORY_NELIBC']
            libraries += ['-Wl,--exclude-libs,nelibc-private.a', str(root/'build/nelibc-private.a'), '-ldl', '-lm']
        if args.sanitize:
            flags += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
        subprocess.run(shlex.split(os.environ.get('CC','cc'))+flags+[
            str(root/'tests/request_pool.c'),str(root/'src/request.c'),str(root/'src/bcrypt.c'),
            *libraries,'-o',str(binary)],check=True)
        print(f'memory={args.memory} pool={pool} reserve={reserve}',flush=True)
        subprocess.run([str(binary)],check=True,timeout=60,
                       env={**os.environ,'ASAN_OPTIONS':'detect_leaks=1'})
