#!/usr/bin/env python3
"""Check the optional read pipeline against PostgreSQL using literal SELECTs.

Set DATABASE_URL and, if needed, PG_CONFIG. No tables or database rows change.
The driver checks cold/warm preparation, result ownership, large responses,
SQL errors, aborted commands, timeouts, and recovery after its own backend exits.
"""
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
    url = os.environ.get('DATABASE_URL')
    if not url:
        parser.error('DATABASE_URL must select a PostgreSQL test server')
    config = shlex.split(os.environ.get('PG_CONFIG', 'pg_config'))
    include = subprocess.check_output(config + ['--includedir'], text=True).strip()
    library = subprocess.check_output(config + ['--libdir'], text=True).strip()
    compiler = shlex.split(os.environ.get('CC', 'cc'))
    flags = ['-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
             '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
             '-Wl,--wrap=PQclear',
             '-I' + str(ROOT / 'src'), '-I' + include,
             '-L' + library, '-Wl,-rpath,' + library]
    if args.sanitize:
        flags += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    with tempfile.TemporaryDirectory(prefix='nc-read-pipeline-') as tmp:
        binary = Path(tmp) / 'test'
        subprocess.run(compiler + flags + [str(ROOT / 'src/db.c'),
                       str(ROOT / 'tests/read_pipeline.c'), '-lpq', '-o', str(binary)],
                       check=True)
        try:
            # Namespace-restricted runners may deny LeakSanitizer's /proc task
            # scan. Address/undefined checks remain enabled; callers can opt in
            # to leak scanning through ASAN_OPTIONS when their host supports it.
            env = {**os.environ,
                   'ASAN_OPTIONS': os.environ.get('ASAN_OPTIONS', 'detect_leaks=0')}
            result = subprocess.run([str(binary), url], timeout=60, env=env)
        except subprocess.TimeoutExpired:
            # DATABASE_URL may contain credentials; do not print command argv.
            parser.exit(1, 'FAIL: read pipeline driver timed out\n')
        if result.returncode:
            parser.exit(1, 'FAIL: read pipeline driver failed\n')


if __name__ == '__main__':
    main()
