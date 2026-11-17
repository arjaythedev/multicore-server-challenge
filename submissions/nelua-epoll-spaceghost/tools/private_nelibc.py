#!/usr/bin/env python3
"""Namespace a pinned Nelibc archive without interposing on hosted libraries.

Run only in the build environment authorized by Nelibc's AGENTS.md. This does
not rebuild or modify Nelibc. Every defined symbol and internal reference is
renamed; undefined host imports retain their original names. The linker must
also use --exclude-libs to keep the private archive out of the dynamic ABI.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

REVISION = '73ae254aa0f4cc1fa03f8fad92711c497e9c28fc'


def exports(archive):
    result = set()
    output = subprocess.check_output(['nm', '-g', '--defined-only', '-j', str(archive)], text=True)
    for line in output.splitlines():
        if not line or line.endswith(':'):
            continue
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', line):
            raise SystemExit('unexpected archive symbol: ' + line)
        result.add(line)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    revision = subprocess.check_output(['git', '-C', str(args.source), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != REVISION or subprocess.run(['git', '-C', str(args.source), 'diff', '--quiet', 'HEAD', '--']).returncode:
        raise SystemExit('expected unmodified Nelibc at ' + REVISION)
    names = exports(args.archive)
    required = {'nelibc_malloc', 'nelibc_calloc', 'nelibc_realloc', 'nelibc_free',
                'nelibc_allocator_owns', 'memcpy', 'memmove', 'memset'}
    if not required <= names:
        raise SystemExit('archive lacks required ownership/allocation symbols')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='private-nelibc-', dir=args.output.parent) as tmp:
        mapping = Path(tmp) / 'symbols'
        mapping.write_text(''.join(name + ' nc_nelibc_' + name + '\n' for name in sorted(names)))
        target = Path(tmp) / 'private.a'
        subprocess.run(['objcopy', '--redefine-syms=' + str(mapping), str(args.archive), str(target)], check=True)
        if exports(target) != {'nc_nelibc_' + name for name in names}:
            raise SystemExit('private archive export namespace is incomplete')
        target.replace(args.output)
    manifest = {'source_revision': revision, 'source_archive_sha256': hashlib.sha256(args.archive.read_bytes()).hexdigest(),
                'private_archive_sha256': hashlib.sha256(args.output.read_bytes()).hexdigest(),
                'renamed_exports': len(names), 'profile': 'private hybrid Nelibc; hosted imports remain hosted'}
    args.output.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('PASS: namespaced', len(names), 'Nelibc exports; original archive unchanged')


if __name__ == '__main__':
    main()
