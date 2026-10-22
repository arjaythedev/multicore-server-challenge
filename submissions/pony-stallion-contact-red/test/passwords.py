from contextlib import contextmanager
import http.client
import json
import os
from pathlib import Path
import random
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

from integration import Integration, PoolRun, SQLSession


ROOT = Path(__file__).resolve().parents[1]
VARIANT = os.environ.get("CONDUIT_VARIANT", "ordinary")
if VARIANT not in ("ordinary", "diagnostic"):
    raise ValueError("CONDUIT_VARIANT must be ordinary or diagnostic")
EXE = ROOT / "bin" / ("conduit-diagnostic-password-test" if
                      VARIANT == "diagnostic" else "conduit-password-test")
FIXED_HASH = "$2b$10$......................naFBfND/0rjnzNKXE2KCY4zIW5UdykO"


@contextmanager
def probe(case, workers=1, http_env=None, args=None, threads=8,
          unset=(), expected_exit=0):
    env = os.environ.copy()
    env.update(BCRYPT_MODE=os.environ.get("PASSWORD_TEST_MODE", "batch"),
               BCRYPT_WORKERS=str(workers))
    if http_env:
        env.update(http_env)
    for key in unset:
        env.pop(key, None)
    command = args or ["--test-password-http" if http_env else
                       "--test-password-async"]
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(
            [str(EXE), *command, f"--ponymaxthreads={threads}"], env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors,
            bufsize=0)
        run = None
        try:
            run = PoolRun(case, process, None, csv="--test-http" in command,
                          count=1, actors=1)
            yield run
        finally:
            failure = sys.exc_info()[1]
            if process.poll() is None:
                try:
                    process.stdin.write(b"quit\n")
                    process.stdin.flush()
                    process.wait(timeout=5)
                except (subprocess.TimeoutExpired, BrokenPipeError):
                    process.kill()
                    process.wait(timeout=5)
            if run:
                run.selector.close()
            process.stdin.close()
            process.stdout.close()
            errors.seek(0)
            details = errors.read().decode(errors="replace")
            if failure is None:
                case.assertEqual(process.returncode, expected_exit, details)
            elif process.returncode:
                failure.add_note(f"probe exit {process.returncode}: {details}")


def event(run, name, **fields):
    return run.receive(lambda x: x.get("event") == name and
                       all(x.get(k) == v for k, v in fields.items()))


def pool_state(run, number=1):
    run.send(f"state {number}")
    return event(run, "pool", request=number)


def reply_ledger(case, run, expected):
    pool_state(run, 9000)
    run.send("clients 9000")
    for client in (0, 1):
        event(run, "client_checkpoint", client=client, request=9000)
    actual = [(x["client"], x["id"], x["hash"], x["kind"])
              for x in run.history if x.get("event") == "reply"]
    case.assertCountEqual(actual, expected)


class PasswordActors(unittest.TestCase):
    def test_real_compute_modes(self):
        for mode in ("scalar", "batch"):
            with self.subTest(mode=mode), probe(self) as run:
                for n in (1, 2, 3, 4):
                    run.send(f"compute {n} {n * 10} verify nul {mode}")
                    actual = event(run, "actual")
                    self.assertEqual(actual["interleaved"],
                                     n if mode == "batch" and n >= 2 else 0)
                    self.assertEqual(actual["scalar"],
                                     n if mode == "scalar" or n == 1 else 0)
                    for id in range(n * 10, n * 10 + n):
                        self.assertEqual(event(run, "reply", id=id)["kind"],
                                         "verified")
                reply_ledger(self, run, [(0, n * 10 + i, False, "verified")
                    for n in (1, 2, 3, 4) for i in range(n)])

    def test_lone_fifo_capacity_and_routing(self):
        for workers in (1, 2, 8):
            with self.subTest(workers=workers), probe(self, workers) as run:
                held = {}
                selected = []
                for n in range(workers):
                    kind = "hash" if n % 2 else "verify"
                    run.send(f"job {n % 2} {n + 1} {kind} nul")
                    value = event(run, "held")
                    self.assertEqual(value["ids"], [n + 1])
                    self.assertNotIn(value["worker"], held)
                    held[value["worker"]] = value["ids"]
                    selected.extend(value["ids"])
                count = workers + 13
                for n in range(workers + 1, count + 1):
                    kind = "hash" if n % 2 else "verify"
                    run.send(f"job {n % 2} {n} {kind} empty")
                state = pool_state(run)
                self.assertEqual((state["pending"], state["busy"],
                                  state["idle"]), (13, workers, 0))
                finished = 0
                while held:
                    index = sorted(held)[-1]
                    ids = held.pop(index)
                    run.send(f"release {index} fail")
                    event(run, "completed", worker=index)
                    for id in ids:
                        reply = event(run, "reply", id=id)
                        expected_client = ((id - 1) % 2 if id <= workers
                                           else id % 2)
                        self.assertEqual(reply["client"], expected_client)
                        self.assertEqual(reply["kind"], "failed")
                        finished += 1
                    if len(selected) < count:
                        value = event(run, "held")
                        self.assertNotIn(value["worker"], held)
                        self.assertTrue(1 <= len(value["ids"]) <= 4)
                        selected.extend(value["ids"])
                        held[value["worker"]] = value["ids"]
                self.assertEqual(selected, list(range(1, count + 1)))
                self.assertEqual(finished, count)
                state = pool_state(run, 2)
                self.assertEqual((state["pending"], state["busy"],
                                  state["idle"]), (0, 0, workers))
                reply_ledger(self, run,
                    [(n % 2, n + 1, bool(n % 2), "failed")
                     for n in range(workers)] +
                    [(n % 2, n, bool(n % 2), "failed")
                     for n in range(workers + 1, count + 1)])

    def test_native_rejection_releases_worker(self):
        with probe(self) as run:
            run.send("job 0 10 hash nul")
            warm = event(run, "held")
            run.send(f"release {warm['worker']} real")
            self.assertTrue(event(run, "reply", id=10)["valid"])
            run.send("job 0 1 hash nul")
            held = event(run, "held")
            run.send("job 1 2 verify nul")
            state = pool_state(run)
            self.assertEqual((state["pending"], state["busy"],
                              state["idle"]), (1, 1, 0))
            run.send(f"release {held['worker']} reject")
            self.assertEqual(event(run, "reply", id=1)["kind"], "failed")
            event(run, "completed", worker=held["worker"],
                  interleaved=0, scalar=0)
            follow = event(run, "held")
            self.assertEqual(follow["ids"], [2])
            run.send(f"release {follow['worker']} real")
            self.assertEqual(event(run, "reply", id=2)["kind"], "verified")
            state = pool_state(run, 2)
            self.assertEqual((state["pending"], state["busy"],
                              state["idle"]), (0, 0, 1))
            reply_ledger(self, run, [(0, 10, True, "hashed"),
                (0, 1, True, "failed"), (1, 2, False, "verified")])

    def test_generated_dispatcher_model(self):
        seen_workers, seen_rounds, seen_kinds = set(), set(), set()
        for seed in range(6):
            rng = random.Random(0xBC00 + seed)
            workers, rounds = 1 + seed % 3, 1 + seed % 4
            seen_workers.add(workers)
            seen_rounds.add(rounds)
            with self.subTest(seed=seed), probe(self, workers) as run:
                next_id = 0
                submitted, pending, busy = [], [], {}

                def submit(count):
                    nonlocal next_id
                    jobs = []
                    for _ in range(count):
                        next_id += 1
                        client = rng.randrange(2)
                        hash = bool(rng.getrandbits(1))
                        seen_kinds.add(hash)
                        jobs.append((client, next_id, hash))
                    run.send(*(f"job {client} {id} " +
                        ("hash" if hash else "verify") + " empty"
                        for client, id, hash in jobs))
                    submitted.extend(jobs)
                    return jobs

                for _ in range(workers):
                    jobs = submit(1)
                    held = event(run, "held")
                    self.assertNotIn(held["worker"], busy)
                    self.assertEqual(held["ids"], [jobs[0][1]])
                    busy[held["worker"]] = jobs
                for turn in range(rounds):
                    pending.extend(submit(rng.randint(4, 7)))
                    state = pool_state(run, 100 + turn)
                    self.assertEqual((state["pending"], state["busy"],
                                      state["idle"]),
                                     (len(pending), workers, 0))
                    index = rng.choice(sorted(busy))
                    run.send(f"release {index} fail")
                    event(run, "completed", worker=index)
                    held = event(run, "held")
                    self.assertEqual(held["worker"], index)
                    self.assertEqual(held["ids"], [x[1] for x in pending[:4]])
                    busy[index] = pending[:4]
                    del pending[:4]
                run.send("stop", "stop")
                submit(2)
                state = pool_state(run, 200)
                self.assertEqual((state["pending"], state["busy"],
                                  state["idle"], state["stopped"]),
                                 (0, workers, 0, True))
                order = list(busy)
                rng.shuffle(order)
                for index in order:
                    run.send(f"release {index} fail")
                event(run, "stopped")
                state = pool_state(run, 201)
                self.assertEqual((state["pending"], state["busy"],
                                  state["idle"]), (0, 0, 0))
                reply_ledger(self, run, [(client, id, hash, "failed")
                                        for client, id, hash in submitted])
                self.assertEqual(sum(x.get("event") == "stopped"
                                     for x in run.history), 1)
        self.assertEqual(seen_workers, {1, 2, 3})
        self.assertEqual(seen_rounds, {1, 2, 3, 4})
        self.assertEqual(seen_kinds, {False, True})

    def test_stop_pending_and_inflight(self):
        with probe(self, 2) as run:
            run.send("job 0 1 hash nul")
            a = event(run, "held")
            run.send("job 1 1 verify empty")
            b = event(run, "held")
            run.send("job 0 3 hash empty", "job 1 4 verify empty",
                     "stop", "stop", "job 0 5 hash empty")
            for id in (3, 4, 5):
                self.assertEqual(event(run, "reply", id=id)["kind"], "failed")
            state = pool_state(run)
            self.assertEqual((state["pending"], state["busy"]), (0, 2))
            self.assertFalse(any(x["event"] == "stopped" for x in run.history))
            run.send(f"release {b['worker']} real")
            self.assertEqual(event(run, "reply", client=1, id=1)["kind"],
                             "verified")
            self.assertEqual(pool_state(run, 2)["busy"], 1)
            run.send(f"release {a['worker']} real")
            self.assertTrue(event(run, "reply", client=0, id=1)["valid"])
            event(run, "stopped")
            state = pool_state(run, 3)
            self.assertEqual((state["pending"], state["busy"]), (0, 0))
            self.assertEqual(sum(x["event"] == "stopped"
                                 for x in run.history), 1)
            reply_ledger(self, run, [(0, 1, True, "hashed"),
                (1, 1, False, "verified"), (0, 3, True, "failed"),
                (1, 4, False, "failed"), (0, 5, True, "failed")])

    def test_idle_stop_is_idempotent(self):
        with probe(self) as run:
            run.send("stop")
            event(run, "stopped")
            run.send("stop", "job 0 1 hash empty", "job 0 2 verify empty")
            self.assertEqual(event(run, "reply", id=1)["kind"], "failed")
            self.assertEqual(event(run, "reply", id=2)["kind"], "failed")
            state = pool_state(run)
            self.assertEqual((state["pending"], state["busy"],
                              state["idle"]), (0, 0, 0))
            self.assertTrue(state["stopped"])
            self.assertEqual(sum(x["event"] == "stopped"
                                 for x in run.history), 1)
            reply_ledger(self, run, [(0, 1, True, "failed"),
                                     (0, 2, False, "failed")])

    def test_adapter_reuse_bytes_status_and_rejection(self):
        with probe(self) as run:
            for count, first, kind, key, expected in (
                    (4, 10, "hash", "nul", "hashed"),
                    (1, 20, "hash", "72", "hashed"),
                    (3, 30, "verify", "utf8", "verified"),
                    (2, 40, "wrong", "nul", "rejected"),
                    (4, 50, "hash", "73", "failed"),
                    (2, 60, "hash", "empty", "hashed"),
                    (2, 90, "hash", "utf72", "hashed"),
                    (2, 95, "hash", "utf73", "failed")):
                run.send(f"adapter {count} {first} {kind} {key}")
                value = event(run, "adapter")
                eligible = 0 if key in ("73", "utf73") else count
                self.assertEqual(value["interleaved"],
                                 eligible if eligible >= 2 else 0)
                self.assertEqual(value["scalar"],
                                 1 if eligible == 1 else 0)
                for id in range(first, first + count):
                    reply = event(run, "reply", id=id)
                    self.assertEqual(reply["kind"], expected)
                    self.assertTrue(reply.get("valid", True))
            run.send("adapter 4 100 hash nul")
            event(run, "adapter")
            for id in range(100, 104):
                self.assertEqual(event(run, "reply", id=id)["kind"], "hashed")
            run.send("reject-next", "adapter 4 70 hash nul")
            value = event(run, "adapter")
            for id in range(70, 74):
                self.assertEqual(event(run, "reply", id=id)["kind"], "failed")
            self.assertEqual((value["interleaved"], value["scalar"]), (0, 0))
            run.send("adapter 2 80 verify nul")
            self.assertEqual(event(run, "adapter")["interleaved"], 2)
            for id in (80, 81):
                self.assertEqual(event(run, "reply", id=id)["kind"], "verified")
            run.send("reject-next", "adapter 2 85 verify nul")
            value = event(run, "adapter")
            for id in (85, 86):
                self.assertEqual(event(run, "reply", id=id)["kind"], "failed")
            self.assertEqual((value["interleaved"], value["scalar"]), (0, 0))
            run.send("adapter 1 87 verify nul")
            self.assertEqual(event(run, "adapter")["scalar"], 1)
            self.assertEqual(event(run, "reply", id=87)["kind"], "verified")
            metadata = json.dumps(run.history)
            self.assertNotIn(r"a\u0000b", metadata)
            self.assertNotIn("$2b$", metadata)


class PasswordOptions(unittest.TestCase):
    def environment(self, mode="batch", workers="1"):
        env = os.environ.copy()
        env.update(DATABASE_URL="postgres://test:test@127.0.0.1:1/test",
                   JWT_SECRET="startup-test", HOST="127.0.0.1", PORT="30997",
                   BCRYPT_MODE=mode, BCRYPT_WORKERS=workers,
                   CONDUIT_TEST_POOL_SIZE="1")
        return env

    def test_invalid_configuration_stops_before_startup(self):
        cases = [("wrong", "1"), ("Batch", "1"), ("", "1")]
        cases += [(mode, workers) for mode in ("inline", "scalar", "batch")
                  for workers in ("", "0", "9", "-1", "+1", " 1", "1 ",
                                  "1x", "18446744073709551616")]
        corpus = [a + b for a in "018x+" for b in "018x+"]
        invalid = [value for value in corpus if not
                   (all("0" <= c <= "9" for c in value) and
                    1 <= int(value) <= 8)]
        cases += [(mode, value) for mode in ("inline", "scalar", "batch")
                  for value in invalid]
        for mode, workers in cases:
            with self.subTest(mode=mode, workers=workers):
                result = subprocess.run([str(EXE), "--test-http",
                    "--test-password-startup", "--db-worker-count=1",
                    "--ponymaxthreads=8"], env=self.environment(mode, workers),
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 1)
                self.assertIn("Invalid BCRYPT", result.stderr)
                self.assertEqual(result.stdout, "")
        for threads in (1, 2):
            result = subprocess.run([str(EXE), "--test-http",
                "--test-password-startup", "--db-worker-count=1",
                f"--ponymaxthreads={threads}"], env=self.environment(
                    "inline", str(threads + 1)), capture_output=True,
                text=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Invalid BCRYPT", result.stderr)

    def test_actual_startup_modes_and_counts(self):
        for mode, workers in ([("inline", 1), ("scalar", 1)] +
                              [("batch", n) for n in range(1, 9)]):
            env = self.environment(mode, "000" + str(workers))
            with socket.socket() as s:
                s.bind(("127.0.0.1", 0))
                env["PORT"] = str(s.getsockname()[1])
            with self.subTest(mode=mode, workers=workers), probe(self,
                    workers, env, ["--test-http", "--test-password-startup",
                                   "--db-worker-count=1"]) as run:
                startup = event(run, "startup")
                self.assertEqual(startup["inline"], mode == "inline")
                self.assertEqual(startup["pool"], mode != "inline")
                self.assertEqual(startup["workers"], workers)
                if mode != "inline":
                    self.assertEqual(pool_state(run)["idle"], workers)
                created = [x["worker"] for x in run.history
                           if x.get("event") == "created"]
                self.assertEqual(created, [] if mode == "inline" else
                                 list(range(workers)))

    def test_batch_startup_failure(self):
        result = subprocess.run([str(EXE), "--test-http",
            "--test-password-startup-failure", "--ponymaxthreads=8"],
            env=self.environment(), capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Bcrypt batch self-test failed", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_defaults_and_scheduler_cap(self):
        args = ["--test-http", "--test-password-startup", "--db-worker-count=1"]
        for threads in (1, 2):
            env = self.environment("batch", str(threads))
            with socket.socket() as s:
                s.bind(("127.0.0.1", 0))
                env["PORT"] = str(s.getsockname()[1])
            with self.subTest(threads=threads), probe(self, threads, env,
                    args, threads=threads) as run:
                self.assertEqual(event(run, "startup")["workers"], threads)
                self.assertEqual(pool_state(run)["idle"], threads)
        env = self.environment("batch", "8")
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            env["PORT"] = str(s.getsockname()[1])
        with probe(self, 8, env, args, threads=9) as run:
            self.assertEqual(event(run, "startup")["workers"], 8)
            self.assertEqual(pool_state(run)["idle"], 8)
        result = subprocess.run([str(EXE), *args, "--ponymaxthreads=9"],
            env=self.environment("batch", "9"), capture_output=True,
            text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Invalid BCRYPT", result.stderr)
        self.assertEqual(result.stdout, "")
        for threads in (1, 2, 3, 8):
            env = self.environment()
            with socket.socket() as s:
                s.bind(("127.0.0.1", 0))
                env["PORT"] = str(s.getsockname()[1])
            with self.subTest(default_threads=threads), probe(self,
                    http_env=env, args=args, threads=threads,
                    unset=("BCRYPT_MODE", "BCRYPT_WORKERS")) as run:
                startup = event(run, "startup")
                self.assertFalse(startup["inline"])
                self.assertTrue(startup["pool"])
                self.assertEqual(startup["workers"], min(3, threads))
                self.assertEqual(pool_state(run)["idle"], min(3, threads))

    def test_listener_failure_stops_password_pool(self):
        with socket.socket() as occupied:
            occupied.bind(("127.0.0.1", 0))
            occupied.listen()
            env = self.environment("batch", "2")
            env["PORT"] = str(occupied.getsockname()[1])
            with probe(self, 2, env,
                    ["--test-http", "--test-password-startup",
                     "--db-worker-count=1"], expected_exit=1) as run:
                event(run, "stopped")

    def test_normal_listener_close_keeps_password_pool(self):
        env = self.environment("batch", "2")
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            env["PORT"] = str(s.getsockname()[1])
        with probe(self, 2, env, ["--test-http", "--test-password-startup",
                                 "--db-worker-count=1"]) as run:
            run.send("listener-close")
            event(run, "listener_closed")
            state = pool_state(run)
            self.assertFalse(state["stopped"])
            self.assertEqual(state["idle"], 2)


class PasswordHTTP(unittest.TestCase):
    sql = classmethod(Integration.sql.__func__)
    literal = staticmethod(Integration.literal)
    token = classmethod(Integration.token.__func__)

    @classmethod
    def setUpClass(cls):
        cls.database = "pony_password_" + uuid.uuid4().hex
        cls.secret = "password-probe-secret"
        cls.sql(f"CREATE DATABASE {cls.database} TEMPLATE conduit_dev")
        cls.addClassCleanup(cls.sql,
                            f"DROP DATABASE {cls.database} WITH (FORCE)")

    def db(self, sql):
        return self.sql(sql, self.database)

    def fixture(self):
        name = "password_" + uuid.uuid4().hex
        rows = self.db("INSERT INTO users(username,email,password_hash) "
            f"VALUES ('{name}','{name}@test.invalid','{FIXED_HASH}') "
            "RETURNING id")
        id = int(rows.splitlines()[0])
        return id, name + "@test.invalid", self.token(id)

    def environment(self):
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        host = os.environ.get("PGHOST", "127.0.0.1")
        if host.startswith("/"):
            host = "127.0.0.1"
        return dict(DATABASE_URL=f"postgres://conduit:conduit@{host}:"
                    f"{os.environ.get('PGPORT', '5432')}/{self.database}",
                    JWT_SECRET=self.secret, HOST="127.0.0.1", PORT=str(port))

    @contextmanager
    def connection(self, env):
        deadline = time.monotonic() + 10
        while True:
            try:
                s = socket.create_connection(("127.0.0.1", int(env["PORT"])), 1)
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.01)
        s.settimeout(10)
        stream = s.makefile("rb")
        try:
            yield s, stream
        finally:
            stream.close()
            s.close()

    def wire(self, method, path, body=None, token=None):
        data = json.dumps(body).encode() if body is not None else b""
        auth = f"Authorization: Token {token}\r\n" if token else ""
        return (f"{method} {path} HTTP/1.1\r\nHost: test\r\n{auth}"
                f"Content-Type: application/json\r\nContent-Length: {len(data)}"
                "\r\n\r\n").encode() + data

    def response(self, stream):
        status = int(stream.readline().split()[1])
        headers = {}
        while True:
            line = stream.readline()
            self.assertTrue(line, "response headers ended early")
            if line == b"\r\n":
                break
            key, value = line.split(b":", 1)
            headers[key.lower()] = value.strip()
        data = stream.read(int(headers[b"content-length"]))
        return status, json.loads(data) if data else None

    def accepted(self, run, id):
        return event(run, "accepted", id=id)

    def snapshot(self, run, connection, request=1):
        run.send(f"connstate {connection} {request}")
        state = event(run, "connection", connection=connection, request=request)
        event(run, "fence", connection=connection, request=request)
        return state

    def sql_ids(self, run, connection):
        return [x["id"] for x in run.history if x["event"] == "sql"
                and x["connection"] == connection]

    def barrier(self, run, id=999):
        run.send(f"barrier {id}")
        event(run, "barrier", id=id)

    def test_real_native_multiworker(self):
        for mode in ("scalar", "batch"):
            with self.subTest(mode=mode):
                env = self.environment()
                env.update(BCRYPT_MODE=mode, CONDUIT_TEST_POOL_SIZE="1")
                args = ["--test-http", "--test-password-startup",
                        "--db-worker-count=1"]
                with (probe(self, workers=2, http_env=env, args=args,
                            threads=2) as run,
                      self.connection(env) as (a, first),
                      self.connection(env) as (b, second)):
                    self.assertEqual(event(run, "startup")["workers"], 2)
                    self.assertEqual(pool_state(run)["idle"], 2)
                    users = []
                    for i, connection in enumerate((a, b)):
                        name = "native_" + uuid.uuid4().hex
                        user = dict(username=name, email=name + "@test.invalid",
                                    password="native-password-" + str(i))
                        users.append(user)
                        connection.sendall(self.wire("POST", "/api/users",
                                                     {"user": user}))
                    for user, stream in zip(users, (first, second)):
                        status, body = self.response(stream)
                        self.assertEqual(status, 201)
                        self.assertEqual(body["user"]["email"], user["email"])
                        self.assertEqual(body["user"]["username"],
                                         user["username"])
                        stored = self.db("SELECT password_hash FROM users "
                            f"WHERE email='{user['email']}'")
                        run.send(f"check-hash {user['password']} {stored}")
                        self.assertTrue(event(run, "checked")["valid"])
                    state = pool_state(run, 2)
                    self.assertEqual((state["pending"], state["busy"],
                                      state["idle"]), (0, 0, 2))
                    selected = [x["worker"] for x in run.history
                                if x.get("event") == "selected"]
                    completed = [x["worker"] for x in run.history
                                 if x.get("event") == "completed"]
                    self.assertIn(1, selected)
                    self.assertCountEqual(completed, selected)
                    for user, connection, stream in zip(users, (a, b),
                                                         (first, second)):
                        connection.sendall(self.wire("POST", "/api/users/login",
                            {"user": {"email": user["email"],
                                      "password": user["password"]}}))
                        status, body = self.response(stream)
                        self.assertEqual(status, 200)
                        self.assertEqual(body["user"]["username"],
                                         user["username"])
                    state = pool_state(run, 3)
                    self.assertEqual((state["pending"], state["busy"],
                                      state["idle"]), (0, 0, 2))

    def test_real_native_endpoint_policy(self):
        for mode in ("inline", "scalar", "batch"):
            env = self.environment()
            env.update(BCRYPT_MODE=mode, CONDUIT_TEST_POOL_SIZE="1")
            args = ["--test-http", "--test-password-startup",
                    "--db-worker-count=1"]
            with (self.subTest(mode=mode),
                  probe(self, http_env=env, args=args) as run,
                  self.connection(env) as (s, stream)):
                for password in ("a" * 72, "é" * 36, "a\0b"):
                    with self.subTest(password_bytes=len(password.encode())):
                        name = "policy_" + uuid.uuid4().hex
                        user = dict(username=name, email=name + "@test.invalid",
                                    password=password)
                        s.sendall(self.wire("POST", "/api/users",
                                            {"user": user}))
                        status, body = self.response(stream)
                        self.assertEqual(status, 201)
                        token = body["user"]["token"]
                        stored = self.db("SELECT password_hash FROM users "
                            f"WHERE email='{user['email']}'")
                        self.assertEqual(len(stored), 60)
                        self.assertTrue(stored.startswith("$2b$10$"))
                        for variant in "abxy":
                            hash = "$2" + variant + stored[3:]
                            self.db("UPDATE users SET password_hash=" +
                                self.literal(hash) + " WHERE email=" +
                                self.literal(user["email"]))
                            s.sendall(self.wire("POST", "/api/users/login",
                                {"user": {"email": user["email"],
                                          "password": password}}))
                            self.assertEqual(self.response(stream)[0], 200)
                        s.sendall(self.wire("POST", "/api/users/login",
                            {"user": {"email": user["email"],
                                      "password": "z" + password[1:]}}))
                        self.assertEqual(self.response(stream)[0], 401)
                        self.db("UPDATE users SET password_hash='malformed' "
                            "WHERE email=" + self.literal(user["email"]))
                        s.sendall(self.wire("POST", "/api/users/login",
                            {"user": {"email": user["email"],
                                      "password": password}}))
                        self.assertEqual(self.response(stream)[0], 401)
                        self.db("UPDATE users SET password_hash=" +
                            self.literal(stored) + " WHERE email=" +
                            self.literal(user["email"]))
                        if len(password.encode()) == 72:
                            s.sendall(self.wire("POST", "/api/users/login",
                                {"user": {"email": user["email"],
                                          "password": password + "x"}}))
                            self.assertEqual(self.response(stream)[0], 200)
                            s.sendall(self.wire("PUT", "/api/user",
                                {"user": {"password": password + "x"}}, token))
                            self.assertEqual(self.response(stream)[0], 422)
                            self.assertEqual(self.db("SELECT password_hash "
                                "FROM users WHERE email=" +
                                self.literal(user["email"])), stored)
                        s.sendall(self.wire("POST", "/api/users",
                                            {"user": user}))
                        self.assertEqual(self.response(stream)[0], 422)
                if mode != "inline":
                    state = pool_state(run)
                    self.assertEqual((state["pending"], state["busy"],
                                      state["idle"]), (0, 0, 1))

    def test_password_then_plain_update(self):
        user, _, token = self.fixture()
        env = self.environment()
        with (probe(self, http_env=env) as run,
              self.connection(env) as (s, stream)):
            s.sendall(self.wire("PUT", "/api/user", {"user": {
                "password": "new-password", "bio": "A"}}, token) +
                self.wire("PUT", "/api/user", {"user": {"bio": "B"}}, token))
            c = self.accepted(run, 1)["connection"]
            second = self.accepted(run, 2)
            held = event(run, "held")
            state = self.snapshot(run, c)
            self.assertEqual(state["waiting"], 1)
            self.assertEqual(self.sql_ids(run, c), [])
            run.send(f"release {held['worker']} real")
            self.assertEqual(self.response(stream)[0], 200)
            self.assertEqual(self.response(stream)[0], 200)
            self.snapshot(run, c, 2)
            self.assertEqual(self.sql_ids(run, c), [1, 2])
            self.assertEqual(self.db(
                f"SELECT bio FROM users WHERE id={user}"), "B")
            self.assertTrue(second["queued"])

    def test_two_hash_waits_wrong_completions_and_replay(self):
        user, _, token = self.fixture()
        env = self.environment()
        with (probe(self, http_env=env) as run,
              self.connection(env) as (s, stream)):
            s.sendall(b"".join(self.wire("PUT", "/api/user",
                {"user": body}, token)
                for body in ({"password": "first", "bio": "A"},
                             {"password": "second", "bio": "B"}, {"bio": "C"})))
            c = self.accepted(run, 1)["connection"]
            self.accepted(run, 2)
            self.accepted(run, 3)
            a = event(run, "held")
            run.send(f"bad-hash {c} 999", f"bad-verify {c} 1", f"replay {c}")
            self.assertEqual(self.snapshot(run, c)["waiting"], 1)
            self.assertEqual(self.sql_ids(run, c), [])
            run.send(f"release {a['worker']} real")
            b = event(run, "held")
            run.send(f"bad-hash {c} 1", f"bad-verify {c} 2")
            self.assertEqual(self.snapshot(run, c, 2)["waiting"], 2)
            self.assertEqual(self.sql_ids(run, c), [1])
            run.send(f"release {b['worker']} real")
            for _ in range(3):
                self.assertEqual(self.response(stream)[0], 200)
            state = self.snapshot(run, c, 3)
            self.assertEqual(self.sql_ids(run, c), [1, 2, 3])
            self.assertEqual((state["operations"], state["pending"],
                              state["waiting"]), (0, 0, 0))
            self.assertEqual(self.db(
                f"SELECT bio FROM users WHERE id={user}"), "C")

    def test_operation_replay_cannot_submit_twice(self):
        _, _, token = self.fixture()
        env = self.environment()
        with (probe(self, http_env=env) as run,
              self.connection(env) as (s, stream)):
            s.sendall(self.wire("PUT", "/api/user", {"user": {
                "password": "replay", "bio": "once"}}, token))
            c = self.accepted(run, 1)["connection"]
            held = event(run, "held")
            run.send(f"replay {c}", f"release {held['worker']} real")
            event(run, "completed", worker=held["worker"])
            state = self.snapshot(run, c)
            self.assertEqual(self.sql_ids(run, c), [1])
            self.assertEqual(state["waiting"], 0)
            self.assertEqual(self.response(stream)[0], 200)

    def test_two_verify_waits_wrong_completions_and_replay(self):
        user, email, token = self.fixture()
        env = self.environment()
        with (probe(self, http_env=env) as run,
              self.connection(env) as (s, stream)):
            login = self.wire("POST", "/api/users/login", {"user": {
                "email": email, "password": "password123"}})
            s.sendall(login)
            c = self.accepted(run, 1)["connection"]
            a = event(run, "held")
            s.sendall(login)
            self.accepted(run, 2)
            run.send(f"bad-verify {c} 2", f"bad-hash {c} 1")
            state = self.snapshot(run, c)
            self.assertEqual((state["waiting"], state["hash"]), (1, False))
            self.assertEqual(self.sql_ids(run, c), [1])
            run.send(f"replay {c}", f"release {a['worker']} real")
            b = event(run, "held")
            s.sendall(self.wire("PUT", "/api/user",
                {"user": {"bio": "after-verifies"}}, token))
            self.accepted(run, 3)
            run.send(f"bad-verify {c} 1", f"bad-hash {c} 2")
            state = self.snapshot(run, c, 2)
            self.assertEqual((state["waiting"], state["hash"]), (2, False))
            self.assertEqual(self.sql_ids(run, c), [1, 2])
            run.send(f"release {b['worker']} real")
            for _ in range(3):
                self.assertEqual(self.response(stream)[0], 200)
            state = self.snapshot(run, c, 3)
            self.assertEqual(self.sql_ids(run, c), [1, 2, 3])
            self.assertEqual((state["operations"], state["pending"],
                              state["waiting"]), (0, 0, 0))
            self.assertEqual(self.db(
                f"SELECT bio FROM users WHERE id={user}"), "after-verifies")

    def test_verify_outcomes_and_continuation_errors_release_gate(self):
        for kind, continuation, status in (("verified", False, 200),
                ("rejected", False, 401), ("fail", False, 401),
                ("verified", True, 500)):
            with self.subTest(kind=kind, continuation=continuation):
                user, email, token = self.fixture()
                env = self.environment()
                with (probe(self, http_env=env) as run,
                      self.connection(env) as (s, stream)):
                    s.sendall(self.wire("POST", "/api/users/login", {"user": {
                        "email": email, "password": "password123"}}))
                    c = self.accepted(run, 1)["connection"]
                    held = event(run, "held")
                    wait = event(run, "wait", connection=c, id=1)
                    self.assertFalse(wait["hash"])
                    s.sendall(self.wire("PUT", "/api/user",
                        {"user": {"bio": "later"}}, token))
                    self.accepted(run, 2)
                    run.send(f"bad-verify {c} 2")
                    state = self.snapshot(run, c, 10)
                    self.assertEqual((state["waiting"], state["hash"]),
                                     (1, False))
                    self.assertEqual(self.sql_ids(run, c), [1])
                    run.send(f"bad-hash {c} 1")
                    state = self.snapshot(run, c, 11)
                    self.assertEqual((state["waiting"], state["hash"]),
                                     (1, False))
                    self.assertEqual(self.sql_ids(run, c), [1])
                    if continuation:
                        run.send(f"continuation-error {c}")
                    self.assertEqual(self.snapshot(run, c)["waiting"], 1)
                    self.assertEqual(self.sql_ids(run, c), [1])
                    run.send(f"release {held['worker']} {kind}")
                    event(run, "completed", worker=held["worker"])
                    self.assertEqual(self.snapshot(run, c, 3)["waiting"], 0)
                    self.assertEqual(self.response(stream)[0], status)
                    self.assertEqual(self.response(stream)[0], 200)
                    run.send(f"bad-verify {c} 1", f"bad-hash {c} 1")
                    self.snapshot(run, c, 2)
                    self.assertEqual(self.sql_ids(run, c), [1, 2])
                    self.assertEqual(self.db(
                        f"SELECT bio FROM users WHERE id={user}"), "later")

    def test_hash_failure_and_continuation_error(self):
        for continuation in (False, True):
            user, _, token = self.fixture()
            env = self.environment()
            with (self.subTest(continuation=continuation),
                  probe(self, http_env=env) as run,
                  self.connection(env) as (s, stream)):
                s.sendall(self.wire("PUT", "/api/user", {"user": {
                    "password": "first"}}, token) + self.wire("PUT",
                    "/api/user", {"user": {"password": "second",
                        "bio": "after-failure"}}, token))
                c = self.accepted(run, 1)["connection"]
                self.accepted(run, 2)
                held = event(run, "held")
                if continuation:
                    run.send(f"continuation-error {c}")
                result = "real" if continuation else "fail"
                run.send(f"release {held['worker']} {result}")
                event(run, "completed", worker=held["worker"])
                next_wait = event(run, "held")
                state = self.snapshot(run, c, 3)
                self.assertEqual((state["waiting"], state["hash"]), (2, True))
                self.assertEqual(self.sql_ids(run, c), [])
                self.assertEqual(self.response(stream)[0], 422)
                run.send(f"release {next_wait['worker']} real")
                event(run, "completed", worker=next_wait["worker"])
                self.assertEqual(self.response(stream)[0], 200)
                self.assertEqual(self.snapshot(run, c)["waiting"], 0)
                self.assertEqual(self.sql_ids(run, c), [2])
                self.assertEqual(self.db(
                    f"SELECT bio FROM users WHERE id={user}"), "after-failure")

    def test_register_then_login_distinct_bodies(self):
        name = "register_" + uuid.uuid4().hex
        env = self.environment()
        with (probe(self, http_env=env) as run,
              self.connection(env) as (s, stream)):
            s.sendall(self.wire("POST", "/api/users", {"user": {
                "username": name, "email": name + "@test.invalid",
                "password": "register-pass"}}) +
                self.wire("POST", "/api/users/login", {"user": {
                    "email": name + "@test.invalid",
                    "password": "register-pass"}}))
            c = self.accepted(run, 1)["connection"]
            self.accepted(run, 2)
            h = event(run, "held")
            run.send(f"release {h['worker']} real")
            self.assertEqual(self.response(stream)[0], 201)
            v = event(run, "held")
            run.send(f"release {v['worker']} real")
            status, body = self.response(stream)
            self.assertEqual(status, 200)
            self.assertEqual(body["user"]["username"], name)
            self.snapshot(run, c)
            self.assertEqual(self.sql_ids(run, c), [1, 2])

    def reset_peer(self, s, stream):
        s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                     struct.pack("ii", 1, 0))
        stream.close()
        s.close()

    def closed_state(self, run, c, accepted):
        event(run, "logical", connection=c)
        event(run, "fence", connection=c, request=0)
        self.barrier(run)
        state = self.snapshot(run, c, 901)
        self.assertEqual(state["accepted"], accepted)
        self.assertTrue(state["closed"])
        self.assertEqual(tuple(state[k] for k in
            ("operations", "responders", "body", "pending", "waiting")),
            (0, 0, 0, 0, 0))
        return state

    def test_close_preserves_two_hashes_and_discards_partial_body(self):
        user, _, token = self.fixture()
        env = self.environment()
        with (probe(self, http_env=env) as run,
              self.connection(env) as (s, stream)):
            s.sendall(b"".join(self.wire("PUT", "/api/user",
                {"user": body}, token)
                for body in ({"password": "first", "bio": "A"},
                             {"password": "second", "bio": "B"}, {"bio": "C"})))
            c = self.accepted(run, 1)["connection"]
            self.accepted(run, 2)
            self.accepted(run, 3)
            a = event(run, "held")
            s.sendall(b"PUT /api/user HTTP/1.1\r\nHost: test\r\n"
                      b"Content-Length: 100\r\n\r\n{\"user\":")
            deadline = time.monotonic() + 10
            request = 100
            while True:
                before = self.snapshot(run, c, request)
                if before["body"] > 0:
                    break
                self.assertLess(time.monotonic(), deadline,
                                "connection did not retain partial body")
                request += 1
            self.assertEqual(before["accepted"], 3)
            self.reset_peer(s, stream)
            physical = event(run, "physical", connection=c)
            self.assertEqual((physical["responders"], physical["body"]), (0, 0))
            self.assertEqual(physical["operations"], 3)
            run.send(f"repeatclose {c}", f"release {a['worker']} real")
            event(run, "completed", worker=a["worker"])
            self.snapshot(run, c, 799)
            self.assertEqual(self.sql_ids(run, c), [1])
            b = event(run, "held")
            state = self.snapshot(run, c, 800)
            self.assertEqual(state["waiting"], 2)
            self.assertEqual(self.sql_ids(run, c), [1])
            run.send(f"release {b['worker']} real")
            self.closed_state(run, c, 3)
            self.assertEqual(self.sql_ids(run, c), [1, 2, 3])
            ledger = [x["event"] for x in run.history if
                x["event"] in ("sql", "cancel") and x["connection"] == c]
            self.assertEqual(ledger, ["sql", "sql", "sql", "cancel"])
            self.assertEqual(self.db(
                f"SELECT bio FROM users WHERE id={user}"), "C")
            stored = self.db(f"SELECT password_hash FROM users WHERE id={user}")
            run.send(f"check-hash second {stored}")
            self.assertTrue(event(run, "checked")["valid"])
            run.send(f"check-hash first {stored}")
            self.assertFalse(event(run, "checked")["valid"])
            run.send(f"bad-hash {c} 1", f"bad-verify {c} 2",
                     f"late-db {c} 1", f"bad-row {c} 1", f"repeatclose {c}")
            after = self.snapshot(run, c, 902)
            self.assertEqual(after["operations"], 0)
            self.assertEqual(self.sql_ids(run, c), [1, 2, 3])
            self.assertEqual(sum(x["event"] == "cancel" and x["connection"] == c
                                 for x in run.history), 1)

    def test_close_during_verify_preserves_later_write(self):
        user, email, token = self.fixture()
        env = self.environment()
        with (probe(self, http_env=env) as run,
              self.connection(env) as (s, stream)):
            s.sendall(self.wire("POST", "/api/users/login", {"user": {
                "email": email, "password": "password123"}}))
            c = self.accepted(run, 1)["connection"]
            held = event(run, "held")
            self.assertFalse(event(run, "wait", connection=c)["hash"])
            s.sendall(self.wire("PUT", "/api/user",
                {"user": {"bio": "after-verify"}}, token))
            self.accepted(run, 2)
            self.reset_peer(s, stream)
            event(run, "physical", connection=c)
            run.send(f"release {held['worker']} real")
            event(run, "completed", worker=held["worker"])
            self.assertEqual(self.snapshot(run, c, 800)["waiting"], 0)
            self.closed_state(run, c, 2)
            self.assertEqual(self.sql_ids(run, c), [1, 2])
            self.assertEqual(self.db(
                f"SELECT bio FROM users WHERE id={user}"), "after-verify")

    def test_queued_database_result_installs_verify_after_close(self):
        user, email, token = self.fixture()
        env = self.environment()
        with (probe(self, http_env=env) as run,
              self.connection(env) as (s, stream),
              SQLSession(self.database) as blocker):
            blocker.execute("BEGIN; LOCK TABLE users IN ACCESS EXCLUSIVE MODE;")
            s.sendall(self.wire("POST", "/api/users/login", {"user": {
                "email": email, "password": "password123"}}) +
                self.wire("PUT", "/api/user", {"user": {
                    "password": "new", "bio": "A"}}, token) +
                self.wire("PUT", "/api/user", {"user": {"bio": "last"}}, token))
            c = self.accepted(run, 1)["connection"]
            self.accepted(run, 2)
            self.accepted(run, 3)
            h = event(run, "held")
            self.assertEqual(h["ids"], [2])
            blocker.execute("COMMIT;")
            self.assertTrue(event(run, "database", connection=c,
                                  id=1)["queued"])
            self.reset_peer(s, stream)
            event(run, "physical", connection=c)
            run.send(f"release {h['worker']} real")
            v = run.receive(lambda x: x["event"] in ("held", "logical"))
            self.assertEqual(v["event"], "held")
            self.assertEqual(v["ids"], [1])
            self.assertFalse(self.snapshot(run, c)["hash"])
            run.send(f"release {v['worker']} real")
            self.closed_state(run, c, 3)
            self.assertEqual(self.sql_ids(run, c), [1, 2, 3])
            self.assertEqual(self.db(
                f"SELECT bio FROM users WHERE id={user}"), "last")

    def test_database_failure_queued_behind_hash(self):
        user, email, token = self.fixture()
        env = self.environment()
        with (probe(self, http_env=env) as run,
              self.connection(env) as (s, stream),
              SQLSession(self.database) as blocker):
            blocker.execute("BEGIN; LOCK TABLE users IN SHARE MODE;")
            s.sendall(self.wire("POST", "/api/users", {"user": {
                "username": email.split("@")[0], "email": "other-" + email,
                "password": "duplicate"}}) + self.wire("PUT", "/api/user",
                {"user": {"password": "new", "bio": "after-sql-failure"}},
                token))
            c = self.accepted(run, 1)["connection"]
            self.accepted(run, 2)
            first = event(run, "held")
            run.send(f"release {first['worker']} real")
            second = event(run, "held")
            self.assertEqual(second["ids"], [2])
            blocker.execute("COMMIT;")
            self.assertTrue(event(run, "database", connection=c,
                                  id=1)["queued"])
            run.send(f"release {second['worker']} real")
            self.assertEqual(self.response(stream)[0], 422)
            self.assertEqual(self.response(stream)[0], 200)
            self.snapshot(run, c)
            self.assertEqual(self.sql_ids(run, c), [1, 2])
            self.assertEqual(self.db(f"SELECT bio FROM users WHERE id={user}"),
                             "after-sql-failure")

    def test_malformed_result_callback_releases_operation(self):
        user, email, token = self.fixture()
        env = self.environment()
        with (probe(self, http_env=env) as run,
              self.connection(env) as (s, stream),
              SQLSession(self.database) as blocker):
            blocker.execute("BEGIN; LOCK TABLE users IN ACCESS EXCLUSIVE MODE;")
            s.sendall(self.wire("POST", "/api/users/login", {"user": {
                "email": email, "password": "password123"}}))
            c = self.accepted(run, 1)["connection"]
            event(run, "sql", connection=c, id=1)
            run.send(f"bad-row {c} 1")
            self.assertEqual(self.response(stream)[0], 500)
            s.sendall(self.wire("PUT", "/api/user",
                {"user": {"bio": "after-bad-row"}}, token))
            self.accepted(run, 2)
            blocker.execute("COMMIT;")
            self.assertEqual(self.response(stream)[0], 200)
            state = self.snapshot(run, c)
            self.assertEqual(state["operations"], 0)
            self.assertEqual(self.sql_ids(run, c), [1, 2])
            self.assertEqual(self.db(
                f"SELECT bio FROM users WHERE id={user}"), "after-bad-row")

    def test_close_without_operations_has_no_cancel(self):
        env = self.environment()
        with (probe(self, http_env=env) as run,
              self.connection(env) as (s, stream)):
            s.sendall(self.wire("GET", "/api/tags"))
            c = self.accepted(run, 1)["connection"]
            self.assertEqual(self.response(stream)[0], 200)
            self.assertEqual(self.snapshot(run, c)["operations"], 0)
            self.reset_peer(s, stream)
            self.closed_state(run, c, 1)
            self.assertFalse(any(x["event"] == "cancel" and x["connection"] == c
                                 for x in run.history))

    def test_close_handler_ignores_late_body_and_request_callbacks(self):
        user, _, token = self.fixture()
        env = self.environment()
        with (probe(self, http_env=env) as run,
              self.connection(env) as (s, stream)):
            s.sendall(self.wire("PUT", "/api/user", {"user": {
                "password": "new", "bio": "accepted"}}, token))
            c = self.accepted(run, 1)["connection"]
            held = event(run, "held")
            run.send(f"handler-close {c}")
            event(run, "physical", connection=c)
            state = self.snapshot(run, c)
            self.assertEqual(state["accepted"], 1)
            self.assertEqual((state["body"], state["responders"]), (0, 0))
            self.assertEqual(state["pending"], 1)
            run.send(f"late-db {c} 1", f"bad-row {c} 1")
            self.assertEqual(self.snapshot(run, c, 2)["pending"], 1)
            run.send(f"release {held['worker']} real")
            self.closed_state(run, c, 1)
            self.assertEqual(self.sql_ids(run, c), [1])
            self.assertEqual(self.db(
                f"SELECT bio FROM users WHERE id={user}"), "accepted")
            self.reset_peer(s, stream)

    def test_observed_drain_progress_without_controller(self):
        user, _, token = self.fixture()
        env = self.environment()
        with (probe(self, http_env=env) as run,
              self.connection(env) as (s, stream)):
            first = self.wire("PUT", "/api/user", {"user": {
                "password": "new", "bio": "start"}}, token)
            queued = [self.wire("PUT", "/api/user", {"user": {
                "bio": f"observed-{i}"}}, token) for i in range(80)]
            s.sendall(first + b"".join(queued))
            c = self.accepted(run, 1)["connection"]
            for id in range(2, 82):
                self.accepted(run, id)
            held = event(run, "held")
            run.send(f"release {held['worker']} real")
            for _ in range(81):
                self.assertEqual(self.response(stream)[0], 200)
            state = self.snapshot(run, c)
            self.assertEqual((state["operations"], state["pending"],
                              state["waiting"]), (0, 0, 0))
            self.assertEqual(self.sql_ids(run, c), list(range(1, 82)))
            self.assertEqual(self.db(
                f"SELECT bio FROM users WHERE id={user}"), "observed-79")
            self.assertFalse(any(x.get("event") == "paused"
                                 for x in run.history))

    def test_new_ingress_during_yielded_drain(self):
        user, _, token = self.fixture()
        env = self.environment()
        with (probe(self, http_env=env) as run,
              self.connection(env) as (s, stream)):
            first = self.wire("PUT", "/api/user", {"user": {
                "password": "new", "bio": "start"}}, token)
            queued = [self.wire("PUT", "/api/user", {"user": {
                "bio": f"old-{i}"}}, token) for i in range(80)]
            s.sendall(first + b"".join(queued))
            c = self.accepted(run, 1)["connection"]
            for id in range(2, 82):
                self.accepted(run, id)
            held = event(run, "held")
            run.send(f"pause-drains {c}")
            run.send(f"release {held['worker']} real")
            paused = event(run, "paused", connection=c)
            self.assertTrue(paused["pending"])
            paused_state = self.snapshot(run, c, 900)
            self.assertEqual(paused_state["waiting"], 0)
            self.assertGreater(paused_state["pending"], 0)
            s.sendall(self.wire("PUT", "/api/user",
                {"user": {"bio": "new-last"}}, token))
            ingress = self.accepted(run, 82)
            self.assertEqual(ingress["epoch"], paused["epoch"])
            released = {paused["epoch"]}
            epoch = paused["epoch"]
            run.send(f"drain {c} {epoch}", f"drain {c} {epoch}", f"drain {c} 0")
            deadline = time.monotonic() + 10
            request = 1000
            while True:
                state = self.snapshot(run, c, request)
                for x in run.history:
                    if (x["event"] == "paused" and x["connection"] == c and
                            x["epoch"] not in released):
                        released.add(x["epoch"])
                        run.send(f"drain {c} {x['epoch']}")
                if state["operations"] == state["pending"] == 0:
                    break
                self.assertLess(time.monotonic(), deadline,
                                "drain did not finish")
                request += 1
            self.assertEqual(self.sql_ids(run, c), list(range(1, 83)))
            self.assertEqual(self.db(
                f"SELECT bio FROM users WHERE id={user}"), "new-last")
            self.assertTrue(ingress["queued"])
            self.assertIn(82, ingress["pending"])
            for _ in range(82):
                self.assertEqual(self.response(stream)[0], 200)


if __name__ == "__main__":
    unittest.main()
