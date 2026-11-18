#!/usr/bin/env python3
"""Audit the actual freestanding application object linked into the server.

The allowed host boundary is the declared native.h API plus the three memory
primitives a C compiler may emit for aggregate operations. This is not an audit
claim about the hosted libpq/OpenSSL bridge or the entire ELF executable.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('object', type=Path)
parser.add_argument('--implementation', choices=['c', 'nelua'], required=True)
args = parser.parse_args()
allowed = set(re.findall(r'\b((?:nc_|conduit_)\w+)\s*\(', (ROOT / 'src/native.h').read_text()))
allowed |= {'memcpy', 'memmove', 'memset'}
output = subprocess.check_output(['nm', '-u', str(args.object)], text=True)
undefined = {line.split()[-1] for line in output.splitlines() if line.strip()}
unexpected = undefined - allowed
if unexpected:
    raise SystemExit('unexpected freestanding core imports: ' + repr(sorted(unexpected)))
if not undefined:
    raise SystemExit('core object unexpectedly has no native API boundary')
manifest = {'implementation': args.implementation,
            'scope': 'freestanding application object; native bridge and complete executable remain hosted',
            'sha256': hashlib.sha256(args.object.read_bytes()).hexdigest(),
            'undefined_symbols': sorted(undefined)}
args.object.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('PASS:', args.implementation, 'freestanding core imports only the declared native ABI and compiler memory primitives')
