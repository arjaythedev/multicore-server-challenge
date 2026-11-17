#!/usr/bin/env python3
"""Pulse only an owned shootout target's CPU quota; check admission recovery.

This is a diagnostic harness, never an entry startup dependency or score. Supply
one fresh stopped fixture using shootout_run's case JSON. Root creates the
transient target; PostgreSQL, application and load generator run unprivileged.
The pulse occurs during ramp, and every quota change is retained as an event.
"""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cases', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--loadgen', type=Path, required=True)
    parser.add_argument('--conformance', type=Path, required=True)
    parser.add_argument('--memory-gib', type=int, required=True)
    parser.add_argument('--users', type=int, default=3000)
    parser.add_argument('--quota', type=int, default=10)
    args = parser.parse_args()
    cases = json.loads(args.cases.read_text())
    if os.geteuid() or len(cases) != 1 or cases[0].get('mode', 'load') != 'load':
        parser.error('root and exactly one load case are required')
    case = cases[0]
    restore = int(case.get('quota', 800))
    if not 1 <= args.quota < restore or case['adaptive'] != 1:
        parser.error('pulse must reduce the declared quota; adaptive admission must be enabled')
    output = args.output / case['name']
    command = [sys.executable, str(Path(__file__).with_name('shootout_run.py')),
               '--cases', str(args.cases), '--output', str(args.output),
               '--loadgen', str(args.loadgen), '--conformance', str(args.conformance),
               '--memory-gib', str(args.memory_gib), '--warm-seed',
               '--users', str(args.users), '--think-scale', '1', '--ramp', '60s',
               '--measure', '30s', '--tail', '15s', '--run-id', 'quota-pulse']
    process = subprocess.Popen(command, start_new_session=True)
    unit, changed, completed = None, False, False
    events = []

    def wait_until(deadline):
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError('shootout exited before the quota pulse completed')
            time.sleep(min(.25, max(0, deadline-time.monotonic())))

    def quota(value):
        subprocess.run(['systemctl', 'set-property', '--runtime', unit,
                        'CPUQuota=' + str(value) + '%'], check=True)
        events.append({'time_ns': time.time_ns(), 'monotonic_ns': time.monotonic_ns(),
                       'unit': unit, 'quota_percent': value})
        (args.output / 'pressure-events.json').write_text(json.dumps({
            'scope': 'forced quota pulse during ramp; not a capacity comparison',
            'events': events}, indent=2) + '\n')

    try:
        deadline = time.monotonic() + 600
        logfile = output / 'loadgen.log'
        while not (logfile.exists() and logfile.stat().st_size):
            if time.monotonic() >= deadline:
                raise TimeoutError('load generator did not start')
            wait_until(time.monotonic() + .25)
        start = time.monotonic()
        metadata = json.loads((output / 'target/metadata.json').read_text())
        unit = Path(metadata['cgroup']).name
        if (not re.fullmatch(r'multicore-shootout-[a-f0-9]{12}\.service', unit) or
                metadata['binary'] != case['binary']):
            raise RuntimeError('target identity differs from the declared owned case')
        owner = subprocess.check_output(['systemctl', 'show', '--property=User', '--value', unit],
                                        text=True).strip()
        if owner != 'build':
            raise RuntimeError('refusing to alter a target outside the unprivileged build account')
        wait_until(start + 35)
        quota(args.quota)
        changed = True
        wait_until(start + 50)
        quota(restore)
        changed = False
        process.wait(timeout=300)
        if process.returncode:
            raise RuntimeError('pressure workload failed to complete')
        completed = True
    finally:
        try:
            if changed:
                quota(restore)
        finally:
            # Include our runuser/loadgen descendants, which are outside the
            # target service. The launcher finally stops its own PG/app unit.
            if not completed:
                try:
                    os.killpg(process.pid, signal.SIGINT)
                except ProcessLookupError:
                    pass
                process.wait(timeout=150)
    log = (output / 'target/server.log').read_text()
    match = re.search(r'read policy: active_limit=(\d+)/(\d+) minimum=(\d+) '
                      r'reductions=(\d+) recoveries=(\d+)', log)
    if not match:
        raise RuntimeError('missing completed admission statistics')
    limit, maximum, minimum, reductions, recoveries = map(int, match.groups())
    # Recovery is demand-driven. Quiet traffic need not reopen every slot, but
    # this busy workload must regain capacity above its pressure minimum.
    if not (minimum < maximum and reductions > 0 and recoveries > 0 and limit > minimum):
        raise RuntimeError('admission did not reduce and regain capacity: ' + match.group(0))
    print('PASS: integrated database/application quota pulse; ' + match.group(0), flush=True)


if __name__ == '__main__':
    main()
