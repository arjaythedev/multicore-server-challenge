#!/usr/bin/env python3
"""Compare actual request lifetimes with libc/private Nelibc; no DB/network.

Run only in Nelibc's authorized container, after a MEMORY_IMPL=nelibc build.
Raw JSONL records include process CPU time, wall time and consumed checksums.
This measures the shared hosted bridge, not the C/Nelua application languages.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--actions', type=int, default=262144)
parser.add_argument('--rounds', type=int, default=8)
parser.add_argument('--shapes', default='0')
parser.add_argument('--caches', default='0,1')
parser.add_argument('--pools', default='0,1')
args = parser.parse_args()
shapes = [int(value) for value in args.shapes.split(',')]
caches = [int(value) for value in args.caches.split(',')]
pools = [int(value) for value in args.pools.split(',')]
if (not 4 <= args.actions <= 10000000 or not 1 <= args.rounds <= 50 or
        len(set(shapes)) != len(shapes) or len(set(caches)) != len(caches) or
        len(set(pools)) != len(pools) or not pools or
        not set(shapes) <= {0, 1} or not set(caches) <= {0, 1} or not set(pools) <= {0, 1}):
    parser.error('invalid rounds/actions/shapes/caches')
archive = root / 'build/nelibc-private.a'
if not archive.is_file():
    raise SystemExit('Build MEMORY_IMPL=nelibc first')
metadata = {'type': 'metadata', 'scope': 'request/buffer/HMAC bridge, no network/database',
            'platform': list(platform.uname()), 'shapes': shapes, 'caches': caches,
            'rounds': args.rounds, 'actions': args.actions, 'pools': pools, 'output_reserve': 0,
            'compiler': subprocess.check_output(shlex.split(os.environ.get('CC', 'cc')) + ['--version'], text=True),
            'archive_sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
            'sources': {name: hashlib.sha256((root / name).read_bytes()).hexdigest()
                        for name in ('src/request.c', 'src/owned_memory.h', 'src/native.h',
                                     'src/bcrypt.c', 'src/bf_tables.h', 'tests/request_memory.c')}}
print(json.dumps(metadata), flush=True)
with tempfile.TemporaryDirectory(prefix='nc-request-memory-') as tmp:
    binaries = {}
    variants = [(memory, shape, cache, pool) for shape in shapes for cache in caches
                for pool in pools for memory in ('host', 'nelibc')]
    for memory, shape, cache, pool in variants:
        binary = Path(tmp) / (memory + '-s' + str(shape) + '-c' + str(cache) + '-p' + str(pool))
        flags = ['-std=gnu11', '-O3', '-flto', '-fno-semantic-interposition', '-march=native',
                 '-Wall', '-Wextra', '-Werror', '-ffunction-sections', '-fdata-sections',
                 '-I' + str(root / 'src'), '-DNC_MEMORY_SHAPE=' + str(shape),
                 '-DNC_BUFFER_CACHE=' + str(cache), '-DNC_REQUEST_POOL=' + str(pool), '-DNC_OUTPUT_RESERVE=0']
        libraries = ['-pthread', '-lcrypto', '-lcrypt']
        if memory == 'nelibc':
            flags += ['-DNC_MEMORY_NELIBC']
            libraries += ['-Wl,--exclude-libs,nelibc-private.a', str(archive), '-ldl', '-lm']
        subprocess.run(shlex.split(os.environ.get('CC', 'cc')) + flags + [
            str(root / 'src/request.c'), str(root / 'src/bcrypt.c'), str(root / 'tests/request_memory.c'),
            '-Wl,--gc-sections', *libraries, '-o', str(binary)], check=True)
        binaries[memory, shape, cache, pool] = binary
        print(json.dumps({'type': 'binary', 'memory': memory, 'shape': shape, 'cache': cache, 'pool': pool,
                          'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'flags': flags}), flush=True)
    expected = {}
    for round_ in range(args.rounds):
        for threads in (1, 4):
            for group in (1, 128):
                for mode in (0, 1, 2):
                    variants = list(binaries)
                    offset = round_ % len(variants)
                    variants = variants[offset:] + variants[:offset]
                    if (round_ // len(variants)) % 2:
                        variants.reverse()
                    for memory, shape, cache, pool in variants:
                        raw = subprocess.check_output([str(binaries[memory, shape, cache, pool]), str(threads), str(group),
                                                       str(mode), str(args.actions)], text=True)
                        record = json.loads(raw)
                        key = threads, group, mode
                        if key in expected and expected[key] != record['checksum']:
                            raise RuntimeError('memory providers/shapes produced different consumed output')
                        expected[key] = record['checksum']
                        record.update(memory=memory, shape=shape, cache=cache, pool=pool, round=round_, type='sample')
                        print(json.dumps(record), flush=True)
