#!/usr/bin/env python3
"""Compile the generated Nelua serializer against an independent scalar oracle."""
import argparse
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sanitize', action='store_true')
    parser.add_argument('--generated-c', type=Path, default=ROOT / 'build/app.c')
    parser.add_argument('--implementation', choices=['c', 'nelua'], default='nelua')
    parser.add_argument('--benchmark', type=int, default=0)
    parser.add_argument('--modes', default=None,
                        help='comma-separated JSON_SCAN modes; defaults to the current environment')
    parser.add_argument('--rounds', type=int, default=1)
    parser.add_argument('--memory', choices=['host', 'nelibc'], default='host')
    parser.add_argument('--reserve', type=int, choices=[0, 1], default=1)
    parser.add_argument('--compile-only', type=Path, help='copy the test executable here without running it')
    args = parser.parse_args()
    if not 1 <= args.rounds <= 50 or not 0 <= args.benchmark <= 10000000:
        parser.error('rounds must be1..50 and benchmark loops0..10000000')
    config = shlex.split(os.environ.get('PG_CONFIG', 'pg_config'))
    include = subprocess.check_output(config + ['--includedir'], text=True).strip()
    flags = ['-std=gnu11', '-O1' if args.sanitize else '-O3', '-g', '-Wall', '-Wextra', '-Werror',
             '-ffunction-sections', '-fdata-sections', '-Wl,--gc-sections',
             '-I' + str(ROOT / 'src'), '-I' + include, '-DNC_OUTPUT_RESERVE='+str(args.reserve)]
    libraries = ['-pthread', '-lpq', '-lcrypto', '-lcrypt']
    if args.memory == 'nelibc':
        flags += ['-DNC_MEMORY_NELIBC', '-DNC_BUFFER_CACHE=1']
        libraries += ['-Wl,--exclude-libs,nelibc-private.a', str(ROOT/'build/nelibc-private.a'), '-ldl', '-lm']
    if args.sanitize:
        flags += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    elif args.benchmark:
        flags += ['-flto', '-fno-semantic-interposition', '-march=native']
    application = [str(args.generated_c)]
    if args.implementation == 'c':
        flags += ['-DNC_APP_C']
        application = [str(ROOT / p) for p in ('src/app_c.c', 'src/batch_c.c', 'src/serialize_c.c')]
    with tempfile.TemporaryDirectory(prefix='nc-serialize-') as directory:
        binary = Path(directory) / 'test'
        sources = [ 'src/request.c', 'src/bcrypt.c', 'src/db.c', 'src/json_scan.c',
                    'src/json_dispatch.c', 'tests/serialize_scan.c']
        subprocess.run(shlex.split(os.environ.get('CC', 'cc')) + flags +
                       application + [str(ROOT / p) for p in sources] +
                       libraries + ['-o', str(binary)], check=True)
        if args.compile_only:
            args.compile_only.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(binary,args.compile_only)
            return
        modes = args.modes.split(',') if args.modes else [os.environ.get('JSON_SCAN', 'legacy')]
        for repetition in range(args.rounds):
            rotation = repetition % len(modes)
            for mode in modes[rotation:] + modes[:rotation]:
                print('JSON_SCAN=' + mode + ' repetition=' + str(repetition), flush=True)
                subprocess.run([str(binary)] + ([str(args.benchmark)] if args.benchmark else []), check=True, timeout=120,
                               env={**os.environ, 'JSON_SCAN': mode, 'ASAN_OPTIONS': 'detect_leaks=0'})


if __name__ == '__main__':
    main()
