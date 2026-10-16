import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import hmac
import http.client
import json
import os
from pathlib import Path
import selectors
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time
import unittest
import uuid


class ProtocolProxy(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, database_host, database_port, frame_timeout=15):
        self.database_host = database_host
        self.database_port = int(database_port)
        self.frame_timeout = frame_timeout
        self.messages = []
        self.backends = []
        self.mutate_next_row = False
        self.drop_next_command_complete = False
        self.command_complete_gate = None
        self.command_complete_skip = 0
        self.command_complete_abort = False
        self.lock = threading.Lock()
        self.connections = threading.BoundedSemaphore(64)
        super().__init__(("127.0.0.1", 0), ProtocolConnection)
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    def snapshot(self):
        with self.lock:
            return [list(messages) for messages in self.messages]

    def drop_backend(self, index=-1):
        with self.lock:
            backend = self.backends[index]
        backend.shutdown(socket.SHUT_RDWR)
        backend.close()

    def corrupt_next_data_row(self):
        with self.lock:
            self.mutate_next_row = True

    def suppress_next_command_complete(self):
        with self.lock:
            self.drop_next_command_complete = True

    def hold_command_complete_after(self, skipped):
        with self.lock:
            self.command_complete_gate = threading.Event()
            self.command_complete_skip = skipped
            self.command_complete_abort = False

    def release_command_complete(self, abort=False):
        with self.lock:
            self.command_complete_abort = abort
            gate = self.command_complete_gate
        if gate is not None:
            gate.set()

    def verify_request(self, request, client_address):
        return self.connections.acquire(blocking=False)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.connections.release()

    def stop(self):
        self.release_command_complete(abort=True)
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=5)


class ProtocolConnection(socketserver.BaseRequestHandler):
    @staticmethod
    def read_exact(connection, length, deadline=None):
        data = bytearray()
        while len(data) < length:
            if deadline is not None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError
                connection.settimeout(remaining)
            chunk = connection.recv(length - len(data))
            if not chunk:
                raise EOFError
            data.extend(chunk)
        return bytes(data)

    def handle(self):
        with socket.create_connection((self.server.database_host,
                                       self.server.database_port)) as backend:
            messages = []
            with self.server.lock:
                if len(self.server.messages) < 128:
                    self.server.messages.append(messages)
                    self.server.backends.append(backend)

            def downstream():
                try:
                    while True:
                        kind = self.read_exact(backend, 1)
                        size = self.read_exact(backend, 4)
                        length = int.from_bytes(size, "big")
                        if not 4 <= length <= 1048576:
                            break
                        payload = self.read_exact(backend, length - 4)
                        with self.server.lock:
                            mutate = kind == b"D" and self.server.mutate_next_row
                            if mutate:
                                self.server.mutate_next_row = False
                            suppress = (kind == b"C" and
                                        self.server.drop_next_command_complete)
                            if suppress:
                                self.server.drop_next_command_complete = False
                            gate = None
                            if kind == b"C" and self.server.command_complete_gate:
                                if self.server.command_complete_skip:
                                    self.server.command_complete_skip -= 1
                                else:
                                    gate = self.server.command_complete_gate
                        if suppress:
                            continue
                        if gate is not None:
                            gate.wait(10)
                            with self.server.lock:
                                abort = self.server.command_complete_abort
                                self.server.command_complete_gate = None
                            if abort:
                                continue
                        if mutate:
                            columns = int.from_bytes(payload[:2], "big") + 1
                            payload = (columns.to_bytes(2, "big") + payload[2:]
                                       + b"\xff\xff\xff\xff")
                            size = (length + 4).to_bytes(4, "big")
                        self.request.sendall(kind + size + payload)
                except (EOFError, OSError):
                    pass
                finally:
                    try:
                        self.request.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass

            thread = threading.Thread(target=downstream, daemon=True)
            thread.start()
            try:
                deadline = time.monotonic() + self.server.frame_timeout
                length = int.from_bytes(
                    self.read_exact(self.request, 4, deadline), "big")
                if not 4 <= length <= 1048576:
                    return
                payload = self.read_exact(self.request, length - 4, deadline)
                self.request.settimeout(None)
                backend.sendall(length.to_bytes(4, "big") + payload)
                while True:
                    kind = self.read_exact(self.request, 1)
                    deadline = time.monotonic() + self.server.frame_timeout
                    size = self.read_exact(self.request, 4, deadline)
                    length = int.from_bytes(size, "big")
                    if not 4 <= length <= 1048576:
                        return
                    payload = self.read_exact(self.request, length - 4,
                                              deadline)
                    self.request.settimeout(None)
                    if kind in (b"P", b"B"):
                        names = payload.split(b"\0", 2)
                        if kind == b"P":
                            captured = names[0][:128] + b"\0"
                        elif len(names) > 1:
                            captured = (names[0][:128] + b"\0" +
                                        names[1][:128] + b"\0")
                        else:
                            captured = b""
                        with self.server.lock:
                            if len(messages) < 1024:
                                messages.append((kind, captured))
                    backend.sendall(kind + size + payload)
            except (EOFError, OSError):
                pass
            finally:
                try:
                    self.request.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                try:
                    backend.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                thread.join(timeout=5)


class SQLSession:
    def __init__(self, database, env=None):
        self.process = subprocess.Popen(
            ["psql", "-XAt", "-v", "ON_ERROR_STOP=1", "-d", database],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, bufsize=0, env=env)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""

    def execute(self, statement):
        marker = uuid.uuid4().hex.encode()
        self.process.stdin.write(statement.encode() + b"\n\\echo " + marker + b"\n")
        lines = []
        deadline = time.monotonic() + 10
        while True:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                if line == marker:
                    return lines
                lines.append(line.decode())
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise TimeoutError("psql acknowledgement timed out")
            chunk = os.read(self.process.stdout.fileno(), 4096)
            if not chunk:
                raise RuntimeError("psql exited: " + "\n".join(lines))
            self.buffer += chunk

    def __enter__(self):
        return self

    def __exit__(self, *args):
        try:
            if self.process.poll() is None:
                try:
                    self.process.communicate(b"ROLLBACK;\n\\q\n", timeout=5)
                except (subprocess.TimeoutExpired, BrokenPipeError):
                    self.process.kill()
                    self.process.communicate(timeout=5)
        finally:
            self.selector.close()
            self.process.stdin.close()
            self.process.stdout.close()


class Integration(unittest.TestCase):
    @classmethod
    def sql(cls, statement, database="postgres", timeout=30):
        return subprocess.check_output(
            ["psql", "-XAt", "-v", "ON_ERROR_STOP=1", "-d", database,
             "-c", statement], text=True, timeout=timeout).strip()

    @staticmethod
    def literal(value):
        return "'" + value.replace("'", "''") + "'"

    @classmethod
    def db(cls, statement, timeout=30):
        return cls.sql(statement, cls.database, timeout)

    @classmethod
    def setUpClass(cls):
        cls.database = f"pony_integration_{os.getpid()}"
        cls.secret = "integration-secret"
        cls.sql(f"CREATE DATABASE {cls.database} TEMPLATE conduit_dev")
        cls.addClassCleanup(cls.sql, f"DROP DATABASE {cls.database} WITH (FORCE)")
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            cls.port = listener.getsockname()[1]
        env = os.environ.copy()
        dbhost = env.get("PGHOST", "127.0.0.1")
        if dbhost.startswith("/"):
            dbhost = "127.0.0.1"
        cls.proxy = ProtocolProxy(dbhost, env.get("PGPORT", "5432"))
        cls.addClassCleanup(cls.proxy.stop)
        env.update(
            DATABASE_URL=f"postgres://conduit:conduit@127.0.0.1:"
                         f"{cls.proxy.server_address[1]}/{cls.database}",
            JWT_SECRET=cls.secret, HOST="127.0.0.1", PORT=str(cls.port),
            DB_WORKERS="10")
        cls.server_env = env
        executable = Path(__file__).resolve().parents[1] / "bin" / "conduit"
        cls.server_log = tempfile.TemporaryFile(mode="w+b")
        cls.addClassCleanup(cls.server_log.close)
        cls.server = subprocess.Popen([str(executable)], env=env,
                                      stderr=cls.server_log)
        cls.addClassCleanup(cls.stop)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if cls.server.poll() is not None:
                raise RuntimeError("server exited during startup")
            try:
                if cls.request("GET", "/api/tags")[0] == 200:
                    return
            except OSError:
                pass
            time.sleep(0.05)
        raise RuntimeError("server did not become ready")

    @classmethod
    def stop(cls):
        cls.server.terminate()
        try:
            cls.server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            cls.server.kill()
            cls.server.wait(timeout=5)

    @classmethod
    def request(cls, method, path, body=None, token=None, timeout=5):
        connection = http.client.HTTPConnection("127.0.0.1", cls.port,
                                               timeout=timeout)
        try:
            headers = {"Content-Type": "application/json"}
            if token:
                headers["Authorization"] = "Token " + token
            connection.request(method, path,
                               None if body is None else json.dumps(body), headers)
            response = connection.getresponse()
            data = response.read()
            return response.status, json.loads(data) if data else None
        finally:
            connection.close()

    def probe_line(self, process, expected):
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            self.assertTrue(selector.select(10), "worker probe did not respond")
        self.assertEqual(process.stdout.readline().strip(), expected)

    @classmethod
    def token(cls, subject):
        def encode(data):
            return base64.urlsafe_b64encode(data).rstrip(b"=")
        header = encode(b'{"alg":"HS256"}')
        payload = encode(json.dumps({"sub": str(subject),
                                     "exp": int(time.time()) + 3600}).encode())
        data = header + b"." + payload
        signature = hmac.digest(cls.secret.encode(), data, hashlib.sha256)
        return (data + b"." + encode(signature)).decode()

    def test_feed_named_parameter_width(self):
        suffix = uuid.uuid4().hex
        follower = int(self.db(
            "INSERT INTO users(username,email,password_hash) VALUES "
            f"('feed_{suffix}','feed_{suffix}@example.com','unused') "
            "RETURNING id").splitlines()[0])
        author = self.author()
        self.db(f"INSERT INTO follows(follower_id,followee_id) "
                f"VALUES ({follower},{author})")
        status, article = self.request("POST", "/api/articles",
            self.article("feed_" + suffix, []), self.token(author))
        self.assertEqual(status, 201)
        self.assertEqual(article["article"]["title"], "feed_" + suffix)
        self.server_log.seek(0, os.SEEK_END)
        start = self.server_log.tell()
        status, body = self.request("GET",
            "/api/articles/feed?limit=1&offset=2147483648",
            token=self.token(follower))
        self.assertEqual(status, 500)
        self.assertIsInstance(body["errors"]["body"], list)
        deadline = time.monotonic() + 2
        diagnostics = b""
        while time.monotonic() < deadline:
            self.server_log.seek(start)
            diagnostics = self.server_log.read()
            if b"22003" in diagnostics:
                break
            time.sleep(0.01)
        self.assertIn(b"Database error 22003:", diagnostics)
        self.assertNotIn(b"22P03", diagnostics)

    def test_prepared_startup_and_runtime_wire(self):
        def workers():
            return [session for session in self.proxy.snapshot()[:10]
                    if any(kind == b"P" and
                           payload.split(b"\0", 1)[0] == b"tags"
                           for kind, payload in session)]

        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            sessions = workers()
            if len(sessions) == 10 and all(
                len([message for message in session if message[0] == b"P"])
                == 30 for session in sessions):
                break
            time.sleep(0.01)
        self.assertEqual(len(sessions), 10)
        initial = []
        for session in sessions:
            names = [payload.split(b"\0", 1)[0] for kind, payload
                     in session if kind == b"P"]
            self.assertEqual(len(names), 30)
            self.assertEqual(len(set(names)), 30)
            self.assertIn(b"rollback", names)
            initial.append(len(names))
        for _ in range(20):
            status, body = self.request("GET", "/api/tags")
            self.assertEqual(status, 200)
            self.assertIsInstance(body["tags"], list)
            self.assertTrue(all(isinstance(tag, str) for tag in body["tags"]))
        sessions = workers()
        for index, session in enumerate(sessions):
            self.assertEqual(sum(kind == b"P" for kind, _ in session),
                             initial[index])
        bound_names = [payload.split(b"\0", 2)[1] for session in sessions
                       for kind, payload in session if kind == b"B"]
        self.assertIn(b"tags", bound_names)

    def test_listener_assigns_workers_round_robin(self):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            sessions = self.proxy.snapshot()[:10]
            if len(sessions) == 10 and all(
                sum(kind == b"P" for kind, _ in session) == 30
                    for session in sessions):
                break
            time.sleep(0.01)
        self.assertEqual(len(sessions), 10)
        before = [sum(kind == b"B" for kind, _ in session)
                  for session in sessions]
        connections = []
        try:
            for _ in range(10):
                connection = http.client.HTTPConnection(
                    "127.0.0.1", self.port, timeout=5)
                connections.append(connection)
                connection.request("GET", "/api/tags")
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                response.read()
            sessions = self.proxy.snapshot()[:10]
            after = [sum(kind == b"B" for kind, _ in session)
                     for session in sessions]
            self.assertEqual([a - b for a, b in zip(after, before)],
                             [1] * 10)
        finally:
            for connection in connections:
                connection.close()

    def test_named_rollback_after_failed_transaction(self):
        before = len(self.proxy.snapshot())
        executable = Path(__file__).resolve().parents[1] / "bin" / "conduit"
        result = subprocess.run([str(executable), "--test-named-rollback"],
                                env=self.server_env, capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(),
                         "named rollback after failed transaction passed")
        sessions = self.proxy.snapshot()
        self.assertGreaterEqual(len(sessions), before + 1)
        probes = []
        for traffic in sessions[before:]:
            parsed = [payload.split(b"\0", 1)[0] for kind, payload
                      in traffic if kind == b"P"]
            bound = [payload.split(b"\0", 2)[1] for kind, payload
                     in traffic if kind == b"B"]
            if b"rollback" in parsed and b"rollback" in bound:
                probes.append(traffic)
        self.assertEqual(len(probes), 1)

    def test_presend_data_error_keeps_worker_query_order(self):
        before = len(self.proxy.snapshot())
        executable = Path(__file__).resolve().parents[1] / "bin" / "conduit"
        result = subprocess.run([str(executable), "--test-worker-data-error"],
                                env=self.server_env, capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(),
                         "worker data errors followed by query passed")
        sessions = self.proxy.snapshot()[before:]
        self.assertEqual(len(sessions), 1)
        bound = [payload.split(b"\0", 2)[1] for kind, payload
                 in sessions[0] if kind == b"B"]
        self.assertEqual(bound, [b"tags"])

    def test_decode_data_error_keeps_worker_query_order(self):
        self.assertGreater(int(self.db("SELECT count(*) FROM tags")), 0)
        before = len(self.proxy.snapshot())
        self.proxy.corrupt_next_data_row()
        executable = Path(__file__).resolve().parents[1] / "bin" / "conduit"
        result = subprocess.run([str(executable), "--test-worker-decode-error"],
                                env=self.server_env, capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(),
                         "worker decode error followed by query passed")
        sessions = self.proxy.snapshot()[before:]
        self.assertEqual(len(sessions), 1)
        bound = [payload.split(b"\0", 2)[1] for kind, payload
                 in sessions[0] if kind == b"B"]
        self.assertEqual(bound, [b"tags", b"tags"])

    def test_foreign_session_callback_does_not_retire_worker(self):
        before = len(self.proxy.snapshot())
        executable = Path(__file__).resolve().parents[1] / "bin" / "conduit"
        result = subprocess.run(
            [str(executable), "--test-worker-foreign-callback"],
            env=self.server_env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(),
                         "foreign session callback ignored")
        sessions = self.proxy.snapshot()[before:]
        prepared = [session for session in sessions if any(
            kind == b"P" and payload.split(b"\0", 1)[0] == b"tags"
            for kind, payload in session)]
        self.assertEqual(len(prepared), 1)
        bound = [payload.split(b"\0", 2)[1] for kind, payload
                 in prepared[0] if kind == b"B"]
        self.assertEqual(bound, [b"tags", b"tags"])

    def test_missing_query_completion_fails_request(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port,
                                                timeout=8)
        try:
            self.proxy.suppress_next_command_complete()
            connection.request("GET", "/api/tags")
            response = connection.getresponse()
            self.assertEqual(response.status, 500)
            self.assertEqual(json.loads(response.read())["errors"]["body"],
                             ["connection lost"])
            connection.request("GET", "/api/tags")
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertIn("tags", json.loads(response.read()))
        finally:
            connection.close()

    def test_shared_worker_cancellation_preserves_other_client(self):
        executable = Path(__file__).resolve().parents[1] / "bin" / "conduit"
        before = len(self.proxy.snapshot())
        self.proxy.hold_command_complete_after(1)
        process = subprocess.Popen(
            [str(executable), "--test-worker-overlap"],
            env=self.server_env, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1)
        try:
            self.probe_line(process, "overlap accepted")
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                sessions = self.proxy.snapshot()[before:]
                if sessions and any(kind == b"B" and
                        payload.split(b"\0", 2)[1] == b"tags"
                        for kind, payload in sessions[0]):
                    break
                time.sleep(0.01)
            else:
                self.fail("first client's query did not reach PostgreSQL")
            self.proxy.release_command_complete()
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(stdout.strip(), "surviving client passed")
            sessions = self.proxy.snapshot()[before:]
            self.assertEqual(len(sessions), 1)
            bound = [payload.split(b"\0", 2)[1] for kind, payload
                     in sessions[0] if kind == b"B"]
            self.assertEqual(bound,
                             [b"current_user", b"tags", b"profile"])
        finally:
            self.proxy.release_command_complete(abort=True)
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)

    def test_submitted_jobs_each_fail_on_database_loss(self):
        executable = Path(__file__).resolve().parents[1] / "bin" / "conduit"
        before = len(self.proxy.snapshot())
        self.proxy.hold_command_complete_after(1)
        process = subprocess.Popen(
            [str(executable), "--test-worker-submitted-loss"],
            env=self.server_env, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1)
        try:
            self.probe_line(process, "submitted work accepted")
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                sessions = self.proxy.snapshot()[before:]
                if sessions and any(kind == b"B" and
                        payload.split(b"\0", 2)[1] == b"tags"
                        for kind, payload in sessions[0]):
                    break
                time.sleep(0.01)
            else:
                self.fail("submitted query did not reach PostgreSQL")
            self.proxy.drop_backend(before)
            self.proxy.release_command_complete(abort=True)
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(stdout.strip(), "submitted work failed once")
            sessions = self.proxy.snapshot()[before:]
            self.assertEqual(len(sessions), 1)
            bound = [payload.split(b"\0", 2)[1] for kind, payload
                     in sessions[0] if kind == b"B"]
            self.assertEqual(bound, [b"current_user", b"tags"])
        finally:
            self.proxy.release_command_complete(abort=True)
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)

    def test_explicit_worker_close_fails_each_submitted_job(self):
        executable = Path(__file__).resolve().parents[1] / "bin" / "conduit"
        self.proxy.hold_command_complete_after(1)
        process = subprocess.Popen(
            [str(executable), "--test-worker-close-drain"],
            env=self.server_env, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1)
        try:
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(stdout.splitlines(),
                             ["submitted work accepted",
                              "submitted work failed once"])
        finally:
            self.proxy.release_command_complete()
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)

    def test_proxy_frame_deadline_preserves_idle_sessions(self):
        proxy = ProtocolProxy(self.proxy.database_host,
                              self.proxy.database_port, frame_timeout=0.5)
        try:
            env = os.environ.copy()
            env.update(PGHOST="127.0.0.1", PGPORT=str(proxy.server_address[1]),
                       PGUSER="conduit", PGPASSWORD="conduit",
                       PGSSLMODE="disable", PGGSSENCMODE="disable")
            with SQLSession(self.database, env) as session:
                self.assertEqual(session.execute("\\echo ready"), ["ready"])
                time.sleep(1)
                self.assertEqual(session.execute("SELECT 1;"), ["1"])

            startup = (struct.pack("!I", 196608) +
                       b"user\0conduit\0database\0" +
                       self.database.encode() + b"\0\0")
            with socket.create_connection(proxy.server_address) as sock:
                sock.settimeout(4)
                sock.sendall(struct.pack("!I", len(startup) + 4) +
                             startup)
                self.assertEqual(sock.recv(1), b"R")
                sock.sendall(b"P")
                while sock.recv(4096):
                    pass
        finally:
            proxy.stop()

    def test_worker_count_configuration(self):
        executable = Path(__file__).resolve().parents[1] / "bin" / "conduit"
        for count in ("", "invalid", "0", "96"):
            with self.subTest(count=count):
                env = self.server_env.copy()
                env["DB_WORKERS"] = count
                result = subprocess.run([str(executable)], env=env,
                                        capture_output=True, text=True,
                                        timeout=5)
                self.assertEqual(result.returncode, 1)
                self.assertIn("DB_WORKERS must be valid", result.stderr)

    def test_invalid_catalog_prevents_worker_dispatch(self):
        database = "pony_invalid_" + uuid.uuid4().hex
        self.sql(f"CREATE DATABASE {database} TEMPLATE conduit_dev")
        proxy = ProtocolProxy(self.proxy.database_host,
                              self.proxy.database_port)
        try:
            self.sql("ALTER TABLE tags RENAME TO tags_hidden", database)
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            env = os.environ.copy()
            env.update(
                DATABASE_URL=f"postgres://conduit:conduit@127.0.0.1:"
                             f"{proxy.server_address[1]}/{database}",
                JWT_SECRET=self.secret, HOST="127.0.0.1", PORT=str(port),
                DB_WORKERS="1")
            executable = Path(__file__).resolve().parents[1] / "bin" / "conduit"
            with tempfile.TemporaryFile(mode="w+b") as log:
                server = subprocess.Popen([str(executable)], env=env,
                                          stderr=log)
                try:
                    with ThreadPoolExecutor(max_workers=1) as executor:
                        def request():
                            deadline = time.monotonic() + 15
                            while time.monotonic() < deadline:
                                connection = http.client.HTTPConnection(
                                    "127.0.0.1", port, timeout=15)
                                try:
                                    connection.request("GET", "/api/tags")
                                    response = connection.getresponse()
                                    return response.status, json.loads(response.read())
                                except ConnectionRefusedError:
                                    time.sleep(0.01)
                                finally:
                                    connection.close()
                            raise TimeoutError("server did not listen")

                        future = executor.submit(request)
                        diagnostic = b""
                        deadline = time.monotonic() + 5
                        while time.monotonic() < deadline:
                            self.assertIsNone(server.poll())
                            log.seek(0)
                            diagnostic = log.read()
                            if b"Database prepare tags failed" in diagnostic:
                                break
                            time.sleep(0.01)
                        self.assertIn(b"Database prepare tags failed", diagnostic)
                        self.assertFalse(future.done())
                        self.sql("ALTER TABLE tags_hidden RENAME TO tags", database)
                        status, body = future.result(timeout=12)
                        self.assertEqual(status, 200)
                        self.assertIsInstance(body["tags"], list)
                        bound = [payload.split(b"\0", 2)[1]
                            for session in proxy.snapshot()
                            for kind, payload in session if kind == b"B"]
                        self.assertEqual(bound, [b"tags"])
                finally:
                    server.terminate()
                    try:
                        server.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait(timeout=5)
        finally:
            proxy.stop()
            self.sql(f"DROP DATABASE {database} WITH (FORCE)")

    def test_pending_cancellation_keeps_other_client(self):
        database = f"pony_pending_{os.getpid()}"
        self.sql(f"CREATE DATABASE {database} TEMPLATE conduit_dev")
        proxy = ProtocolProxy(self.proxy.database_host,
                              self.proxy.database_port)
        try:
            self.sql("ALTER TABLE tags RENAME TO tags_hidden", database)
            env = self.server_env.copy()
            env.update(DATABASE_URL=f"postgres://conduit:conduit@127.0.0.1:"
                       f"{proxy.server_address[1]}/{database}")
            executable = Path(__file__).resolve().parents[1] / "bin" / "conduit"
            process = subprocess.Popen(
                [str(executable), "--test-worker-pending-cancel"], env=env,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, bufsize=1)
            try:
                self.probe_line(process, "pending cancellation accepted")
                self.sql("ALTER TABLE tags_hidden RENAME TO tags", database)
                stdout, stderr = process.communicate(timeout=15)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertEqual(stdout.strip(),
                                 "surviving pending client passed")
                bound = [payload.split(b"\0", 2)[1]
                         for session in proxy.snapshot()
                         for kind, payload in session if kind == b"B"]
                self.assertEqual(bound, [b"tags"])
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)
        finally:
            proxy.stop()
            self.sql(f"DROP DATABASE {database} WITH (FORCE)")

    def test_worker_reconnect_preserves_http_session(self):
        proxy = ProtocolProxy(self.proxy.database_host,
                              self.proxy.database_port)
        try:
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            env = self.server_env.copy()
            env.update(DATABASE_URL=f"postgres://conduit:conduit@127.0.0.1:"
                       f"{proxy.server_address[1]}/{self.database}",
                       PORT=str(port), DB_WORKERS="1")
            executable = Path(__file__).resolve().parents[1] / "bin" / "conduit"
            with tempfile.TemporaryFile(mode="w+b") as log:
                server = subprocess.Popen([str(executable)], env=env,
                                          stderr=log)
                try:
                    deadline = time.monotonic() + 10
                    while True:
                        self.assertLess(time.monotonic(), deadline)
                        self.assertIsNone(server.poll())
                        try:
                            with socket.create_connection(("127.0.0.1", port)):
                                break
                        except ConnectionRefusedError:
                            time.sleep(0.01)
                    connection = http.client.HTTPConnection(
                        "127.0.0.1", port, timeout=10)
                    try:
                        connection.request("GET", "/api/tags")
                        response = connection.getresponse()
                        self.assertEqual(response.status, 200)
                        self.assertIn("tags", json.loads(response.read()))
                        self.assertEqual(len(proxy.snapshot()), 1)
                        proxy.drop_backend(0)
                        deadline = time.monotonic() + 5
                        while time.monotonic() < deadline:
                            log.seek(0)
                            if b"Postgres session shutdown" in log.read():
                                break
                            time.sleep(0.01)
                        else:
                            self.fail("worker did not observe lost database socket")
                        connection.request("GET", "/api/tags")
                        response = connection.getresponse()
                        self.assertEqual(response.status, 200)
                        self.assertIn("tags", json.loads(response.read()))
                        sessions = proxy.snapshot()
                        self.assertEqual(len(sessions), 2)
                        self.assertEqual(sum(kind == b"P" for kind, _
                                             in sessions[1]), 30)
                        self.assertIn(b"tags", [payload.split(b"\0", 2)[1]
                            for kind, payload in sessions[1] if kind == b"B"])
                        with SQLSession(self.database) as holder:
                            holder.execute("BEGIN; LOCK TABLE tags IN "
                                           "ACCESS EXCLUSIVE MODE;")
                            try:
                                with socket.create_connection(
                                        ("127.0.0.1", port), timeout=5) as sock:
                                    sock.settimeout(8)
                                    sock.sendall((
                                        b"GET /api/tags HTTP/1.1\r\n"
                                        b"Host: localhost\r\n\r\n"))
                                    deadline = time.monotonic() + 5
                                    while time.monotonic() < deadline:
                                        traffic = proxy.snapshot()[1]
                                        if sum(kind == b"B" for kind, _
                                               in traffic) >= 2:
                                            break
                                        time.sleep(0.01)
                                    else:
                                        self.fail("blocked query was not submitted")
                                    proxy.drop_backend(1)
                                    with sock.makefile("rb") as stream:
                                        self.assertEqual(
                                            stream.readline().split()[1], b"500")
                                        headers = {}
                                        while (line := stream.readline()) != b"\r\n":
                                            self.assertTrue(line)
                                            name, value = line.split(b":", 1)
                                            headers[name.lower()] = value.strip()
                                        body = json.loads(stream.read(
                                            int(headers[b"content-length"])))
                                        self.assertEqual(
                                            body["errors"]["body"],
                                            ["connection lost"])
                            finally:
                                holder.execute("ROLLBACK;")
                        deadline = time.monotonic() + 5
                        while time.monotonic() < deadline:
                            sessions = proxy.snapshot()
                            if len(sessions) == 3 and sum(kind == b"P" for
                                    kind, _ in sessions[2]) == 30:
                                break
                            time.sleep(0.01)
                        self.assertEqual(len(sessions), 3)
                        self.assertFalse(any(kind == b"B" for kind, _
                                             in sessions[2]))
                        connection.request("GET", "/api/tags")
                        response = connection.getresponse()
                        self.assertEqual(response.status, 200)
                        response.read()
                    finally:
                        connection.close()
                finally:
                    server.terminate()
                    try:
                        server.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait(timeout=5)
        finally:
            proxy.stop()

    def test_atomic_failure_reuses_all_workers(self):
        token = self.token(9223372036854775807)
        for _ in range(10):
            status, body = self.request("POST", "/api/articles", {
                "article": {"title": "rollback", "description": "d", "body": "b"}},
                token)
            self.assertEqual(status, 500)
            self.assertIsInstance(body["errors"]["body"], list)
        for _ in range(10):
            self.assertEqual(self.request("GET", "/api/tags")[0], 200)
        states = self.sql(
            "SELECT count(*), count(*) FILTER (WHERE state = 'idle') "
            "FROM pg_stat_activity "
            f"WHERE datname = '{self.database}' AND usename = 'conduit'")
        self.assertEqual(states, "10|10")

    def author(self):
        return int(self.db("SELECT id FROM users ORDER BY id LIMIT 1"))

    def article(self, title, tags):
        return {"article": {"title": title, "description": "atomic description",
                            "body": "atomic body", "tagList": tags}}

    def assert_article(self, response, title, tags):
        article = response["article"]
        self.assertEqual(article["title"], title)
        self.assertEqual(article["description"], "atomic description")
        self.assertEqual(article["body"], "atomic body")
        self.assertEqual(sorted(article["tagList"]), sorted(set(tags)))
        self.assertFalse(article["favorited"])
        self.assertEqual(article["favoritesCount"], 0)
        for field in ["slug", "createdAt", "updatedAt"]:
            self.assertIsInstance(article[field], str)
            self.assertTrue(article[field])
        username = self.db(f"SELECT username FROM users WHERE id={self.author()}")
        self.assertEqual(article["author"]["username"], username)
        slug = self.literal(article["slug"])
        stored = json.loads(self.db(
            "SELECT json_build_object('title',title,'description',description,"
            "'body',body,'tags',ARRAY(SELECT t.name FROM article_tags at "
            "JOIN tags t ON t.id=at.tag_id WHERE at.article_id=a.id)) "
            f"FROM articles a WHERE slug={slug}"))
        self.assertEqual(stored["title"], title)
        self.assertEqual(stored["description"], "atomic description")
        self.assertEqual(stored["body"], "atomic body")
        self.assertEqual(sorted(stored["tags"]), sorted(set(tags)))
        for tag in set(tags):
            self.assertEqual(self.db(
                f"SELECT count(*) FROM tags WHERE name={self.literal(tag)}"), "1")
        status, fetched = self.request("GET", "/api/articles/" + article["slug"])
        self.assertEqual(status, 200)
        self.assertEqual(fetched["article"], article)

    def test_article_tag_variants(self):
        prefix = "atomic_" + uuid.uuid4().hex
        existing = prefix + "_existing"
        self.db(f"INSERT INTO tags(name) VALUES ({self.literal(existing)})")
        existing_id = self.db(
            f"SELECT id FROM tags WHERE name={self.literal(existing)}")
        special = prefix + "_quote'\"\\雪"
        cases = [None, [], [prefix + "_z", prefix + "_a"], [existing],
                 [existing, special], [existing, special, existing, special]]
        for index, tags in enumerate(cases):
            with self.subTest(tags=tags):
                title = prefix + str(index)
                body = self.article(title, tags)
                if tags is None:
                    del body["article"]["tagList"]
                status, response = self.request(
                    "POST", "/api/articles", body, self.token(self.author()))
                self.assertEqual(status, 201)
                self.assert_article(response, title, tags or [])
        self.assertEqual(self.db(
            f"SELECT id FROM tags WHERE name={self.literal(existing)}"), existing_id)

    def test_sql_json_list_and_tags(self):
        suffix = uuid.uuid4().hex
        title = "json_雪_\\\"_" + suffix
        tag = "json_tag_" + suffix
        status, created = self.request("POST", "/api/articles",
            self.article(title, [tag]), self.token(self.author()))
        self.assertEqual(status, 201)
        article = created["article"]
        status, tags = self.request("GET", "/api/tags")
        self.assertEqual(status, 200)
        self.assertIn(tag, tags["tags"])
        self.assertEqual(tags["tags"], sorted(tags["tags"]))
        status, listed = self.request("GET", "/api/articles?tag=" + tag)
        self.assertEqual(status, 200)
        self.assertEqual(listed["articlesCount"], 1)
        self.assertEqual(len(listed["articles"]), 1)
        self.assertEqual(listed["articles"][0],
                         {key: value for key, value in article.items()
                          if key != "body"})
        status, empty = self.request(
            "GET", "/api/articles?tag=" + tag + "_none")
        self.assertEqual(status, 200)
        self.assertEqual(empty, {"articles": [], "articlesCount": 0})

    def test_sql_json_input_validation(self):
        token = self.token(self.author())
        suffix = uuid.uuid4().hex
        body = self.article("sql_input_" + suffix, [])
        body["article"]["tagList"] = None
        status, created = self.request("POST", "/api/articles", body, token)
        self.assertEqual(status, 201)
        self.assertEqual(created["article"]["tagList"], [])
        slug = created["article"]["slug"]
        before = self.db("SELECT (SELECT count(*) FROM articles), "
                         "(SELECT count(*) FROM tags), "
                         "(SELECT count(*) FROM article_tags)")
        bad_tag = "rejected_" + suffix
        for invalid in [
            {"article": {"title": True, "description": "d", "body": "b"}},
            {"article": {"title": "t", "description": "d", "body": "b",
                         "tagList": [bad_tag, 2]}},
            {"article": {"title": "t", "description": "d", "body": "b",
                         "tagList": {}}},
        ]:
            with self.subTest(invalid=invalid):
                self.assertEqual(self.request("POST", "/api/articles",
                    invalid, token)[0], 422)
                self.assertEqual(self.db("SELECT (SELECT count(*) FROM articles), "
                                         "(SELECT count(*) FROM tags), "
                                         "(SELECT count(*) FROM article_tags)"),
                                 before)
        status, updated = self.request("PUT", "/api/articles/" + slug,
            {"article": {"tagList": False, "description": "new"}}, token)
        self.assertEqual(status, 200)
        self.assertEqual(updated["article"]["description"], "new")
        self.assertEqual(self.request("POST", "/api/articles/missing-" + suffix
            + "/comments", {"comment": {"body": False}}, token)[0], 422)
        connection = http.client.HTTPConnection(
            "127.0.0.1", self.port, timeout=5)
        try:
            connection.request("POST", "/api/articles",
                               "{bad", {"Authorization": "Token " + token,
                                        "Content-Type": "application/json"})
            response = connection.getresponse()
            self.assertEqual(response.status, 422)
            response.read()
        finally:
            connection.close()

    def test_article_failure_is_atomic(self):
        title = "atomic_failure_" + uuid.uuid4().hex
        tag = title + "_tag"
        counts = "SELECT (SELECT count(*) FROM articles), " \
                 "(SELECT count(*) FROM tags), (SELECT count(*) FROM article_tags)"
        before = self.db(counts)
        status, response = self.request("POST", "/api/articles",
            self.article(title, [tag]), self.token(9223372036854775807))
        self.assertEqual(status, 500)
        self.assertIsInstance(response["errors"]["body"], list)
        self.assertEqual(self.db(
            f"SELECT count(*) FROM articles WHERE title={self.literal(title)}"), "0")
        self.assertEqual(self.db(
            f"SELECT count(*) FROM tags WHERE name={self.literal(tag)}"), "0")
        self.assertEqual(self.db(counts), before)
        self.db("""
            CREATE FUNCTION pony_atomic_fail_link() RETURNS trigger
            LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'link failure'; END $$;
            CREATE TRIGGER pony_atomic_fail_link BEFORE INSERT ON article_tags
            FOR EACH ROW EXECUTE FUNCTION pony_atomic_fail_link()
            """)
        try:
            status, response = self.request("POST", "/api/articles",
                self.article(title, [tag]), self.token(self.author()))
            self.assertEqual(status, 500)
            self.assertIsInstance(response["errors"]["body"], list)
            self.assertEqual(self.db(
                f"SELECT count(*) FROM articles WHERE title={self.literal(title)}"), "0")
            self.assertEqual(self.db(
                f"SELECT count(*) FROM tags WHERE name={self.literal(tag)}"), "0")
            self.assertEqual(self.db(counts), before)
        finally:
            self.db("""
                DROP TRIGGER pony_atomic_fail_link ON article_tags;
                DROP FUNCTION pony_atomic_fail_link()
                """)
        status, response = self.request("POST", "/api/articles",
            self.article(title, [tag]), self.token(self.author()))
        self.assertEqual(status, 201)
        self.assert_article(response, title, [tag])

    def test_concurrent_shared_tag(self):
        title = "atomic_conflict_" + uuid.uuid4().hex
        shared, fresh = title + "_shared", title + "_fresh"
        with SQLSession(self.database) as holder:
            lines = holder.execute(
                "BEGIN; SET LOCAL statement_timeout='15s'; "
                "SET LOCAL idle_in_transaction_session_timeout='20s'; "
                f"INSERT INTO tags(name) VALUES ({self.literal(shared)}); "
                "SELECT pg_backend_pid();")
            pid = int(lines[-1])
            with ThreadPoolExecutor(max_workers=1) as executor:
                future = executor.submit(self.request, "POST", "/api/articles",
                    self.article(title, [shared, fresh, shared]),
                    self.token(self.author()), 30)
                committed = False
                try:
                    deadline = time.monotonic() + 10
                    blocked = False
                    while time.monotonic() < deadline:
                        blocked = self.db(
                            "SELECT EXISTS(SELECT 1 FROM pg_stat_activity "
                            "WHERE datname=current_database() AND usename='conduit' "
                            f"AND {pid}=ANY(pg_blocking_pids(pid)))", timeout=2) == "t"
                        if blocked or future.done():
                            break
                        time.sleep(0.02)
                    self.assertTrue(blocked, "HTTP database query never blocked on holder")
                    self.assertFalse(future.done())
                    holder.execute("COMMIT;")
                    committed = True
                finally:
                    if not committed:
                        holder.execute("ROLLBACK;")
                status, response = future.result(timeout=30)
        self.assertEqual(status, 201)
        self.assert_article(response, title, [shared, fresh])

    def test_submitted_write_survives_http_close(self):
        title = "closed_write_" + uuid.uuid4().hex
        body = json.dumps(self.article(title, [title + "_tag"])).encode()
        token = self.token(self.author()).encode()
        with SQLSession(self.database) as holder:
            holder.execute("BEGIN; LOCK TABLE tags IN ACCESS EXCLUSIVE MODE;")
            released = False
            try:
                with socket.create_connection(("127.0.0.1", self.port)) as sock:
                    sock.sendall(b"POST /api/articles HTTP/1.1\r\n"
                                 b"Host: localhost\r\n"
                                 b"Content-Type: application/json\r\n"
                                 b"Authorization: Token " + token + b"\r\n"
                                 b"Content-Length: " + str(len(body)).encode()
                                 + b"\r\n\r\n" + body)
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        blocked = self.db(
                            "SELECT EXISTS(SELECT 1 FROM pg_stat_activity "
                            f"WHERE datname='{self.database}' "
                            "AND usename='conduit' AND wait_event_type='Lock')")
                        if blocked == "t":
                            break
                        time.sleep(0.01)
                    self.assertEqual(blocked, "t")
                holder.execute("COMMIT;")
                released = True
            finally:
                if not released:
                    holder.execute("ROLLBACK;")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            count = self.db("SELECT count(*) FROM articles WHERE title="
                            + self.literal(title))
            if count == "1":
                break
            time.sleep(0.01)
        self.assertEqual(count, "1")

    def test_password_nul_bytes(self):
        user = {"username": "nul_user", "email": "nul@example.com",
                "password": "a\0b"}
        self.assertEqual(self.request("POST", "/api/users", {"user": user})[0], 201)
        for password, expected in [("a\0b", 200), ("a\0c", 401), ("a", 401)]:
            status, _ = self.request("POST", "/api/users/login", {
                "user": {"email": user["email"], "password": password}})
            self.assertEqual(status, expected)

    def test_invalid_unrelated_query_keeps_limit_validation(self):
        status, _ = self.request("GET", "/api/articles?limit=0&junk=%ZZ")
        self.assertEqual(status, 422)

    def test_pipelined_response_order(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as sock:
            sock.sendall(
                b"GET /api/tags HTTP/1.1\r\nHost: localhost\r\n\r\n"
                b"GET /api/articles?limit=1 HTTP/1.1\r\nHost: localhost\r\n\r\n")
            with sock.makefile("rb") as stream:
                for expected in ["tags", "articles"]:
                    self.assertEqual(stream.readline().split()[1], b"200")
                    headers = {}
                    while (line := stream.readline()) != b"\r\n":
                        self.assertTrue(line)
                        name, value = line.split(b":", 1)
                        headers[name.lower()] = value.strip()
                    body = json.loads(stream.read(int(headers[b"content-length"])))
                    self.assertIn(expected, body)


if __name__ == "__main__":
    unittest.main()
