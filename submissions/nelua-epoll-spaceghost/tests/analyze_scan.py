#!/usr/bin/env python3
"""Validate complete repeated scanner samples and emit component measurements.

These results describe a scanner or JSON string writer, never server capacity.
Use --modes to state the tested ISA set on machines without AVX-512/AVX2.
"""
import argparse
import itertools
import json
from pathlib import Path
import re
import statistics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--kind', choices=['kernel', 'writer'], required=True)
    parser.add_argument('--rounds', type=int, default=5)
    parser.add_argument('--modes', help='exact comma-separated list expected in the log')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error('rounds must be positive')
    if args.kind == 'kernel':
        defaults = 'c-scalar,nelua-scalar,c-word,nelua-word,c-avx2,nelua-avx2,c-avx512,nelua-avx512'
        lengths = [12, 32, 64, 128, 1024, 4096]
        baseline = 'nelua-word'
    else:
        defaults = 'legacy,c-word,nelua-word,c-avx2,nelua-avx2,c-avx512,nelua-avx512'
        lengths = [12, 64, 128, 1024, 4096]
        baseline = 'legacy'
    modes = (args.modes or defaults).split(',')
    samples = {}
    mode, repetition = None, None
    for line in args.log.read_text().splitlines():
        header = re.fullmatch(r'JSON_SCAN=(\S+) repetition=(\d+)', line)
        if header:
            mode, repetition = header.group(1), int(header.group(2))
        if args.kind == 'kernel':
            match = re.match(r'BENCH (\S+) repetition=(\d+) kind=(\d+) length=(\d+) ns_per_string=([\d.]+)', line)
            if not match:
                continue
            name, rep, kind, length, elapsed = match.groups()
            key = name, int(rep), int(kind), int(length)
        else:
            match = re.match(r'BENCH kind=(\d+) length=(\d+) loops=\d+ cpu_seconds=[\d.]+ ns_per_string=([\d.]+)', line)
            if not match:
                continue
            kind, length, elapsed = match.groups()
            key = mode, repetition, int(kind), int(length)
        if key in samples:
            raise SystemExit('duplicate benchmark sample: ' + repr(key))
        samples[key] = float(elapsed)
    expected = set(itertools.product(modes, range(args.rounds), range(3), lengths))
    if set(samples) != expected:
        raise SystemExit('incomplete or unexpected benchmark matrix: missing=' +
                         repr(sorted(expected - samples.keys())[:5]) +
                         ' extra=' + repr(list(samples.keys() - expected)[:5]))
    rows = []
    for name, kind, length in itertools.product(modes, range(3), lengths):
        values = [samples[name, rep, kind, length] for rep in range(args.rounds)]
        med = statistics.median(values)
        base = statistics.median(samples[baseline, rep, kind, length] for rep in range(args.rounds))
        rows.append({'implementation': name, 'kind': kind, 'length': length,
                     'samples_ns': values, 'median_ns': med,
                     'min_ns': min(values), 'max_ns': max(values),
                     'baseline': baseline, 'baseline_median_ratio': base / med})
    args.output.write_text(json.dumps({
        'scope': args.kind + ' component microbenchmark; not whole-server throughput',
        'rounds': args.rounds, 'samples_checked': len(samples), 'rows': rows,
    }, indent=2) + '\n')
    print('PASS: validated', len(samples), 'samples;', args.output)


if __name__ == '__main__':
    main()
