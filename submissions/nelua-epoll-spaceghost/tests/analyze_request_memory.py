#!/usr/bin/env python3
"""Reject incomplete request-memory matrices before reporting component timings."""
import argparse
import itertools
import json
from pathlib import Path
import statistics


def analyze(path):
    records = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    metadata = [r for r in records if r.get('type') == 'metadata']
    if len(metadata) != 1 or records[0] != metadata[0]:
        raise ValueError('expected exactly one leading metadata record')
    meta = metadata[0]
    variants = list(itertools.product(meta['shapes'], meta['caches'], ('host', 'nelibc')))
    expected_variants = {(memory, shape, cache) for shape, cache, memory in variants}
    binaries = [r for r in records if r.get('type') == 'binary']
    if (len(binaries) != len(expected_variants) or
            {(r['memory'], r['shape'], r['cache']) for r in binaries} != expected_variants):
        raise ValueError('incomplete or duplicate binary provenance')
    for record in [*binaries, {'sha256': meta['archive_sha256']}]:
        digest = record['sha256']
        if len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
            raise ValueError('invalid artifact hash')
    samples = [r for r in records if r.get('type') == 'sample']
    if len(records) != 1 + len(binaries) + len(samples):
        raise ValueError('unknown record type')
    expected = set(itertools.product(range(meta['rounds']), (1, 4), (1, 128), (0, 1, 2),
                                     expected_variants))
    observed, checksums, groups = set(), {}, {}
    for r in samples:
        variant = r['memory'], r['shape'], r['cache']
        key = r['round'], r['threads'], r['group'], r['mode'], variant
        if key not in expected or key in observed:
            raise ValueError('unexpected or duplicate sample: ' + str(key))
        observed.add(key)
        if (r['actions'] != meta['actions'] or r['cpu_ns'] <= 0 or r['wall_ns'] <= 0 or
                not 0 <= r['retained_bytes'] <= 32 * 1024**2 or
                (not r['cache'] and r['retained_bytes'])):
            raise ValueError('invalid timing, action count or storage bound')
        workload = r['threads'], r['group'], r['mode']
        if checksums.setdefault(workload, r['checksum']) != r['checksum']:
            raise ValueError('consumed output differs between variants/rounds')
        group = (*workload, *variant)
        groups.setdefault(group, []).append(r)
    if observed != expected:
        raise ValueError(f'incomplete matrix: {len(observed)}/{len(expected)} samples')
    # Confirm the declared Latin rotation, including order within each workload.
    ordered = [(memory, shape, cache) for shape, cache, memory in variants]
    for round_ in range(meta['rounds']):
        offset = round_ % len(ordered)
        rotation = ordered[offset:] + ordered[:offset]
        if (round_ // len(ordered)) % 2:
            rotation.reverse()
        for workload in itertools.product((1, 4), (1, 128), (0, 1, 2)):
            actual = [(r['memory'], r['shape'], r['cache']) for r in samples
                      if (r['round'], r['threads'], r['group'], r['mode']) == (round_, *workload)]
            if actual != rotation:
                raise ValueError('unexpected variant execution order')
    summary = []
    for key, values in sorted(groups.items()):
        row = dict(zip(('threads', 'group', 'mode', 'memory', 'shape', 'cache'), key))
        for metric in ('cpu_ns', 'wall_ns'):
            timings = [r[metric] / r['actions'] for r in values]
            row[metric + '_per_request'] = {'min': min(timings), 'median': statistics.median(timings),
                                               'max': max(timings)}
        summary.append(row)
    return {'scope': meta['scope'], 'samples': len(samples), 'rounds': meta['rounds'],
            'archive_sha256': meta['archive_sha256'], 'results': summary}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    args = parser.parse_args()
    print(json.dumps(analyze(args.input), indent=2))
