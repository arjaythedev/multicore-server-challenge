#!/usr/bin/env python3
"""The native host owns allocation; generated Nelua must stay runtime-free."""
from pathlib import Path
import argparse
import re
import subprocess

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--implementation',choices=['c','nelua'],default='nelua')
parser.add_argument('--binary',default='bin/conduit')
parser.add_argument('--memory',choices=['host','nelibc'],default='host')
args=parser.parse_args()
if args.implementation=='nelua':
    source=Path('build/app.c').read_text()
    for pattern in (r'\bnelua_(?:gc|panic|assert|error|abort)',r'\b(?:lua_|GC_)',
                    r'\b(?:malloc|calloc|realloc|free|abort|exit)\s*\('):
        if re.search(pattern,source):
            raise SystemExit('unexpected runtime/allocation path in generated Nelua C: '+pattern)
    if re.search(r'\bmain\s*\(',source):
        raise SystemExit('unexpected Nelua main; native transport is the sole host entrypoint')
    print('audit passed: no Nelua VM, GC, allocator, panic, or initialization entrypoint')
else:
    symbols=subprocess.check_output(['nm','--defined-only',args.binary],text=True)
    # A private Nelibc archive is itself compiled from Nelua. Its own local
    # string literals are not C application logic. Public C/Nelua scanner
    # implementations still must not be mixed in this profile.
    pattern=r'\b\S*(?:nelua_|_nelua)\S*$' if args.memory=='host' else r'\bnc_json_prefix_\w+_nelua\b'
    if re.search(pattern,symbols,re.M):
        raise SystemExit('unexpected Nelua implementation linked into the C counterpart')
    print('audit passed: independently authored C application; no Nelua application/scanner implementation linked')
if args.memory=='nelibc':
    symbols=subprocess.check_output(['nm','--defined-only',args.binary],text=True)
    if 'nc_nelibc_nelibc_malloc' not in symbols or 'nc_nelibc_memcpy' not in symbols:
        raise SystemExit('private Nelibc allocation/copy implementation missing')
    dynamic=subprocess.check_output(['nm','-D','--defined-only',args.binary],text=True)
    if 'nc_nelibc_' in dynamic:
        raise SystemExit('private Nelibc symbols leaked into the hosted-library dynamic ABI')
    print('audit passed: private Nelibc allocator/copy symbols linked and hidden from dynamic libraries')
subprocess.run(['size',args.binary],check=True)
