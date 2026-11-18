#!/usr/bin/env python3
"""Exercise the epoll/libpq scheduler against a disposable PostgreSQL server.

No tables are changed. The test terminates one of its own database sessions.
"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
url = os.environ.get('DATABASE_URL')
if not url:
    raise SystemExit('DATABASE_URL must select a PostgreSQL test server')
config = shlex.split(os.environ.get('PG_CONFIG', 'pg_config'))
include = subprocess.check_output(config + ['--includedir'], text=True).strip()
library = subprocess.check_output(config + ['--libdir'], text=True).strip()
with tempfile.TemporaryDirectory(prefix='nc-read-reactor-') as tmp:
    binary = Path(tmp) / 'test'
    subprocess.run(shlex.split(os.environ.get('CC', 'cc')) + [
        '-std=gnu11', '-O2', '-g', '-Wall', '-Wextra', '-Werror',
        '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
        '-fsanitize=undefined', '-fno-omit-frame-pointer',
        '-I' + str(root / 'src'), '-I' + include,
        '-L' + library, '-Wl,-rpath,' + library,
        str(root / 'src/db.c'), str(root / 'src/reactor.c'),
        str(root / 'tests/read_reactor.c'), '-lpq', '-o', str(binary)], check=True)
    try:
        result = subprocess.run([str(binary), url], timeout=30)
    except subprocess.TimeoutExpired:
        raise SystemExit('FAIL: read reactor timed out') from None
    if result.returncode:
        raise SystemExit('FAIL: read reactor driver failed')
