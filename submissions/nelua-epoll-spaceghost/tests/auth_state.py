#!/usr/bin/env python3
"""Check HMAC context lifetime, independent signatures, rotation, and failures."""
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
    compiler = shlex.split(os.environ.get('CC', 'cc'))
    flags = ['-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
             '-I' + str(ROOT / 'src')]
    if args.sanitize:
        flags += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    for function in ('EVP_MAC_CTX_new', 'EVP_MAC_CTX_free', 'EVP_MAC_init',
                     'EVP_MAC_update', 'EVP_MAC_final'):
        flags += ['-Wl,--wrap=' + function]
    with tempfile.TemporaryDirectory(prefix='nc-auth-state-') as directory:
        binary = Path(directory) / 'test'
        subprocess.run(compiler + flags + [str(ROOT / 'src/request.c'),
            str(ROOT / 'src/bcrypt.c'), str(ROOT / 'tests/auth_state.c'),
            '-pthread', '-lcrypto', '-lcrypt', '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=30,
                       env={**os.environ, 'ASAN_OPTIONS': 'detect_leaks=0'})


if __name__ == '__main__':
    main()
