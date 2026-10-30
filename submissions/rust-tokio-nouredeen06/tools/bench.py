#!/usr/bin/env python3
"""Run the unchanged challenge load generator on an isolated database clone.

Requires psql in PATH, libpq admin env, built upstream loadgen, and a binary.
Uses only Python's standard library. Each run owns and removes its DB/process.
No host tuning, CPU affinity, or changes to database settings are performed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import subprocess
import sys
import threading
import time
import urllib.request


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs)


def cpu(pid):
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")
    except (OSError, IndexError, ValueError):
        return 0


def rss(pid):
    try:
        return int(Path(f"/proc/{pid}/statm").read_text().split()[1]) * os.sysconf("SC_PAGE_SIZE")
    except (OSError, IndexError, ValueError):
        return 0


def descendants(pid):
    found = {pid}
    pending = [pid]
    while pending:
        parent = pending.pop()
        try:
            children = Path(f"/proc/{parent}/task/{parent}/children").read_text().split()
        except OSError:
            continue
        for child in map(int, children):
            if child not in found:
                found.add(child)
                pending.append(child)
    return found


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--binary", required=True, type=Path)
    p.add_argument("--loadgen", required=True, type=Path)
    p.add_argument("--output", required=True, type=Path)
    p.add_argument("--template", default="conduit_seed")
    p.add_argument("--existing-database", help="use a database in a caller-owned disposable volume snapshot; caller owns cleanup")
    p.add_argument("--port", type=int, default=3110)
    p.add_argument("--users", type=int, default=6000)
    p.add_argument("--articles", type=int, default=500000)
    p.add_argument("--think-scale", type=float, default=0.1)
    p.add_argument("--ramp", default="15s")
    p.add_argument("--measure", default="45s")
    p.add_argument("--tail", default="5s")
    p.add_argument("--pg-container", help="optional container name for PG CPU monitoring")
    p.add_argument("--loadgen-procs", type=int, default=4,
                   help="Go scheduler workers for the colocated generator (recorded in metadata)")
    p.add_argument("--env", action="append", default=[], help="server setting KEY=VALUE")
    a = p.parse_args()
    if a.loadgen_procs < 1:
        p.error("--loadgen-procs must be positive")
    # The official service supplies LimitNOFILE=200000. Match that process limit
    # locally; desktop shells commonly inherit a soft limit of just 1024.
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    desired = 200000 if hard == resource.RLIM_INFINITY else min(200000, hard)
    if soft != resource.RLIM_INFINITY:
        resource.setrlimit(resource.RLIMIT_NOFILE, (max(soft, desired), hard))
    a.output.mkdir(parents=True, exist_ok=False)
    binary, loadgen = str(a.binary.resolve()), str(a.loadgen.resolve())
    run_id = f"nouredeen_bench_{os.getpid()}_{int(time.time())}"
    db = a.existing_database or run_id
    if not a.template.replace("_", "").isalnum():
        p.error("template must be an alphanumeric database name")
    if not db.replace("_", "").isalnum():
        p.error("database must be an alphanumeric database name")
    settings = dict(APP_THREADS="2", DB_CONNS="6", DB_WRITE_CONNS="2", BCRYPT_THREADS="2",
                    READ_TAG_ROUTE="1", READ_COMMENT_SET="1", READ_TAG_BATCH="1")
    settings.update(item.split("=", 1) for item in a.env)
    env = os.environ | settings | dict(
        DATABASE_URL=f"postgres://conduit:conduit@127.0.0.1:{os.environ.get('PGPORT', '5432')}/{db}",
        HOST="127.0.0.1", PORT=str(a.port), JWT_SECRET="multicore-server-challenge")
    metadata = dict(binary=binary, binary_sha256=hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
                    settings=settings, args=vars(a).copy(),
                    machine=platform.uname()._asdict(), logical_cpus=os.cpu_count(),
                    start_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    note="Local shared host, accelerated workload; not an official challenge score.")
    metadata["args"] = {k: str(v) if isinstance(v, Path) else v for k, v in metadata["args"].items()}
    pg_pid = None
    if a.pg_container:
        pg_pid = int(run("docker", "inspect", "--format", "{{.State.Pid}}", a.pg_container).stdout)
    app = lg = None
    stop = threading.Event()
    samples = []
    created = False
    try:
        if not a.existing_database:
            run("psql", "-X", "-v", "ON_ERROR_STOP=1", "-d", "postgres", "-c",
                f'CREATE DATABASE "{db}" TEMPLATE "{a.template}" STRATEGY FILE_COPY')
            created = True
        with (a.output / "server.log").open("w") as serverlog:
            app = subprocess.Popen([binary], env=env, stdout=serverlog, stderr=subprocess.STDOUT)
            base = f"http://127.0.0.1:{a.port}"
            for _ in range(300):
                if app.poll() is not None:
                    raise RuntimeError(f"server exited: {(a.output / 'server.log').read_text()}")
                try:
                    with urllib.request.urlopen(base + "/api/tags", timeout=1) as r:
                        if r.status == 200:
                            break
                except OSError:
                    time.sleep(0.2)
            else:
                raise RuntimeError("health deadline exceeded")

            def monitor():
                while not stop.is_set():
                    pids = descendants(pg_pid) if pg_pid else set()
                    samples.append(dict(time=time.time(), app_cpu_s=cpu(app.pid),
                                        app_rss=rss(app.pid), pg_cpu_s=sum(map(cpu, pids))))
                    stop.wait(1)

            thread = threading.Thread(target=monitor, daemon=True)
            thread.start()
            command = [loadgen, "run", "-target", base, "-users", str(a.users), "-ramp", a.ramp,
                       "-measure", a.measure, "-tail", a.tail, "-secret", env["JWT_SECRET"],
                       "-articles", str(a.articles), "-think-scale", str(a.think_scale),
                       "-run-id", run_id, "-out", str(a.output / "raw.json")]
            print(f"Running {a.output.name}: {a.users} VUs, think-scale={a.think_scale}, {settings}", flush=True)
            with (a.output / "loadgen.log").open("w") as log:
                lg = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                      env=os.environ | {"GOMAXPROCS": str(a.loadgen_procs)})
                if lg.wait() != 0:
                    raise RuntimeError(f"loadgen failed: {(a.output / 'loadgen.log').read_text()}")
            stop.set()
            thread.join()
            merged = subprocess.run([loadgen, "merge", "-o", str(a.output / "merged.json"),
                                     str(a.output / "raw.json")], capture_output=True, text=True)
            (a.output / "merged.txt").write_text(merged.stdout + merged.stderr)
            if merged.returncode not in (0, 3):
                raise RuntimeError(merged.stderr)
            print(merged.stdout + merged.stderr, flush=True)
    finally:
        stop.set()
        # Preserve measurements even when the database or Docker is unavailable
        # during cleanup. Cleanup failure must never erase a completed run.
        (a.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        (a.output / "monitor.json").write_text(json.dumps(samples) + "\n")
        for process in (lg, app):
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        if created:
            try:
                run("psql", "-X", "-v", "ON_ERROR_STOP=1", "-d", "postgres", "-c",
                    f'DROP DATABASE "{db}" WITH (FORCE)')
            except subprocess.CalledProcessError as error:
                metadata["cleanup_error"] = error.stderr
                (a.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
                print(f"Cleanup failed for {db}: {error.stderr}", file=sys.stderr)


if __name__ == "__main__":
    main()
