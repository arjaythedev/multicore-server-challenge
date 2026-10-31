#!/usr/bin/env python3
"""Exercise generated Nelua tag batches without a PostgreSQL server.

Build the app first. --baseline-app can select older generated C for an optional
component benchmark; the mock returns a fresh libpq result for every batch.
"""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sanitize', action='store_true')
    p.add_argument('--baseline-app', type=Path)
    p.add_argument('--benchmark', type=int, default=0, metavar='BATCHES')
    a = p.parse_args()
    if not 0 <= a.benchmark <= 10000:
        p.error('benchmark batches must be 0..10000')
    config = shlex.split(os.environ.get('PG_CONFIG', 'pg_config'))
    include = subprocess.check_output(config + ['--includedir'], text=True).strip()
    library = subprocess.check_output(config + ['--libdir'], text=True).strip()
    flags = ['-std=gnu11', '-O1' if a.sanitize else '-O3', '-g',
             '-Wall', '-Wextra', '-Werror', '-ffunction-sections', '-fdata-sections',
             '-Wl,--gc-sections', '-Wl,--wrap=nc_db_query', '-Wl,--wrap=PQgetvalue',
             '-Wl,--wrap=realloc', '-I' + str(ROOT / 'src'), '-I' + include,
             '-L' + library, '-Wl,-rpath,' + library]
    if a.sanitize:
        flags += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    apps = [(ROOT / 'build/app.c', 0)]
    if a.baseline_app:
        apps.append((a.baseline_app.resolve(), 1))
    with tempfile.TemporaryDirectory(prefix='nc-tags-batch-') as tmp:
        binaries = []
        for app, baseline in apps:
            binary = Path(tmp) / ('baseline' if baseline else 'candidate')
            subprocess.run(shlex.split(os.environ.get('CC', 'cc')) + flags +
                           [str(app), str(ROOT / 'src/request.c'), str(ROOT / 'src/bcrypt.c'),
                            str(ROOT / 'src/db.c'), str(ROOT / 'tests/tags_batch.c'),
                            '-pthread', '-lpq', '-lcrypto', '-lcrypt', '-o', str(binary)], check=True)
            subprocess.run([str(binary), '0', str(baseline)], check=True, timeout=30,
                           env={**os.environ, 'ASAN_OPTIONS': os.environ.get('ASAN_OPTIONS', 'detect_leaks=0')})
            binaries.append((binary, baseline))
        if a.benchmark:
            order = binaries if len(binaries) == 1 else [binaries[1], binaries[0], binaries[0], binaries[1]]
            for binary, baseline in order:
                subprocess.run([str(binary), str(a.benchmark), str(baseline)], check=True, timeout=120)


if __name__ == '__main__':
    main()
