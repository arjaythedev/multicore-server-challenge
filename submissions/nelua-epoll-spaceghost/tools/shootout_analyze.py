#!/usr/bin/env python3
"""Analyze a complete shootout_run load matrix; retain diagnostic caveats."""
import argparse
import json
from pathlib import Path
import statistics


def cpu_usage(sample):
    fields = dict(line.split() for line in (sample.get('cpu.stat') or '').splitlines())
    return int(fields['usage_usec']) if 'usage_usec' in fields else None


def process_cpu(left, right, comm, ticks):
    before = {(p['pid'], p['start_ticks']): p for p in left['processes']}
    elapsed = 0
    for p in right['processes']:
        old = before.get((p['pid'], p['start_ticks']))
        if old and p['comm'] == comm:
            elapsed += max(0, p['user_ticks'] + p['system_ticks'] -
                           old['user_ticks'] - old['system_ticks'])
    return elapsed / ticks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    cases = json.loads((args.directory / 'cases.json').read_text())
    rows = []
    for case in cases:
        if case.get('mode', 'load') != 'load':
            continue
        path = args.directory / case['name']
        metadata = json.loads((path / 'target/metadata.json').read_text())
        merged = json.loads((path / 'merged.json').read_text())
        idle = json.loads((path / 'idle-latency.json').read_text())
        assert len(idle['samples_ms']) == 50
        samples = [json.loads(line) for line in (path / 'target/resources.jsonl').read_text().splitlines()]
        start = (merged['start_at_ms'] / 1000 + merged['ramp_s']) * 1e9
        end = start + merged['measure_s'] * 1e9
        window = [s for s in samples if start <= s['time_ns'] <= end]
        if len(window) < 2:
            raise RuntimeError('insufficient resource samples in measured window: ' + case['name'])
        span = (window[-1]['monotonic_ns'] - window[0]['monotonic_ns']) / 1e9
        ticks = metadata['clock_ticks']
        app_seconds = sum(process_cpu(a, b, Path(case['binary']).name[:15], ticks)
                          for a, b in zip(window, window[1:]))
        pg_seconds = sum(process_cpu(a, b, 'postgres', ticks)
                         for a, b in zip(window, window[1:]))
        left, right = cpu_usage(window[0]), cpu_usage(window[-1])
        overall = merged['overall']
        rows.append(dict(case, **{key: overall[key] for key in
                         ('rps', 'p50_ms', 'p95_ms', 'p99_ms', 'error_rate')},
                         goodput_rps=overall['rps']*(1-overall['error_rate']),
                         verdict=merged['verdict'], idle_median_ms=statistics.median(idle['samples_ms']),
                         resource_sample_span_s=span, app_cores=app_seconds/span,
                         postgres_sampled_cores=pg_seconds/span,
                         target_total_cores=(right-left)/1e6/span if left is not None and right is not None else None,
                         target_memory_peak_measured_bytes=max(int(s['memory.current']) for s in window
                                                              if s.get('memory.current') is not None),
                         app_cpu_us_per_response=app_seconds*1e6/(overall['rps']*span) if overall['rps']>0 else None,
                         binary_sha256=metadata['binary_sha256'], ancestor_limits=metadata['ancestor_limits']))
    if not rows:
        raise RuntimeError('no load cases')
    report = {'scope': 'local diagnostic; accelerated/co-located load is not a competition score',
              'caveats': ['CPU samples cover the displayed subwindow of the measured phase.',
                          'Short-lived PostgreSQL processes can exit between samples; cgroup total CPU is authoritative.',
                          'Memory is measured once per target cgroup; PostgreSQL shared RSS is not summed.',
                          'Host contention and missing PSI must be assessed before choosing defaults.',
                          'Cases require repeated order-balanced rounds before claiming small differences.'],
              'cases': rows}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    for row in rows:
        print(f"{row['name']}: {row['goodput_rps']:.1f} good responses/s "
              f"({row['rps']:.1f} total rps) p95={row['p95_ms']:.2f}ms "
              f"p99={row['p99_ms']:.2f}ms errors={row['error_rate']:.4f} "
              f"idle={row['idle_median_ms']:.3f}ms app={row['app_cores']:.2f} cores "
              f"PG~={row['postgres_sampled_cores']:.2f} cores")


if __name__ == '__main__':
    main()
