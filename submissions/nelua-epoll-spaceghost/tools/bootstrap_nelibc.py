#!/usr/bin/env python3
"""Build pinned private-Nelibc dependencies from source, without Zig binaries.

The Nelibc fork compiler is a build-only dependency. The application continues
to use its separate official Nelua pin. Agents must run this in the environment
authorized by Nelibc's AGENTS.md; this script does not alter that policy.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess

LIBRARY_REVISION = '73ae254aa0f4cc1fa03f8fad92711c497e9c28fc'
COMPILER_REVISION = 'dabbd9effebb7ecfe59a727f49f27b4574109d4d'


def git(path, *arguments, capture=False):
    cmd = ['git', '-C', str(path), *arguments]
    if capture:
        return subprocess.check_output(cmd, text=True).strip()
    subprocess.run(cmd, check=True)


def checkout(path, repository, revision):
    if not (path / '.git').exists():
        if path.exists() and any(path.iterdir()):
            raise RuntimeError('dependency directory contains unmanaged files: ' + str(path))
        path.mkdir(parents=True, exist_ok=True)
        git(path, 'init', '-q')
        git(path, 'remote', 'add', 'origin', repository)
    head = subprocess.run(['git', '-C', str(path), 'rev-parse', '--verify', 'HEAD'],
                          capture_output=True, text=True)
    if head.returncode:
        if git(path, 'status', '--porcelain', capture=True):
            raise RuntimeError('incomplete checkout contains work: ' + str(path))
        git(path, 'fetch', '--depth=1', 'origin', revision)
        git(path, 'checkout', '--detach', 'FETCH_HEAD')
    if git(path, 'rev-parse', 'HEAD', capture=True) != revision:
        raise RuntimeError('dependency revision differs: ' + str(path))
    if subprocess.run(['git', '-C', str(path), 'diff', '--quiet', 'HEAD', '--']).returncode:
        raise RuntimeError('dependency has tracked changes: ' + str(path))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=2)
    args = parser.parse_args()
    cache = args.cache.resolve()
    if any(character.isspace() for character in str(cache)):
        parser.error('upstream Makefile requires a cache path without whitespace')
    if not 1 <= args.jobs <= 16:
        parser.error('jobs must be 1..16')
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / '.source-build.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        build(args, cache)


def build(args, cache):
    source = cache / ('nelibc-' + LIBRARY_REVISION[:8])
    compiler = cache / ('nelua-' + COMPILER_REVISION[:8])
    compiler_cache = cache / 'compiler-cache'
    # Keep the driver path outside the repository too, matching the upstream
    # Makefile's whitespace-free OUT/NELUA/ZIG command assumptions.
    auxiliary = cache / 'gcc-aux.sh'
    auxiliary.write_bytes(Path(__file__).with_name('gcc_aux.sh').read_bytes())
    auxiliary.chmod(0o755)
    checkout(source, 'https://github.com/Spaceghost/nelibc.git', LIBRARY_REVISION)
    checkout(compiler, 'https://github.com/Spaceghost/nelua-lang.git', COMPILER_REVISION)
    subprocess.run(['make', '-C', str(compiler), '-j' + str(args.jobs)], check=True)
    cc = os.environ.get('NC_AUX_GCC', 'gcc')
    compiler_version = subprocess.check_output(['gcc', '--version'], text=True)
    identity = {'source_revision': LIBRARY_REVISION, 'compiler_revision': COMPILER_REVISION,
                'gcc': compiler_version,
                'auxiliary_compiler': subprocess.check_output([cc, '--version'], text=True),
                'compiler_entry_sha256': digest(compiler / 'nelua'),
                'auxiliary_sha256': digest(auxiliary),
                'profile': 'hybrid GCC archive; shared assembly/C ABI auxiliaries also compiled with GCC'}
    configuration = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()[:16]
    output = cache / ('gcc-archive-' + configuration)
    nelua = shlex.quote(str(compiler / 'nelua')) + ' --cache-dir ' + shlex.quote(str(compiler_cache))
    command = ['make', '-C', str(source), 'lib-gcc', 'OUT=' + str(output),
               'NELUA=' + nelua, 'ZIG=' + str(auxiliary), 'ZIGFLAGS=']
    archive = output / 'libnelibc-gcc.a'
    stamp = output / 'conduit-source-build.json'
    previous = json.loads(stamp.read_text()) if stamp.exists() else None
    matches = previous and all(previous.get(key) == value for key, value in identity.items())
    if matches and archive.is_file() and previous.get('archive_sha256') != digest(archive):
        raise RuntimeError('cached Nelibc archive changed; use a fresh NELIBC_CACHE')
    if not (matches and archive.is_file() and previous.get('archive_sha256') == digest(archive)):
        subprocess.run(command, check=True)
        identity['archive_sha256'] = digest(archive)
        stamp.write_text(json.dumps(identity, indent=2) + '\n')
    else:
        identity = previous
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(dict(identity, source=str(source), archive=str(archive),
                                            command=command), indent=2) + '\n')
    print('PASS: pinned Nelibc archive built from source; application compiler unchanged')


if __name__ == '__main__':
    main()
