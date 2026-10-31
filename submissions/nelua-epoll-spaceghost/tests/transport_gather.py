#!/usr/bin/env python3
"""Check real transport gathering ownership, parallel execution, and shutdown."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sanitize', action='store_true')
    args = parser.parse_args()
    cc = shlex.split(os.environ.get('CC', 'cc'))
    flags = ['-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
             '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
             '-I' + str(ROOT / 'src'), '-pthread']
    if args.sanitize:
        flags += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    with tempfile.TemporaryDirectory(prefix='nc-transport-gather-') as tmp:
        binary = Path(tmp) / 'test'
        subprocess.run(cc + flags + [str(ROOT / 'tests/transport_gather.c'),
                                    '-o', str(binary)], check=True)
        for serial in (0, 1):
            for early in (0, 1):
                subprocess.run([str(binary), str(serial), str(early)], check=True,
                               timeout=10, env={**os.environ, 'ASAN_OPTIONS': 'detect_leaks=0'})


if __name__ == '__main__':
    main()
