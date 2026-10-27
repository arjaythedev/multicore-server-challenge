"""Compare builds with the unchanged load generator on fresh seed clones.

This is a local experiment, not the official capacity search. The generator,
application and PostgreSQL share the Mac. No failed requests are filtered out.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
from support import Server, sql


def fingerprint(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--control', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--third', type=Path, help='optional third build, selected as C in --order')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--order', default='ABBABA')
    parser.add_argument('--users', type=int, default=128)
    parser.add_argument('--think-scale', type=float, default=0.01)
    parser.add_argument('--ramp', default='10s')
    parser.add_argument('--measure', default='30s')
    parser.add_argument('--tail', default='3s')
    parser.add_argument('--template', choices=['conduit_dev', 'conduit_seed'], default='conduit_dev')
    args = parser.parse_args()
    labels = {'A', 'B', 'C'} if args.third else {'A', 'B'}
    if not args.order or set(args.order) - labels:
        parser.error('--order must select A, B, or C when --third is supplied')
    if not 0 < args.users <= 8000:
        parser.error('local Mac comparisons use 1–8000 users')
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=False)
    builds = {'A': args.control.resolve(), 'B': args.candidate.resolve()}
    if args.third:
        builds['C'] = args.third.resolve()
    loadgen = Path(os.environ['CHALLENGE_WORK']) / 'tools/loadgen'
    report = {
        'started_at_utc': datetime.now(timezone.utc).isoformat(),
        'scope': f'native Mac, {args.template}, co-located load generator; not an official score',
        'platform': platform.platform(), 'cpu_count': os.cpu_count(),
        'seed_counts': sql('SELECT (SELECT count(*) FROM users), (SELECT count(*) FROM articles)', args.template),
        'settings': {key: value for key, value in vars(args).items() if key not in ('control', 'candidate', 'third', 'out')},
        'binaries': {label: {'path': str(path), 'sha256': fingerprint(path)} for label, path in builds.items()},
        'loadgen_sha256': fingerprint(loadgen),
        'harness_sha256': fingerprint(Path(__file__).resolve()),
        'runs': [],
    }
    summary = args.out / 'summary.json'
    try:
        for index, label in enumerate(args.order):
            name = f'{index + 1:02d}-{label}'
            with Server(args.out, 'local-comparison', 'compare', name.replace('-', '_').lower(), builds[label], template=args.template) as server:
                output = args.out / f'{name}.json'
                command = [str(loadgen), 'run', '-target', f'http://127.0.0.1:{server.port}',
                           '-users', str(args.users), '-ramp', args.ramp, '-measure', args.measure,
                           '-tail', args.tail, '-think-scale', str(args.think_scale), '-articles', '500000' if args.template == 'conduit_seed' else '10000',
                           '-secret', server.secret, '-run-id', f'compare{os.getpid()}n{index}', '-out', str(output)]
                with (args.out / f'{name}.log').open('w') as log:
                    subprocess.run(command, stdout=log, stderr=log, check=True, timeout=900)
                merged = args.out / f'{name}-merged.json'
                with (args.out / f'{name}-merged.log').open('w') as log:
                    merge = subprocess.run([str(loadgen), 'merge', '-o', str(merged), str(output)],
                                           stdout=log, stderr=log, timeout=30)
                if merge.returncode not in (0, 3):
                    raise RuntimeError(f'loadgen merge failed: {merge.returncode}')
                data = json.loads(merged.read_text())
                result = {'run': name, 'build': label, 'overall': data['overall'],
                          'verdict': data['verdict'], 'mix': data['mix'], 'boxes': data['boxes']}
                report['runs'].append(result)
                stats = result['overall']
                print(f"{name}: {stats['rps']:.1f} req/s; p95 {stats['p95_ms']:.2f} ms; "
                      f"p99 {stats['p99_ms']:.2f} ms; errors {stats['errors']}/{stats['count']}; "
                      f"LG-limited={result['verdict']['lg_limited']}", flush=True)
            summary.write_text(json.dumps(report, indent=2) + '\n')
        report['medians'] = {}
        for label in builds:
            runs = [run['overall'] for run in report['runs'] if run['build'] == label]
            if runs:
                report['medians'][label] = {field: statistics.median(run[field] for run in runs)
                                            for field in ('rps', 'p95_ms', 'p99_ms', 'error_rate')}
        if all(label in report['medians'] for label in ('A', 'B')):
            report['median_rps_change_pct'] = 100 * (report['medians']['B']['rps'] / report['medians']['A']['rps'] - 1)
        if 'A' in report['medians']:
            report['median_rps_change_vs_control_pct'] = {
                label: 100 * (stats['rps'] / report['medians']['A']['rps'] - 1)
                for label, stats in report['medians'].items() if label != 'A'}
        report['all_runs_zero_errors_and_no_reported_generator_limit'] = all(
            run['overall']['errors'] == 0 and not run['verdict']['lg_limited'] for run in report['runs'])
        report['completed'] = True
    finally:
        summary.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
