#!/usr/bin/env python3
"""Deterministic pressure/admission policy checks; no host tuning or SQL."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='nc-read-policy-') as tmp:
    binary = Path(tmp) / 'test'
    subprocess.run(shlex.split(os.environ.get('CC', 'cc')) + [
        '-std=gnu11', '-O2', '-g', '-Wall', '-Wextra', '-Werror',
        '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
        '-I' + str(root / 'src'), str(root / 'src/read_policy.c'),
        str(root / 'tests/read_policy.c'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=10,
                   env={**os.environ, 'ASAN_OPTIONS': 'detect_leaks=0'})
