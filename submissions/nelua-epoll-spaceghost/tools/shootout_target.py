#!/usr/bin/env python3
"""Own one disposable PG fixture and server inside a harness-created cgroup.

Run as an unprivileged user, from systemd-run with explicit resource limits.
Never points at a running database; the caller supplies a stopped fixture.
No host tuning, cache dropping, CPU affinity or replay of writes is performed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import threading
import time
import urllib.request


def read(path):
    try:
        return Path(path).read_text()
    except OSError:
        return None


def sample(group):
    result = {'time_ns': time.time_ns(), 'monotonic_ns': time.monotonic_ns()}
    for name in ('cpu.stat', 'cpu.pressure', 'io.stat', 'io.pressure',
                 'memory.current', 'memory.peak', 'memory.events', 'memory.pressure'):
        result[name] = read(group / name)
    processes = []
    for pid in (read(group / 'cgroup.procs') or '').split():
        try:
            raw = Path('/proc', pid, 'stat').read_text()
            fields = raw[raw.rfind(')') + 2:].split()
            processes.append({'pid': int(pid), 'comm': raw[raw.find('(') + 1:raw.rfind(')')],
                              'user_ticks': int(fields[11]), 'system_ticks': int(fields[12]),
                              'start_ticks': int(fields[19]), 'rss_pages': int(fields[21])})
        except (OSError, ValueError, IndexError):
            pass  # Process exited between reading cgroup.procs and stat.
    result['processes'] = processes
    return result


def warm_seed(port, output):
    """Repeat the official read-only seed fingerprint check before timing.

    Cloning a stopped PG cluster loses shared buffers. Verify/scan every table
    explicitly rather than comparing an arbitrary first-cold/second-warm pair.
    This is a harness option; no prewarming extension or application cache.
    """
    script = Path(__file__).resolve().parents[3] / 'seed/make-seed.sh'
    manifests = re.findall(r'EXPECTED="([^"]+)"', script.read_text())
    if not manifests:
        raise RuntimeError('official seed fingerprints not found')
    expected = {table: (int(count), int(digest)) for table, count, digest in
                (line.split() for line in manifests[0].splitlines() if line.strip())}
    tables = ('users', 'follows', 'articles', 'tags', 'article_tags', 'favorites', 'comments')
    if set(expected) != set(tables) or expected['articles'][0] != 500000:
        raise RuntimeError('unexpected full-seed reference')
    deadline = time.monotonic() + 300
    with (output / 'warm-fingerprints.jsonl').open('w', buffering=1) as log:
        for table in tables:
            start = time.monotonic()
            sql = ("SET TimeZone='UTC'; SET max_parallel_workers_per_gather=0; "
                   "SELECT count(*), coalesce(sum(('x' || substr(md5(x::text),1,15))::bit(60)::bigint),0) "
                   f'FROM public.{table} x')
            raw = subprocess.check_output(['psql', '-XqAt', '-F', ' ', '-h', '127.0.0.1',
                                           '-p', str(port), '-U', 'build', '-d', 'conduit_seed',
                                           '-v', 'ON_ERROR_STOP=1', '-c', sql],
                                          text=True, timeout=max(1, deadline-start))
            values = tuple(map(int, raw.split()))
            if values != expected[table]:
                raise RuntimeError('fixture fingerprint mismatch: ' + table)
            log.write(json.dumps({'table': table, 'rows': values[0], 'fingerprint': str(values[1]),
                                  'seconds': time.monotonic()-start}) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--postgres', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--pg-ctl', default='/usr/lib/postgresql/18/bin/pg_ctl')
    parser.add_argument('--pg-port', type=int, default=57432)
    parser.add_argument('--port', type=int, default=3341)
    parser.add_argument('--adaptive', choices=('0', '1'), required=True)
    parser.add_argument('--reactor', choices=('0', '1'), default='1')
    parser.add_argument('--read-connections', type=int, default=4)
    parser.add_argument('--write-connections', type=int, default=8)
    parser.add_argument('--auth-connections', type=int, default=8)
    parser.add_argument('--scan', required=True)
    parser.add_argument('--warm-seed', action='store_true')
    args = parser.parse_args()
    counts = (args.read_connections, args.write_connections, args.auth_connections)
    if min(counts) < 1 or sum(counts) > 95:
        parser.error('positive lane counts with at most 95 total sessions are required')
    if (args.postgres / 'postmaster.pid').exists():
        raise RuntimeError('fixture has postmaster.pid; refusing to take ownership')
    args.output.mkdir(parents=True, exist_ok=False)
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    relative = next(line[3:] for line in Path('/proc/self/cgroup').read_text().splitlines()
                    if line.startswith('0::'))
    group = Path('/sys/fs/cgroup') / relative.lstrip('/')
    ancestors = {}
    for scope in (group, *group.parents):
        if scope == Path('/sys/fs'):
            break
        ancestors[str(scope)] = {name: read(scope / name) for name in
                                 ('cpu.max', 'memory.max', 'cpuset.cpus.effective')}
    metadata = {'binary': str(args.binary),
                'binary_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                'arguments': {key: str(value) for key, value in vars(args).items()},
                'cgroup': str(group), 'cpu.max': read(group / 'cpu.max'),
                'memory.max': read(group / 'memory.max'),
                'ancestor_limits': ancestors,
                'clock_ticks': os.sysconf('SC_CLK_TCK'), 'page_size': os.sysconf('SC_PAGE_SIZE'),
                'platform': os.uname()._asdict() if hasattr(os.uname(), '_asdict') else list(os.uname())}
    (args.output / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    server = None
    started = False
    sampler = None
    try:
        subprocess.run([args.pg_ctl, '-D', str(args.postgres), '-l', str(args.output / 'postgres.log'),
                        # TCP-only avoids Unix socket path-length dependence on
                        # long artifact/case names. The fixture stays loopback.
                        '-o', f"-p {args.pg_port} -k '' -h 127.0.0.1", '-t', '180', '-w', 'start'], check=True)
        started = True
        metadata['postgres_started_at_ns'] = time.time_ns()
        if args.warm_seed:
            warm_seed(args.pg_port, args.output)
            metadata['seed_warmed_at_ns'] = time.time_ns()
        env = dict(os.environ, DATABASE_URL=f'postgres://conduit:conduit@127.0.0.1:{args.pg_port}/conduit_seed',
                   JWT_SECRET='shootout-diagnostic-secret', HOST='127.0.0.1', PORT=str(args.port),
                   READ_REACTOR=args.reactor, READ_ADAPTIVE=args.adaptive, JSON_SCAN=args.scan,
                   READ_BATCH_STATS='1', DB_READ_THREADS=str(args.read_connections),
                   DB_WRITE_THREADS=str(args.write_connections),
                   DB_AUTH_THREADS=str(args.auth_connections))
        with (args.output / 'server.log').open('w') as log:
            server = subprocess.Popen([str(args.binary)], env=env, stdout=log, stderr=subprocess.STDOUT)
            metadata['server_pid'] = server.pid
            metadata['server_launched_at_ns'] = time.time_ns()

            def observe():
                with (args.output / 'resources.jsonl').open('w', buffering=1) as output:
                    while True:
                        output.write(json.dumps(sample(group), separators=(',', ':')) + '\n')
                        if stop.wait(1):
                            break
            sampler = threading.Thread(target=observe, daemon=True)
            sampler.start()
            ready_deadline = time.monotonic() + 60
            while time.monotonic() < ready_deadline:
                if stop.is_set() or server.poll() is not None:
                    raise RuntimeError('target exited before readiness')
                try:
                    with urllib.request.urlopen(f'http://127.0.0.1:{args.port}/api/tags', timeout=1) as response:
                        if response.status == 200:
                            break
                except OSError:
                    stop.wait(.25)
            else:
                raise RuntimeError('target failed readiness deadline')
            metadata['ready_at_ns'] = time.time_ns()
            metadata['application_ready_s'] = (metadata['ready_at_ns'] - metadata['server_launched_at_ns']) / 1e9
            (args.output / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
            (args.output / 'ready').write_text(str(metadata['ready_at_ns']) + '\n')
            while not stop.wait(.5):
                if server.poll() is not None:
                    raise RuntimeError(f'server exited: {server.returncode}')
    finally:
        stop.set()
        if sampler:
            sampler.join(3)
        if server and server.poll() is None:
            server.terminate()
            try:
                server.wait(20)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
        if started or (args.postgres / 'postmaster.pid').exists():
            subprocess.run([args.pg_ctl, '-D', str(args.postgres), '-m', 'fast', '-w', 'stop'], check=True)


if __name__ == '__main__':
    main()
