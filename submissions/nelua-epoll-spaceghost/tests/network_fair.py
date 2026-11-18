#!/usr/bin/env python3
"""Check network fair/control paths on real Linux sockets; no database."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sanitize', action='store_true')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='nc-network-fair-') as tmp:
    for fair in (0, 1):
        binary = Path(tmp) / str(fair)
        flags = ['-std=gnu11', '-O2', '-g', '-Wall', '-Wextra', '-Werror',
                 '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
                 '-DNC_NET_FAIR=' + str(fair), '-I' + str(root / 'src')]
        if args.sanitize:
            flags += ['-O1', '-fsanitize=address,undefined', '-fno-omit-frame-pointer']
        subprocess.run(shlex.split(os.environ.get('CC', 'cc')) + flags + [
            str(root / 'tests/network_fair.c'), str(root / 'src/request.c'),
            str(root / 'src/bcrypt.c'), str(root / 'src/read_policy.c'), '-pthread', '-lcrypto', '-lcrypt',
            '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=30,
                       env={**os.environ, 'ASAN_OPTIONS': 'detect_leaks=0'})
