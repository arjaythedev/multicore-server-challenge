#!/usr/bin/env python3
"""Local diagnostic harness; resource limits apply to PG + app, never loadgen.

Requires root for transient systemd services and a JSON array of case objects.
Each case supplies a DIFFERENT stopped, pristine PostgreSQL fixture, binary,
language, adaptive (0/1), name and optional reactor (0/1), quota (percent), mode
(load/conformance), round. Fixture cloning is deliberately external to this
tool: it never deletes data or creates databases, snapshots or volumes.
"""
import argparse
import http.client
import json
import os
from pathlib import Path
import pwd
import statistics
import subprocess
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cases', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--loadgen', type=Path, required=True)
    parser.add_argument('--conformance', type=Path, required=True)
    parser.add_argument('--user', default='build')
    parser.add_argument('--memory-gib', type=int, default=16)
    parser.add_argument('--warm-seed', action='store_true')
    parser.add_argument('--users', type=int, default=2000)
    parser.add_argument('--think-scale', type=float, default=.1)
    parser.add_argument('--measure', default='30s')
    parser.add_argument('--ramp', default='10s')
    parser.add_argument('--tail', default='15s')
    parser.add_argument('--run-id', default='screen-v7')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise RuntimeError('run harness as root; targets and loadgen run as the specified user')
    relative = next(line[3:] for line in Path('/proc/self/cgroup').read_text().splitlines()
                    if line.startswith('0::'))
    group = Path('/sys/fs/cgroup') / relative.lstrip('/')
    for scope in (group, *group.parents):
        if scope == Path('/sys/fs'):
            break
        limit = scope / 'memory.max'
        if limit.exists() and limit.read_text().strip() != 'max':
            if args.memory_gib * 1024**3 > int(limit.read_text()):
                raise RuntimeError(f'requested memory exceeds parent cap in {limit}')
    cases = json.loads(args.cases.read_text())
    fixtures = [str(Path(case['fixture']).resolve()) for case in cases]
    if len(set(fixtures)) != len(fixtures):
        raise RuntimeError('each case requires its own pristine fixture')
    if len({case['name'] for case in cases}) != len(cases):
        raise RuntimeError('duplicate case name')
    owner = pwd.getpwnam(args.user)
    args.output.mkdir(parents=True, exist_ok=False)
    os.chown(args.output, owner.pw_uid, owner.pw_gid)
    (args.output / 'cases.json').write_text(json.dumps(cases, indent=2) + '\n')
    for case in cases:
        name = case['name']
        if not name or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-_' for c in name):
            raise ValueError('case name must contain only lowercase ASCII, digits, - or _')
        output = args.output / name
        output.mkdir()
        os.chown(output, owner.pw_uid, owner.pw_gid)
        unit = 'multicore-shootout-' + uuid.uuid4().hex[:12]
        target = output / 'target'
        command = ['systemd-run', '--quiet', '--collect', '--unit=' + unit,
                   '--property=User=' + args.user, '--property=CPUQuota=' + str(case.get('quota', 800)) + '%',
                   '--property=MemoryMax=' + str(args.memory_gib) + 'G', '--property=LimitNOFILE=200000',
                   '--property=TimeoutStopSec=120', '--property=KillMode=mixed',
                   '--property=StandardOutput=append:' + str(output / 'target-unit.log'),
                   '--property=StandardError=inherit', '/usr/bin/python3',
                   str(Path(__file__).with_name('shootout_target.py')),
                   '--postgres', case['fixture'], '--binary', case['binary'], '--output', str(target),
                   '--adaptive', str(case['adaptive']), '--reactor', str(case.get('reactor', 1)),
                   '--read-connections', str(case.get('read_connections', 4)),
                   '--write-connections', str(case.get('write_connections', 8)),
                   '--auth-connections', str(case.get('auth_connections', 8)),
                   '--scan', case['language'] + '-auto']
        if args.warm_seed:
            command.append('--warm-seed')
        print('START', name, flush=True)
        try:
            subprocess.run(command, check=True)
            # This includes a fresh PostgreSQL cold start, unlike the entry's
            # application-only challenge health deadline.
            ready_deadline = time.monotonic() + (550 if args.warm_seed else 250)
            while time.monotonic() < ready_deadline:
                if (target / 'ready').exists():
                    break
                active = subprocess.run(['systemctl', 'is-active', '--quiet', unit]).returncode
                if active:
                    raise RuntimeError('target unit failed: ' + (output / 'target-unit.log').read_text())
                time.sleep(.25)
            else:
                raise RuntimeError('target readiness timed out')
            if case.get('mode', 'load') == 'conformance':
                cmd = [str(args.conformance), '-base', 'http://127.0.0.1:3341',
                       '-secret', 'shootout-diagnostic-secret', '-q',
                       '-transcript', str(output / 'transcript.jsonl')]
                with (output / 'conformance.log').open('w') as log:
                    subprocess.run(['runuser', '-u', args.user, '--'] + cmd,
                                   stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
                print((output / 'conformance.log').read_text().strip(), flush=True)
            else:
                connection = http.client.HTTPConnection('127.0.0.1', 3341, timeout=5)
                latencies = []
                for index in range(70):
                    start = time.monotonic_ns()
                    connection.request('GET', '/api/tags')
                    response = connection.getresponse()
                    response.read()
                    assert response.status == 200
                    if index >= 20:
                        latencies.append((time.monotonic_ns() - start) / 1e6)
                    time.sleep(.005)
                connection.close()
                (output / 'idle-latency.json').write_text(json.dumps({
                    'route': '/api/tags', 'keepalive': True, 'samples_ms': latencies,
                    'median_ms': statistics.median(latencies)}, indent=2) + '\n')
                cmd = [str(args.loadgen), 'run', '-target', 'http://127.0.0.1:3341',
                       '-users', str(args.users), '-ramp', args.ramp, '-measure', args.measure,
                       '-tail', args.tail, '-secret', 'shootout-diagnostic-secret',
                       '-articles', '500000', '-think-scale', str(args.think_scale),
                       '-run-id', args.run_id + '-r' + str(case.get('round', 1)),
                       '-out', str(output / 'raw.json')]
                (output / 'load-command.json').write_text(json.dumps(cmd, indent=2) + '\n')
                with (output / 'loadgen.log').open('w') as log:
                    subprocess.run(['runuser', '-u', args.user, '--'] + cmd,
                                   stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
                merged = subprocess.run([str(args.loadgen), 'merge', '-o', str(output / 'merged.json'),
                                         str(output / 'raw.json')])
                # Exit 3 is a measured failed SLO, not a broken result file.
                # Keep it and finish the declared comparison matrix.
                if merged.returncode not in (0, 3):
                    merged.check_returncode()
                result = json.loads((output / 'merged.json').read_text())
                print(json.dumps({'name': name, 'overall': result.get('overall'),
                                  'verdict': result.get('verdict')}), flush=True)
        finally:
            stopped = subprocess.run(['systemctl', 'stop', unit])
            # --collect removes a failed service after its wrapper has already
            # cleaned up. Preserve the original startup exception in that case.
            if stopped.returncode not in (0, 5):
                stopped.check_returncode()
        print('STOP', name, flush=True)


if __name__ == '__main__':
    main()
