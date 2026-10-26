#!/usr/bin/env python3
"""Run conformance and concurrency regressions on a disposable seed clone.

Requires a running PostgreSQL, psql on PATH, and admin access via PG* settings.
The application uses the seed's conduit/conduit role. No schema is changed.
Examples:
  python3 tests/verify.py --template conduit_seed
  python3 tests/verify.py --binary zig-out/safe/bin/conduit --fallback
Logs and summary.json remain in --output, including on failure.
"""
import argparse
import contextlib
import http.client
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
SECRET = "multicore-server-challenge"
BASE = dict(WORKERS="1", PROCS="1", DB_CONNS="2", DB_WRITE_CONNS="1", PG_DEPTH="4", STATS="1")
BATCH = dict(ADAPTIVE_WINDOW="0", READ_WINDOW_US="20000")
CASES = {
    "adaptive": {},
    "per-kind": dict(BATCH, PLAN_MIN="0"),
    "planner": dict(BATCH, PLAN_MIN="16"),
    "split": dict(BATCH, PLAN_MIN="16", PLAN_SPLIT="1", DB_CONNS="3"),
    "failed-per-kind": dict(BATCH, PLAN_MIN="0", TEST_FAIL_BATCHES="1"),
    "failed-planner": dict(BATCH, PLAN_MIN="16", TEST_FAIL_BATCHES="1"),
    "failed-writes": dict(TEST_FAIL_GROUPS="1"),
    "threads": dict(WORKERS="2", PROCS="1", DB_CONNS="4", DB_WRITE_CONNS="2"),
}


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", type=Path, default=ROOT / "bin/conduit")
    parser.add_argument("--template", default="conduit_dev")
    parser.add_argument("--output", type=Path, default=ROOT / "zig-out/verification")
    parser.add_argument("--conformance", type=Path)
    parser.add_argument("--port", type=int, default=3101)
    parser.add_argument("--fallback", action="store_true", help="force poll/recv and ordinary sends")
    parser.add_argument("--case", action="append", choices=CASES, help="select cases; default all")
    args = parser.parse_args()
    require(1024 <= args.port < 65535, "port must leave room for a second unprivileged listener")
    args.binary = args.binary.resolve()
    require(args.binary.is_file(), "build the server first: bash build.sh")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    for key in ("WORKERS", "PROCS", "DB_CONNS", "DB_WRITE_CONNS", "PG_DEPTH", "BATCH_MAX", "PLAN_MIN", "PLAN_MAX", "PLAN_SPLIT", "READ_WINDOW_US", "READ_HOLD_MIN", "ADAPTIVE_WINDOW", "SEND_ZC", "NO_PBUF", "TEST_FAIL_BATCHES", "TEST_FAIL_GROUPS", "BCRYPT_WAIT_MS", "BCRYPT_THREADS", "BCRYPT_LANES", "PIN_CPUS"):
        env.pop(key, None)
    if args.fallback:
        env.update(NO_PBUF="1", SEND_ZC="0")
    records = []

    def command(name, argv, child_env=None, timeout=120):
        log = output / (name + ".txt")
        start = time.monotonic()
        with log.open("w") as stream:
            result = subprocess.run(list(map(str, argv)), cwd=ROOT, env=child_env or env,
                                    stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
        record = dict(test=name, exit=result.returncode, seconds=round(time.monotonic() - start, 3), log=str(log))
        records.append(record)
        print(("PASS " if result.returncode == 0 else "FAIL ") + name + " (%.2fs)" % record["seconds"], flush=True)
        require(result.returncode == 0, str(log) + "\n" + "\n".join(log.read_text().splitlines()[-40:]))

    def psql(sql, database="postgres"):
        result = subprocess.run(["psql", "-w", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-d", database, "-c", sql],
                                cwd=ROOT, env=env, capture_output=True, text=True, timeout=40)
        require(result.returncode == 0, "psql: " + result.stderr)
        return result.stdout.strip()

    @contextlib.contextmanager
    def server(name, config, port, database):
        child_env = dict(env, **BASE, DATABASE_URL=database, JWT_SECRET=SECRET, HOST="127.0.0.1", PORT=str(port))
        child_env.update(config)
        log = output / (name + ".server.log")
        with log.open("w") as stream:
            proc = subprocess.Popen([str(args.binary)], cwd=ROOT, env=child_env, stdout=stream,
                                    stderr=subprocess.STDOUT, start_new_session=True)
            try:
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    require(proc.poll() is None, "server exited: " + log.read_text())
                    client = http.client.HTTPConnection("127.0.0.1", port, timeout=.5)
                    try:
                        client.request("GET", "/api/tags")
                        response = client.getresponse()
                        response.read()
                        if response.status == 200:
                            break
                    except OSError:
                        pass
                    finally:
                        client.close()
                    time.sleep(.05)
                else:
                    raise RuntimeError("server health deadline: " + log.read_text())
                yield proc, child_env, log
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGCONT)
                    os.killpg(proc.pid, signal.SIGTERM)
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(proc.pid, signal.SIGKILL)
                        proc.wait(timeout=5)

    def synchronized_reads(proc, port, before_resume=None):
        clients = [http.client.HTTPConnection("127.0.0.1", port, timeout=3) for _ in range(12)]
        try:
            for client in clients:
                client.connect()
            os.killpg(proc.pid, signal.SIGSTOP)
            try:
                for client in clients:
                    client.request("GET", "/api/tags")
            finally:
                os.killpg(proc.pid, signal.SIGCONT)
            if before_resume:
                before_resume()
            start = time.monotonic()
            for client in clients:
                response = client.getresponse()
                data = json.loads(response.read())
                require(response.status == 200 and isinstance(data["tags"], list), "invalid synchronized read")
            elapsed = (time.monotonic() - start) * 1000
            require(elapsed < 75, "queued reads stalled %.2fms (limit 75ms)" % elapsed)
            return elapsed
        finally:
            for client in clients:
                client.close()

    def scheduling(proc, port, db):
        idle = [synchronized_reads(proc, port) for _ in range(3)]
        lock = subprocess.Popen(["psql", "-w", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-d", db],
                                env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, bufsize=1)
        first = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        assert lock.stdin is not None and lock.stdout is not None
        lock_input, lock_output = lock.stdin, lock.stdout

        def marker(expected):
            require(bool(select.select([lock_output], [], [], 5)[0]), "lock session did not return " + expected)
            require(lock_output.readline().strip() == expected, "unexpected lock session result")

        try:
            lock_input.write("SET statement_timeout='5s'; BEGIN; LOCK TABLE articles IN ACCESS EXCLUSIVE MODE;\n\\echo LOCKED\n")
            lock_input.flush()
            marker("LOCKED")
            first.request("GET", "/api/articles?limit=1")
            deadline = time.monotonic() + 3
            while psql("SELECT count(*) FROM pg_stat_activity WHERE datname='" + db + "' AND usename='conduit' AND wait_event_type='Lock'") == "0":
                require(time.monotonic() < deadline, "read never reached the blocked backend")
                time.sleep(.005)

            def release():
                time.sleep(.005)  # let the worker stage the burst behind the blocked read
                lock_input.write("COMMIT;\n\\echo RELEASED\n\\q\n")
                lock_input.flush()
                marker("RELEASED")

            busy = synchronized_reads(proc, port, release)
            response = first.getresponse()
            require(response.status == 200, "blocked first read failed")
            response.read()
            print("PASS scheduling: idle max=%.2fms, after backend release=%.2fms" % (max(idle), busy), flush=True)
            records.append(dict(test="scheduling", exit=0, idle_max_ms=max(idle), released_ms=busy))
        finally:
            first.close()
            if lock.poll() is None:
                lock.terminate()
            lock.communicate(timeout=5)

    db = "zig_verify_" + uuid.uuid4().hex
    host = env.get("PGHOST", "127.0.0.1")
    if not host or host.startswith("/"):
        host = "127.0.0.1"
    if ":" in host and not host.startswith("["):
        host = "[" + host + "]"
    database = "postgres://conduit:conduit@%s:%s/%s" % (host, env.get("PGPORT", "5432"), db)
    quoted_template = '"' + args.template.replace('"', '""') + '"'
    created = False
    try:
        conformance = args.conformance.resolve() if args.conformance else output / "conformance"
        if not args.conformance:
            command("build-conformance", ["go", "-C", ROOT.parent.parent / "bench", "build", "-o", conformance, "./cmd/conformance"])
        reference = dict(PLAN_MIN="0", BATCH_MAX="1", ADAPTIVE_WINDOW="0", READ_WINDOW_US="0")
        for name in args.case or list(CASES):
            # Conformance mutates seeded rows and uses fixed usernames: every case needs a fresh clone.
            psql("CREATE DATABASE " + db + " TEMPLATE " + quoted_template)
            created = True
            try:
                with server(name + "-reference", reference, args.port, database), server(name, CASES[name], args.port + 1, database) as (proc, child_env, log):
                    port = args.port + 1
                    print("== " + name + (" (fallback)" if args.fallback else ""), flush=True)
                    command(name + "-conformance", [conformance, "-base", "http://127.0.0.1:" + str(port), "-secret", SECRET, "-q"], child_env)
                    read_args = [sys.executable, "tests/read_regression.py", str(port)]
                    if name in ("adaptive", "threads"):
                        read_args += ["--latency-ms", "50"]
                    command(name + "-known-reads", read_args, child_env)
                    if name in ("per-kind", "planner", "split", "failed-per-kind", "failed-planner"):
                        for hot in ("0", "1"):
                            command(name + "-diff-hot" + hot, [sys.executable, "tests/batchdiff.py", str(args.port), str(port)], dict(child_env, HOT=hot), timeout=180)
                    if name == "adaptive":
                        scheduling(proc, port, db)
                        command(name + "-http", [sys.executable, "tests/httptest.py", str(port)], child_env)
                        command(name + "-streams", [sys.executable, "tests/streamtest.py", str(port)], child_env)
                    if name in ("adaptive", "failed-writes"):
                        command(name + "-writes", [sys.executable, "tests/writetest.py", str(port), "200"], child_env)
                    if name == "adaptive":
                        command(name + "-reconnect", [sys.executable, "tests/reconnect.py", str(port)], child_env)
                    expected = {"failed-per-kind": "batched statement failed", "failed-planner": "planned batch failed", "failed-writes": "write group failed; rolling back"}.get(name)
                    if expected:
                        require(expected in log.read_text(), "failure injection was not exercised: " + name)
            finally:
                psql("DROP DATABASE " + db + " WITH (FORCE)")
                created = False
        print("PASS: all selected configurations; logs: " + str(output), flush=True)
    finally:
        if created:
            psql("DROP DATABASE " + db + " WITH (FORCE)")
        (output / "summary.json").write_text(json.dumps(records, indent=2) + "\n")


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt) as exc:
        print("FAIL: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
        sys.exit(1)
