#!/usr/bin/env python3
"""Compile matching freestanding C/Nelua scanner objects and compare them.

Only the driver uses the host libc. The scanner objects must have no undefined
symbols. This does not build or test nelibc itself.
"""
import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--benchmark', type=int, default=0, metavar='ROUNDS')
    parser.add_argument('--sanitize', action='store_true')
    args = parser.parse_args()
    if not 0 <= args.benchmark <= 50:
        parser.error('benchmark rounds must be0..50')
    compiler = shlex.split(os.environ.get('CC', 'cc'))
    nelua = Path(os.environ.get('NELUA_ROOT', ROOT / '.deps/nelua')) / 'nelua'
    with tempfile.TemporaryDirectory(prefix='nc-json-scan-') as tmp:
        folder = Path(tmp)
        generated = subprocess.check_output([
            str(nelua), '--cache-dir', str(folder / 'cache'), '--no-cache',
            '--release', '--print-code', 'json_scan.nelua'], cwd=ROOT / 'src', text=True)
        if re.search(r'\b(?:nelua_(?:gc|panic|assert|error|abort)|lua_|GC_|malloc|calloc|realloc|free)\b', generated):
            raise SystemExit('unexpected runtime import in generated scanner')
        source = folder / 'scan.c'
        source.write_text(generated)
        flags = ['-std=gnu11', '-O3', '-Wall', '-Wextra', '-Werror',
                 '-march=x86-64', '-I' + str(ROOT / 'src')]
        objects = []
        for label, path in [('c', ROOT / 'src/json_scan.c'), ('nelua', source)]:
            obj = folder / (label + '.o')
            subprocess.run(compiler + flags + [
                '-ffreestanding', '-fno-builtin', '-fno-stack-protector',
                '-c', str(path), '-o', str(obj)], check=True)
            undefined = subprocess.check_output(['nm', '-u', str(obj)], text=True).strip()
            if undefined:
                raise SystemExit(label + ' scanner has undefined symbols: ' + undefined)
            print('PASS: ' + label + ' scanner object has no undefined symbols', flush=True)
            objects.append(str(obj))
        # Compile a separately instrumented set for boundary checks. The audit
        # above describes the production freestanding objects, not sanitizer ABI.
        if args.sanitize:
            flags += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
            objects = [str(ROOT / 'src/json_scan.c'), str(source)]
        binary = folder / 'test'
        subprocess.run(compiler + flags + objects + [
            str(ROOT / 'tests/json_scan.c'), '-o', str(binary)], check=True)
        result = subprocess.run([str(binary)] + ([str(args.benchmark)] if args.benchmark else []),
                                timeout=180, env={**os.environ, 'ASAN_OPTIONS': 'detect_leaks=0'})
        if result.returncode:
            raise SystemExit('FAIL: JSON scanner driver failed')


if __name__ == '__main__':
    main()
