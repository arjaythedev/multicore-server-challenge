import base64
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager, ExitStack
import hashlib
import hmac
import http.client
import io
import json
import os
from pathlib import Path
import re
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


def _executable():
    variant = os.environ.get("CONDUIT_VARIANT", "ordinary")
    if variant not in ("ordinary", "diagnostic"):
        raise ValueError("CONDUIT_VARIANT must be ordinary or diagnostic")
    name = "conduit-diagnostic" if variant == "diagnostic" else "conduit"
    return Path(__file__).resolve().parents[1] / "bin" / name


def _diagnostic_mode():
    return os.environ.get("CONDUIT_VARIANT", "ordinary") == "diagnostic"


def _failure_output(value):
    return "diagnostic subprocess failed" if _diagnostic_mode() else value


CSV_FIELDS = ("monotonic_ns", "worker_id", "connecting", "preparing", "idle",
              "busy", "backoff", "stopped", "pending")
CSV_HEADER = ",".join(CSV_FIELDS)


class WorkerCSV:
    def __init__(self, counts=None):
        self.counts = counts
        self.header = False
        self.rows = []

    def consume(self, line):
        if isinstance(line, bytes):
            line = line.decode("utf-8")
        line = line.rstrip("\r\n")
        if line.startswith("{"):
            return False
        if line == CSV_HEADER:
            if self.header:
                raise AssertionError("duplicate CSV header")
            self.header = True
            return True
        if not self.header:
            raise AssertionError("missing CSV header")
        values = line.split(",")
        if len(values) != len(CSV_FIELDS) or any(
                re.fullmatch(r"[0-9]+", value) is None for value in values):
            raise AssertionError("invalid CSV row")
        row = dict(zip(CSV_FIELDS, map(int, values)))
        if any(value > (1 << 64) - 1 for value in row.values()):
            raise AssertionError("invalid CSV value")
        if self.counts is not None:
            self.validate(row, self.counts)
        self.rows.append(row)
        return True

    @staticmethod
    def validate(row, counts):
        worker = row["worker_id"]
        if worker not in counts:
            raise AssertionError("invalid CSV worker identity")
        if sum(row[name] for name in CSV_FIELDS[2:8]) != counts[worker]:
            raise AssertionError("invalid CSV state total")


def _split_output(stream, counts=None, allow_json=True):
    stream.seek(0)
    csv = WorkerCSV(counts)
    lines = []
    for line in stream:
        if not csv.consume(line):
            if not allow_json:
                raise AssertionError("unexpected JSON in CSV output")
            lines.append(line)
    return csv, lines


def _metric_records(stream):
    return [json.loads(line) for line in _split_output(stream)[1]]


def _check_metric_output(stream, require_activity=False):
    if stream is None:
        return
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate diagnostic key")
            result[key] = value
        return result

    def unsigned(value):
        return type(value) is int and 0 <= value <= (1 << 64) - 1

    csv, lines = _split_output(stream)
    records = 0
    startups = {}
    heartbeats = set()
    identities = set()
    pool_snapshots = {}
    connection_snapshots = []
    for line in lines:
        try:
            record = json.loads(line, object_pairs_hook=unique)
        except (ValueError, UnicodeDecodeError):
            raise AssertionError("invalid diagnostic record") from None
        if record.get("kind") != "conduit_diag" or record.get("schema") != 3:
            raise AssertionError("unexpected diagnostic record")
        worker_id = record.get("worker_id")
        if type(worker_id) is not int or worker_id not in range(95):
            raise AssertionError("invalid diagnostic worker identity")
        owner = record.get("owner")
        if "connection_count" in record:
            if owner != 0 or set(record) != {
                    "kind", "schema", "owner", "worker_id", "connection_count",
                    "total_connection_count", "database_actor_count",
                    "period_ns"}:
                raise AssertionError("invalid diagnostic startup record")
            if not unsigned(record["connection_count"]) or not unsigned(
                    record["period_ns"]):
                raise AssertionError("invalid diagnostic startup value")
            connection_count = record["connection_count"]
            actor_count = record["database_actor_count"]
            if (type(actor_count) is not int or
                    actor_count not in range(1, 96) or
                    not 1 <= connection_count <= 95 or
                    worker_id >= actor_count or
                    not unsigned(record["total_connection_count"]) or
                    not actor_count <= record["total_connection_count"] <= 95):
                raise AssertionError(
                    "invalid pool configuration or worker identity")
            if worker_id in startups:
                raise AssertionError("duplicate diagnostic startup")
            if startups and any(record[key] != previous[key]
                    for previous in startups.values() for key in
                    ("database_actor_count", "total_connection_count",
                     "period_ns")):
                raise AssertionError("conflicting diagnostic startup")
            startups[worker_id] = record
        elif owner == 0:
            if worker_id not in startups:
                raise AssertionError("diagnostic record precedes worker startup")
            if set(record) != {"kind", "schema", "owner", "worker_id", "report_ns",
                               "next_request"} or not all(unsigned(record[k])
                               for k in ("report_ns", "next_request")):
                raise AssertionError("invalid diagnostic heartbeat")
            heartbeats.add(worker_id)
        elif owner in (1, 2):
            if worker_id not in startups:
                raise AssertionError("diagnostic record precedes worker startup")
            connection_count = startups[worker_id]["connection_count"]
            if not unsigned(record.get("slot")) or record["slot"] >= connection_count:
                raise AssertionError("invalid diagnostic slot")
            shared = {"kind", "schema", "owner", "worker_id", "slot", "generation",
                      "request", "report_ns"}
            if record.get("missing") is True:
                if set(record) != shared | {"missing", "reason"} or record[
                        "reason"] not in ("overdue", "unavailable"):
                    raise AssertionError("invalid missing record")
            else:
                required = shared | {"observed_ns", "overflow",
                                     "invalid_clock", "counters", "gauges",
                                     "histograms"}
                if set(record) != required or type(record["overflow"]) is not bool:
                    raise AssertionError("invalid snapshot shape")
                counts = 10 if owner == 1 else 4
                gauges = 10 if owner == 1 else 4
                hists = 33 if owner == 1 else 8
                for key, size in (("counters", counts), ("gauges", gauges),
                                  ("histograms", hists)):
                    if type(record[key]) is not list or len(record[key]) != size:
                        raise AssertionError("invalid diagnostic array")
                if not all(unsigned(x) for x in record["counters"] +
                           record["gauges"]):
                    raise AssertionError("invalid diagnostic value")
                for hist in record["histograms"]:
                    if type(hist) is not dict or set(hist) != {
                            "count", "sum_ns", "max_ns", "overflow",
                            "buckets"}:
                        raise AssertionError("invalid histogram shape")
                    if type(hist["overflow"]) is not bool or type(
                            hist["buckets"]) is not list or len(
                            hist["buckets"]) != 27:
                        raise AssertionError("invalid histogram value")
                    if not all(unsigned(hist[k]) for k in (
                            "count", "sum_ns", "max_ns")) or not all(
                            unsigned(x) for x in hist["buckets"]):
                        raise AssertionError("invalid histogram integer")
                    if not hist["overflow"] and sum(hist["buckets"]) != hist[
                            "count"]:
                        raise AssertionError("invalid histogram count")
                if not unsigned(record["observed_ns"]) or not unsigned(
                        record["invalid_clock"]) or record["observed_ns"] > record[
                        "report_ns"]:
                    raise AssertionError("invalid observation time")
                if owner == 1:
                    c, g = record["counters"], record["gauges"]
                    if c[0] != g[0] + g[1] + c[2]:
                        raise AssertionError("accepted work is not conserved")
                    if c[1] + c[3] != c[2] + g[1] or c[7] + c[8] != c[2]:
                        raise AssertionError("terminal work is not conserved")
                    if (sum(g[4:10]) != connection_count
                            or not g[7] <= g[1] <= 32 * g[7]):
                        raise AssertionError("physical slot states are inconsistent")
                    identity = (worker_id, record["slot"], record["request"])
                    if identity in pool_snapshots:
                        raise AssertionError("duplicate Worker snapshot")
                    pool_snapshots[identity] = record
                else:
                    connection_snapshots.append(record)
            generation = record["generation"]
            unknown_generation = (owner == 1 and record.get("missing") is True
                                  and generation is None)
            if (not all(unsigned(record[k]) for k in (
                    "slot", "request", "report_ns")) or
                    not (unsigned(generation) or unknown_generation)):
                raise AssertionError("invalid record identity")
            identity = (owner, worker_id, record["slot"], generation,
                        record["request"])
            if not record.get("missing") and identity in identities:
                raise AssertionError("duplicate diagnostic record")
            if not record.get("missing"):
                identities.add(identity)
        else:
            raise AssertionError("invalid diagnostic owner")
        records += 1
    if not startups:
        raise AssertionError("missing diagnostic startup record")
    expected_workers = set(range(next(iter(startups.values()))[
        "database_actor_count"]))
    if set(startups) != expected_workers:
        raise AssertionError("missing worker startup record")
    if sum(record["connection_count"] for record in startups.values()) != next(
            iter(startups.values()))["total_connection_count"]:
        raise AssertionError("invalid pool configuration total")
    for row in csv.rows:
        WorkerCSV.validate(row, {worker: startup["connection_count"]
                                for worker, startup in startups.items()})
    if require_activity:
        if (heartbeats != expected_workers or not pool_snapshots or
                not connection_snapshots):
            raise AssertionError("missing periodic diagnostics")
        if {(worker, slot) for worker, slot, _ in pool_snapshots} != {
                (worker, slot) for worker in expected_workers
                for slot in range(startups[worker]["connection_count"])}:
            raise AssertionError("missing selected connection slot")
        if {record["worker_id"] for record in pool_snapshots.values()
                if record["counters"][0] > 0} != expected_workers:
            raise AssertionError("missing pool traffic")
        if {record["worker_id"] for record in connection_snapshots
                if record["counters"][0] > 0 and
                record["histograms"][6]["count"] > 0} != expected_workers:
            raise AssertionError("missing transport traffic")
        for record in connection_snapshots:
            if record["request"] == 0:
                continue
            worker = pool_snapshots.get((record["worker_id"], record["slot"],
                                         record["request"]))
            if worker is None or worker["observed_ns"] != record["observed_ns"]:
                raise AssertionError("unmatched connection snapshot")


class FrameGate:
    def __init__(self, kind, connection, skipped=0, timeout=20):
        self.kind = kind
        self.connection = connection
        self.skipped = skipped
        self.reached = threading.Event()
        self.release = threading.Event()
        self.abort = False
        self.claimed = False
        self.timeout = timeout


class ProtocolProxy(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 128

    def __init__(self, database_host, database_port, frame_timeout=15, capacity=128):
        self.database_host = database_host
        self.database_port = int(database_port)
        self.frame_timeout = frame_timeout
        self.messages = []
        self.frame_gates = []
        self.failures = []
        self.capacity = capacity
        self.backends = []
        self.frontends = []
        self.mutate_next_row = False
        self.scalar_replacement = None
        self.scalar_receipts = []
        self.drop_next_command_complete = False
        self.command_complete_gate = None
        self.command_complete_held = threading.Event()
        self.held_frontend = None
        self.command_complete_skip = 0
        self.command_complete_abort = False
        self.lock = threading.Lock()
        self.reject_new = False
        self.connections = threading.BoundedSemaphore(capacity)
        super().__init__(("127.0.0.1", 0), ProtocolConnection)
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    def hold_frame(self, kind, connection, skipped=0, timeout=20):
        gate = FrameGate(kind, connection, skipped, timeout)
        with self.lock:
            self.frame_gates.append(gate)
        return gate

    def frame_gate(self, kind, connection):
        with self.lock:
            for gate in self.frame_gates:
                if gate.claimed or gate.kind != kind or gate.connection != connection:
                    continue
                if gate.skipped:
                    gate.skipped -= 1
                    continue
                gate.claimed = True
                gate.reached.set()
                return gate
        return None

    def assert_healthy(self):
        with self.lock:
            if self.failures:
                raise AssertionError("; ".join(self.failures))

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

    def replace_scalar_field(self, connection, row, column, oid, value):
        with self.lock:
            if self.scalar_replacement is not None:
                raise ValueError("scalar replacement already armed")
            self.scalar_replacement = dict(
                connection=connection, row=row, column=column, oid=oid,
                value=value, seen=0, oids=None, preceding=[])

    def replace_scalar_payload(self, kind, connection, payload):
        with self.lock:
            change = self.scalar_replacement
            if change is None or change["connection"] != connection:
                return payload
            if kind == b"T":
                count = int.from_bytes(payload[:2], "big")
                cursor = 2
                oids = []
                for _ in range(count):
                    cursor = payload.index(b"\0", cursor) + 1
                    if cursor + 18 > len(payload):
                        raise ValueError("short row description")
                    oids.append(int.from_bytes(payload[cursor + 6:cursor + 10],
                                               "big"))
                    cursor += 18
                if cursor != len(payload):
                    raise ValueError("trailing row description bytes")
                change["oids"] = oids
                return payload
            if kind != b"D":
                return payload
            ordinal = change["seen"]
            change["seen"] += 1
            count = int.from_bytes(payload[:2], "big")
            fields = []
            cursor = 2
            for _ in range(count):
                if cursor + 4 > len(payload):
                    raise ValueError("short field length")
                length = int.from_bytes(payload[cursor:cursor + 4], "big",
                                        signed=True)
                cursor += 4
                if length == -1:
                    fields.append(None)
                elif length < 0 or cursor + length > len(payload):
                    raise ValueError("invalid field length")
                else:
                    fields.append(payload[cursor:cursor + length])
                    cursor += length
            if cursor != len(payload):
                raise ValueError("trailing data row bytes")
            if ordinal != change["row"]:
                change["preceding"].append(tuple(fields))
                return payload
            column = change["column"]
            oids = change["oids"]
            if (oids is None or len(oids) != count or column >= count or
                    oids[column] != change["oid"]):
                raise ValueError("scalar replacement target mismatch")
            replaced = list(fields)
            replaced[column] = change["value"]
            parts = [count.to_bytes(2, "big")]
            for value in replaced:
                if value is None:
                    parts.append((-1).to_bytes(4, "big", signed=True))
                else:
                    parts.append(len(value).to_bytes(4, "big", signed=True))
                    parts.append(value)
            changed = b"".join(parts)
            self.scalar_receipts.append(dict(
                connection=connection, row=ordinal, column=column,
                oid=oids[column], before=tuple(fields), after=tuple(replaced),
                preceding=tuple(change["preceding"]),
                old_length=len(payload) + 4, new_length=len(changed) + 4))
            self.scalar_replacement = None
            return changed

    def scalar_mutations(self):
        with self.lock:
            return list(self.scalar_receipts)

    def send_notice(self, frontend=None):
        payload = b"SNOTICE\0Midle notice\0\0"
        frame = b"N" + (len(payload) + 4).to_bytes(4, "big") + payload
        with self.lock:
            frontends = [frontend] if frontend is not None else list(self.frontends)
        sent = 0
        for frontend in frontends:
            try:
                frontend.sendall(frame)
                sent += 1
            except OSError:
                pass
        return sent

    def suppress_next_command_complete(self):
        with self.lock:
            self.drop_next_command_complete = True

    def hold_command_complete_after(self, skipped):
        with self.lock:
            self.command_complete_gate = threading.Event()
            self.command_complete_held.clear()
            self.held_frontend = None
            self.command_complete_skip = skipped
            self.command_complete_abort = False

    def release_command_complete(self, abort=False):
        with self.lock:
            self.command_complete_abort = abort
            gate = self.command_complete_gate
        if gate is not None:
            gate.set()

    def verify_request(self, request, client_address):
        return not self.reject_new and self.connections.acquire(blocking=False)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.connections.release()

    def stop(self):
        self.release_command_complete(abort=True)
        for gate in self.frame_gates:
            gate.abort = True
            gate.release.set()
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
                index = len(self.server.messages)
                if index < self.server.capacity:
                    self.server.messages.append(messages)
                    self.server.backends.append(backend)
                    self.server.frontends.append(self.request)

            def downstream():
                try:
                    while True:
                        kind = self.read_exact(backend, 1)
                        size = self.read_exact(backend, 4)
                        length = int.from_bytes(size, "big")
                        if not 4 <= length <= 1048576:
                            break
                        payload = self.read_exact(backend, length - 4)
                        try:
                            payload = self.server.replace_scalar_payload(
                                kind, index, payload)
                        except (ValueError, IndexError) as error:
                            with self.server.lock:
                                self.server.failures.append(str(error))
                            raise EOFError from error
                        length = len(payload) + 4
                        size = length.to_bytes(4, "big")
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
                        frame_gate = self.server.frame_gate(kind, index)
                        if frame_gate is not None:
                            if not frame_gate.release.wait(frame_gate.timeout):
                                with self.server.lock:
                                    self.server.failures.append("frame gate expired")
                                raise EOFError
                            if frame_gate.abort:
                                raise EOFError
                        if suppress:
                            continue
                        if gate is not None:
                            with self.server.lock:
                                self.server.held_frontend = self.request
                                self.server.command_complete_held.set()
                            if not gate.wait(20):
                                with self.server.lock:
                                    self.server.failures.append("command gate expired")
                                raise EOFError
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


class PoolRun:
    def __init__(self, case, process, proxy, csv=False, count=2, actors=1):
        self.case = case
        self.process = process
        self.proxy = proxy
        self.buffer = b""
        self.events = []
        self.history = []
        self.sequence = 0
        self.deadline = None
        self.csv = WorkerCSV(dict.fromkeys(range(actors), count)) if csv else None
        self.selector = selectors.DefaultSelector()
        self.selector.register(process.stdout, selectors.EVENT_READ)
        self.receive(lambda event: event.get("event") == "started")

    def send(self, *commands):
        self.process.stdin.write(("\n".join(commands) + "\n").encode())
        self.process.stdin.flush()

    def receive(self, predicate, timeout=10):
        deadline = time.monotonic() + self.time_left(timeout)
        while True:
            for index, event in enumerate(self.events):
                if predicate(event):
                    return self.events.pop(index)
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                if self.csv is not None and self.csv.consume(line):
                    if line.decode() == CSV_HEADER:
                        continue
                    event = {"event": "csv", "row": self.csv.rows[-1]}
                else:
                    event = json.loads(line)
                self.events.append(event)
                self.history.append(event)
            if any(predicate(event) for event in self.events):
                continue
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                self.proxy.assert_healthy()
                raise AssertionError(("pool probe response timed out",
                                      self.history[-5:]))
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise AssertionError("pool probe exited before response")
            self.buffer += chunk

    def time_left(self, maximum=10):
        if self.deadline is None:
            return maximum
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            self.proxy.assert_healthy()
            raise AssertionError("held pool phase deadline expired")
        return min(maximum, remaining)

    def reached(self, gate):
        reached = gate.reached.wait(self.time_left())
        if not reached:
            self.proxy.assert_healthy()
        self.case.assertTrue(reached, (gate.kind, gate.connection,
                             gate.release.is_set(), self.history[-5:]))

    def state(self, timeout=10):
        self.sequence += 1
        request = self.sequence
        self.send(f"state {request}")
        state = self.receive(lambda event: event.get("event") == "state"
                             and event["request"] == request, timeout)
        idle = state["idle"]
        self.case.assertEqual(len(idle), len(set(idle)))
        self.case.assertEqual(set(idle), {index for index, code in
                              enumerate(state["phases"]) if code == 2})
        self.case.assertEqual(state["outstanding"],
                              len(state["queued"]) + len(state["active"]))
        return state

    def csv_sample(self):
        self.sequence += 1
        self.send(f"csv-sample {self.sequence}")
        event = self.receive(lambda event: event.get("event") == "csv_sample"
                             and event["request"] == self.sequence)
        parser = WorkerCSV(self.csv.counts)
        parser.consume(CSV_HEADER)
        parser.consume(event["row"])
        return parser.rows[0]

    def csv_fence(self):
        self.sequence += 1
        self.send(f"csv-tick-fence {self.sequence}")
        return self.receive(lambda event: event.get("event") == "csv_fence"
                            and event["request"] == self.sequence)

    def wait_state(self, predicate, timeout=10):
        deadline = time.monotonic() + self.time_left(timeout)
        state = None
        while time.monotonic() < deadline:
            state = self.state(timeout=min(10, deadline - time.monotonic()))
            if predicate(state):
                return state
            time.sleep(0.01)
        self.proxy.assert_healthy()
        gates = [(g.kind, g.connection, g.reached.is_set(), g.release.is_set())
                 for g in self.proxy.frame_gates]
        raise AssertionError(("pool state condition timed out", state, gates))

    def ready(self, count):
        return self.wait_state(lambda state: state["phases"] == [2] * count)

    def result(self, id, kind="ok", client=None, timeout=10):
        result = self.receive(lambda event: event.get("event") == "result"
                              and event["id"] == id
                              and (client is None or event["client"] == client),
                              timeout)
        self.case.assertEqual(result["kind"], kind)
        return result

    def fence(self, timeout=10):
        deadline = time.monotonic() + timeout
        self.sequence += 1
        request = self.sequence
        self.send(f"fence {request}")
        values = {}
        for _ in range(4):
            event = self.receive(lambda event: event.get("event") == "fence"
                                 and event["request"] == request,
                                 max(0, deadline - time.monotonic()))
            self.case.assertNotIn(event["client"], values)
            values[event["client"]] = event["callbacks"]
        return values

    def diagnostic(self):
        self.sequence += 1
        self.send(f"diag {self.sequence}")
        return self.receive(lambda e: e.get("event") == "diag"
                            and e["request"] == self.sequence)


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
        cls.sql(f"ALTER DATABASE {cls.database} SET DateStyle TO 'SQL, DMY'")
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
            CONDUIT_TEST_POOL_SIZE="5")
        cls.server_env = env
        executable = _executable()
        cls.server_log = tempfile.TemporaryFile(mode="w+b")
        cls.addClassCleanup(cls.server_log.close)
        cls.server_metrics = tempfile.TemporaryFile(mode="w+b")
        if cls.server_metrics is not None:
            cls.addClassCleanup(cls.server_metrics.close)
        cls.server = subprocess.Popen(
            [str(executable), "--test-http", "--db-worker-count=4"], env=env,
                                      stdout=cls.server_metrics,
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
        if _diagnostic_mode():
            _check_metric_output(cls.server_metrics)
        else:
            _split_output(cls.server_metrics, dict.fromkeys(range(4), 5),
                          allow_json=False)

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

    def test_diagnostic_reporting(self):
        if not _diagnostic_mode():
            self.skipTest("diagnostic variant only")
        for _ in range(4):
            self.assertEqual(self.request("GET", "/api/tags")[0], 200)

        def paired_snapshots():
            size = os.fstat(self.server_metrics.fileno()).st_size
            data = os.pread(self.server_metrics.fileno(), size, 0)
            end = data.rfind(b"\n")
            if end < 0:
                raise AssertionError("missing diagnostic records")
            complete = data[:end + 1]
            _check_metric_output(io.BytesIO(complete), require_activity=True)
            workers = {}
            sessions = {}
            for record in _metric_records(io.BytesIO(complete)):
                if record.get("missing") or record.get("request") == 0:
                    continue
                if record["owner"] == 1:
                    workers[record["worker_id"], record["slot"]] = record
                elif record["owner"] == 2:
                    sessions[record["worker_id"], record["slot"]] = record
            paired = {slot: (worker, sessions[slot]) for slot, worker
                      in workers.items() if slot in sessions and
                      sessions[slot]["request"] == worker["request"] and
                      sessions[slot]["observed_ns"] == worker["observed_ns"]}
            if len(paired) != 20:
                raise AssertionError("incomplete diagnostic rotation")
            return paired

        def wait_for_snapshots(after=None, minimum_request=0):
            deadline = time.monotonic() + 15
            last_error = None
            while time.monotonic() < deadline:
                try:
                    paired = paired_snapshots()
                    if all(pair[0]["request"] > minimum_request for pair in
                           paired.values()) and (after is None or all(
                           paired[slot][0]["request"] >
                           after[slot][0]["request"] for slot in after)):
                        return paired
                except AssertionError as error:
                    last_error = error
                time.sleep(0.1)
            self.fail(str(last_error or "missing diagnostic rotation"))

        initial = wait_for_snapshots()
        entry_request = max(pair[0]["request"] for pair in initial.values())
        before = wait_for_snapshots(minimum_request=entry_request)
        self.assertEqual(self.request("GET", "/api/tags")[0], 200)
        post_request = wait_for_snapshots(before)
        post_request_id = max(pair[0]["request"] for pair in
                              post_request.values())
        after = wait_for_snapshots(minimum_request=post_request_id)
        def accepted(pairs):
            return sum(max((pair[0] for identity, pair in pairs.items()
                            if identity[0] == worker),
                           key=lambda r: r["request"])["counters"][0]
                       for worker in range(4))
        self.assertEqual(accepted(after) - accepted(before), 1)
        self.assertEqual(sum(pair[1]["counters"][0] for pair in after.values())
                         - sum(pair[1]["counters"][0] for pair in
                               before.values()), 1)
        self.assertEqual(sum(pair[1]["histograms"][6]["count"] for pair in
                             after.values()) - sum(pair[1]["histograms"][6][
                             "count"] for pair in before.values()), 1)

    def test_close_after_rejected_preparation(self):
        process = subprocess.run(
            [str(_executable()), "--test-session-resume-close"],
            env=self.server_env | {"CONDUIT_TEST_POOL_SIZE": "1"},
            capture_output=True, text=True, timeout=10)
        self.assertEqual(process.returncode, 0,
                         _failure_output(process.stderr))
        self.assertEqual(process.stdout.strip(),
                         "rejected preparation closed")

    def test_direct_callback_diagnostic_accounting(self):
        if not _diagnostic_mode():
            self.skipTest("diagnostic variant only")
        database = f"pony_diag_callback_{os.getpid()}"
        self.sql(f"CREATE DATABASE {database} TEMPLATE conduit_dev")
        try:
            self.sql("ALTER TABLE tags RENAME TO tags_hidden", database)
            env = self.server_env.copy()
            env.update(DATABASE_URL=f"postgres://conduit:conduit@"
                       f"{self.proxy.database_host}:"
                       f"{self.proxy.database_port}/{database}",
                       CONDUIT_TEST_POOL_SIZE="1")
            process = subprocess.run(
                [str(_executable()), "--test-worker-diagnostic"],
                env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(process.returncode, 0,
                             _failure_output(process.stderr))
            counts = json.loads(process.stdout)
            self.assertEqual(set(counts), {"callbacks", "pending_close",
                                           "stopped_rejection"})
            self.assertEqual(counts["callbacks"], 3)
            self.assertEqual(counts["pending_close"], 2)
            self.assertEqual(counts["stopped_rejection"], 1)
        finally:
            self.sql(f"DROP DATABASE {database} WITH (FORCE)")

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
        self.assertTrue(b"Database error 22003:" in diagnostics,
                        "expected database error code absent")
        self.assertTrue(b"22P03" not in diagnostics,
                        "unexpected database error code")

    def test_prepared_startup_and_runtime_wire(self):
        def workers():
            return [session for session in self.proxy.snapshot()[:20]
                    if any(kind == b"P" and
                           payload.split(b"\0", 1)[0] == b"tags"
                           for kind, payload in session)]

        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            sessions = workers()
            if len(sessions) == 20 and all(
                len([message for message in session if message[0] == b"P"])
                == 30 for session in sessions):
                break
            time.sleep(0.01)
        self.assertEqual(len(sessions), 20)
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

    @contextmanager
    def pool_run(self, count=2, configure=None, retry_ns=None, csv=False,
                 listener=False):
        proxy = ProtocolProxy(self.proxy.database_host,
                              self.proxy.database_port)
        if configure is not None:
            configure(proxy)
        env = self.server_env.copy()
        env.update(DATABASE_URL=f"postgres://conduit:conduit@127.0.0.1:"
                   f"{proxy.server_address[1]}/{self.database}",
                   CONDUIT_TEST_POOL_SIZE=str(count))
        if retry_ns is not None:
            env["CONDUIT_TEST_RETRY_NS"] = str(retry_ns)
        if listener:
            with socket.socket() as listener_socket:
                listener_socket.bind(("127.0.0.1", 0))
                env["PORT"] = str(listener_socket.getsockname()[1])
        with tempfile.TemporaryFile(mode="w+b") as errors:
            process = subprocess.Popen(
                [str(_executable()),
                 ("--test-listener-csv" if listener else
                  "--test-pool-csv" if csv else "--test-pool"),
                 "--ponymaxthreads=1"],
                env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=errors)
            run = None
            try:
                run = PoolRun(self, process, proxy, csv, count, 4 if listener else 1)
                yield run
            finally:
                for gate in proxy.frame_gates:
                    gate.abort = True
                    gate.release.set()
                if process.poll() is None:
                    try:
                        process.stdin.write(b"quit\n")
                        process.stdin.flush()
                        process.wait(timeout=10)
                    except (BrokenPipeError, subprocess.TimeoutExpired):
                        process.kill()
                        process.wait(timeout=5)
                if run is not None:
                    run.selector.close()
                process.stdin.close()
                process.stdout.close()
                proxy.stop()
                proxy.assert_healthy()
                errors.seek(0)
                self.assertEqual(process.returncode, 0,
                                 _failure_output(errors.read().decode()))

    def tag_snapshot(self, run):
        return json.loads(self.db("SELECT coalesce(json_agg(name ORDER BY name),"
                                  "'[]') FROM tags", run.time_left(30)))

    def tag_holder(self, run, command="user"):
        run.ready(1)
        run.deadline = time.monotonic() + 90
        gate = run.proxy.hold_frame(b"Z", 0, timeout=120)
        run.send(f"{command} 90000 3")
        run.reached(gate)
        run.wait_state(lambda state: state["active"] == [[0, 90000, 1]])
        return gate

    def assert_pool_drained(self, run, count=1):
        state = run.ready(count)
        self.assertEqual(state["active"], [])
        self.assertEqual(state["queued"], [])
        self.assertEqual(state["outstanding"], 0)
        self.assertEqual(state["recipients"], 0)

    def test_pool_tags_batch_boundaries(self):
        for count in (0, 1, 2, 31, 32, 33, 63, 64, 65):
            with self.subTest(count=count), self.pool_run(1) as run:
                holder = self.tag_holder(run)
                expected = self.tag_snapshot(run)
                pairs = [(index + 1, index % 4) for index in range(count)]
                if pairs:
                    run.send(*(f"tags {id} {client}" for id, client in pairs))
                run.wait_state(lambda s: s["queued"] == [p[0] for p in pairs])
                callbacks = {0: 0, 1: 0, 2: 0, 3: 1}
                gate = (run.proxy.hold_frame(b"Z", 0, timeout=120)
                        if count else None)
                holder.release.set()
                run.result(90000, client=3)
                for start in range(0, count, 32):
                    run.reached(gate)
                    batch = pairs[start:start + 32]
                    state = run.wait_state(lambda s: s["active"] ==
                                           [[0, id, 1] for id, _ in batch])
                    self.assertEqual(state["queued"],
                                     [id for id, _ in pairs[start + 32:]])
                    self.assertEqual(run.fence(), callbacks)
                    self.assertEqual(self.routing_binds(run.proxy)[0],
                                     [b"current_user"] + [b"tags"] * (start // 32 + 1))
                    next_gate = (run.proxy.hold_frame(b"Z", 0, timeout=120)
                                 if start + 32 < count else None)
                    gate.release.set()
                    for id, client in batch:
                        result = run.result(id, client=client)
                        self.assertEqual(json.loads(result["payload"])["tags"], expected)
                        callbacks[client] += 1
                    gate = next_gate
                self.assert_pool_drained(run)
                self.assertEqual(run.fence(), callbacks)
                self.assertEqual(self.routing_binds(run.proxy)[0].count(b"tags"),
                                 (count + 31) // 32)
        with self.pool_run(1) as run:
            run.ready(1)
            expected = self.tag_snapshot(run)
            run.send("tags 1 0")
            self.assertEqual(json.loads(run.result(1, client=0)["payload"])["tags"],
                             expected)
            self.assert_pool_drained(run)

    def test_pool_tags_dispatch_budget_is_logical(self):
        for count, prefix, slots, sizes in ((63, 0, 3, [31, 32]),
                (64, 0, 3, [32, 32]), (65, 0, 3, [32, 32]),
                (64, 1, 4, [1, 31, 32])):
            with self.subTest(count=count, prefix=prefix), self.pool_run(slots) as run:
                run.ready(slots)
                run.deadline = time.monotonic() + 90
                gates = [run.proxy.hold_frame(b"Z", index, timeout=120)
                         for index in range(slots)]
                run.send(f"tagbatch {count} {prefix} 70000")
                first = run.receive(lambda e: e.get("event") == "state"
                                    and e["request"] == 70000)
                active_ids = [item[1] for item in first["active"]]
                expected = ([99999] if prefix else []) + list(range(100000, 100000 + count))
                self.assertCountEqual(active_ids, expected[:64])
                self.assertEqual(first["queued"], expected[64:])
                self.assertEqual(first["outstanding"], len(expected))
                self.assertEqual(len(first["idle"]), slots - len(sizes))
                self.assertEqual(set(first["idle"]),
                                 {i for i, phase in enumerate(first["phases"]) if phase == 2})
                self.assertEqual(len(first["idle"]), len(set(first["idle"])))
                self.assertEqual(sorted(sum(item[0] == slot for item in first["active"])
                                        for slot in range(slots)
                                        if any(item[0] == slot for item in first["active"])), sizes)
                state = run.wait_state(lambda s: len(s["active"]) == len(expected)
                                       and all(item[2] == 1 for item in s["active"]))
                self.assertEqual(state["queued"], [])
                for gate, binds in zip(gates, self.routing_binds(run.proxy)):
                    if binds:
                        run.reached(gate)
                        gate.release.set()
                for id in expected:
                    run.result(id, client=0)
                self.assert_pool_drained(run, slots)
                self.assertEqual(run.fence(), {0: len(expected), 1: 0, 2: 0, 3: 0})
        with self.pool_run(2) as run:
            run.ready(2)
            run.deadline = time.monotonic() + 90
            gates = [run.proxy.hold_frame(b"Z", index, timeout=120) for index in range(2)]
            run.send("tagzero 70000")
            first = run.receive(lambda e: e.get("event") == "state" and e["request"] == 70000)
            self.assertEqual([item[1:] for item in first["active"]], [[100063, 0]])
            self.assertEqual(first["queued"], [100064])
            self.assertEqual(first["outstanding"], 2)
            self.assertEqual(len(first["idle"]), 1)
            self.assertEqual(set(first["idle"]),
                             {i for i, phase in enumerate(first["phases"]) if phase == 2})
            if _diagnostic_mode():
                diagnostic = run.receive(lambda e: e.get("event") == "diag"
                                         and e["request"] == 70000)
                self.assertEqual(diagnostic["gauges"][:2], [1, 1])
                self.assertEqual(diagnostic["counters"][:9],
                                 [65, 64, 63, 0, 0, 63, 0, 0, 63])
            run.wait_state(lambda s: len(s["active"]) == 2)
            for gate in gates:
                run.reached(gate)
                gate.release.set()
            for id in range(100000, 100063):
                run.result(id, "data", client=0)
            for id in (100063, 100064):
                run.result(id, client=0)
            self.assertEqual(self.routing_binds(run.proxy), [[b"tags"], [b"tags"]])
            self.assert_pool_drained(run, 2)
            self.assertEqual(run.fence(), {0: 65, 1: 0, 2: 0, 3: 0})
            if _diagnostic_mode():
                diagnostic = run.diagnostic()
                self.assertEqual(diagnostic["counters"][:9],
                                 [65, 65, 65, 0, 0, 65, 0, 2, 63])

    def test_pool_tags_read_scan(self):
        with self.pool_run(1) as run:
            holder = self.tag_holder(run)
            expected = self.tag_snapshot(run)
            run.send("tags 1 0", "user 2 1", "tags 3 2", "user 4 1", "tags 5 0")
            run.wait_state(lambda s: s["queued"] == [1, 2, 3, 4, 5])
            tags = run.proxy.hold_frame(b"Z", 0, timeout=120)
            holder.release.set()
            run.result(90000, client=3)
            run.reached(tags)
            state = run.wait_state(lambda s: [0, 1, 1] in s["active"])
            self.assertEqual(state["active"], [[0, 1, 1], [0, 3, 1], [0, 5, 1]])
            self.assertEqual(state["queued"], [2, 4])
            self.assertEqual(state["outstanding"], 5)
            self.assertEqual(state["recipients"], 3)
            self.assertEqual(self.routing_binds(run.proxy), [[b"current_user", b"tags"]])
            self.assertEqual(run.fence(), {0: 0, 1: 0, 2: 0, 3: 1})
            first_read = run.proxy.hold_frame(b"Z", 0, timeout=120)
            tags.release.set()
            for id, client in ((1, 0), (3, 2), (5, 0)):
                self.assertEqual(json.loads(run.result(id, client=client)["payload"])["tags"], expected)
            run.reached(first_read)
            state = run.wait_state(lambda s: [0, 2, 1] in s["active"])
            self.assertEqual(state["active"], [[0, 2, 1]])
            self.assertEqual(state["queued"], [4])
            last_read = run.proxy.hold_frame(b"Z", 0, timeout=120)
            first_read.release.set()
            run.result(2, client=1)
            run.reached(last_read)
            state = run.wait_state(lambda s: [0, 4, 1] in s["active"])
            self.assertEqual(state["active"], [[0, 4, 1]])
            self.assertEqual(state["queued"], [])
            last_read.release.set()
            run.result(4, client=1)
            self.assert_pool_drained(run)
            self.assertEqual(self.routing_binds(run.proxy),
                             [[b"current_user", b"tags", b"current_user", b"current_user"]])
            self.assertEqual(run.fence(), {0: 2, 1: 2, 2: 1, 3: 1})

    def test_pool_tags_read_scan_cancellation(self):
        for phase in ("queued", "active"):
            with self.subTest(phase=phase), self.pool_run(1) as run:
                holder = self.tag_holder(run)
                expected = self.tag_snapshot(run)
                run.send("tags 1 0", "user 2 1", "tags 3 2")
                run.wait_state(lambda s: s["queued"] == [1, 2, 3])
                if phase == "queued":
                    run.send("cancel 1", "cancel 2")
                    run.state()
                tags = run.proxy.hold_frame(b"Z", 0, timeout=120)
                holder.release.set()
                run.result(90000, client=3)
                run.reached(tags)
                state = run.wait_state(lambda s: [0, 1, 1] in s["active"])
                self.assertEqual(state["active"], [[0, 1, 1], [0, 3, 1]])
                self.assertEqual(state["queued"], [2])
                self.assertEqual(state["outstanding"], 3)
                if phase == "active":
                    run.send("cancel 1", "cancel 2")
                    state = run.state()
                self.assertEqual(state["recipients"], 1)
                run.send("tags 4 2", "tags 5 1")
                state = run.state()
                self.assertEqual(state["active"], [[0, 1, 1], [0, 3, 1]])
                self.assertEqual(state["queued"], [2, 4, 5])
                self.assertEqual(state["outstanding"], 5)
                self.assertEqual(state["recipients"], 3)
                self.assertEqual(run.fence(), {0: 0, 1: 0, 2: 0, 3: 1})
                read = run.proxy.hold_frame(b"Z", 0, timeout=120)
                tags.release.set()
                self.assertEqual(json.loads(run.result(1, client=0)["payload"])["tags"], expected)
                run.reached(read)
                state = run.wait_state(lambda s: [0, 2, 1] in s["active"])
                self.assertEqual(state["active"], [[0, 2, 1]])
                self.assertEqual(state["queued"], [4, 5])
                self.assertEqual(run.fence(), {0: 1, 1: 0, 2: 0, 3: 1})
                fresh = run.proxy.hold_frame(b"Z", 0, timeout=120)
                read.release.set()
                run.reached(fresh)
                state = run.wait_state(lambda s: [0, 4, 1] in s["active"])
                self.assertEqual(state["active"], [[0, 4, 1], [0, 5, 1]])
                self.assertEqual(state["queued"], [])
                self.assertEqual(self.routing_binds(run.proxy),
                                 [[b"current_user", b"tags", b"current_user", b"tags"]])
                fresh.release.set()
                for id, client in ((4, 2), (5, 1)):
                    self.assertEqual(json.loads(run.result(id, client=client)["payload"])["tags"], expected)
                self.assert_pool_drained(run)
                self.assertEqual(run.fence(), {0: 1, 1: 1, 2: 1, 3: 1})

    def test_pool_tags_scan_preserves_write_boundaries(self):
        for query_kind, sql_name, kind in (("user", b"current_user", "ok"),
                ("register", b"register_user", "ok"),
                ("tags-extra-parameter", b"tags", "08P01")):
            for leading in ((False, True) if kind != "ok" else (False,)):
                with self.subTest(query_kind=query_kind, leading=leading), self.pool_run(1) as run:
                    holder = self.tag_holder(run)
                    name = "tagbarrier" + uuid.uuid4().hex
                    command = f"{query_kind} 3 2" + (f" {name}" if query_kind == "register" else "")
                    commands = ([command, "tags 4 0", "tags 5 1"] if leading else
                                ["tags 1 0", "tags 2 1", command, "tags 4 0", "tags 5 1"])
                    groups = ([[3], [4, 5]] if leading else [[1, 2], [3], [4, 5]])
                    queued = sum(groups, [])
                    if query_kind == "user":
                        groups = [[1, 2, 4, 5], [3]]
                    run.send(*commands)
                    run.wait_state(lambda s: s["queued"] == queued)
                    previous = holder
                    for index, ids in enumerate(groups):
                        gate = run.proxy.hold_frame(b"Z", 0, timeout=120)
                        previous.release.set()
                        if index == 0:
                            run.result(90000, client=3)
                        run.reached(gate)
                        outcome = 2 if ids == [3] and kind != "ok" else 1
                        state = run.wait_state(lambda s: s["active"] == [[0, id, outcome] for id in ids])
                        self.assertEqual(state["queued"], sum(groups[index + 1:], []))
                        previous = gate
                    previous.release.set()
                    for id in sum(groups, []):
                        run.result(id, kind if id == 3 else "ok",
                                   client=2 if id == 3 else (0 if id in (1, 4) else 1))
                    expected_binds = ([b"current_user", b"tags", b"current_user"]
                                      if query_kind == "user" else
                                      [b"current_user"] + ([] if leading else [b"tags"])
                                      + [sql_name, b"tags"])
                    self.assertEqual(self.routing_binds(run.proxy)[0], expected_binds)
                    if query_kind == "register":
                        self.assertEqual(self.db("SELECT count(*) FROM users WHERE username="
                                                 + self.literal(name), run.time_left(30)), "1")
                    self.assert_pool_drained(run)
                    run.send("tags 6 0")
                    run.result(6, client=0)
                    self.assert_pool_drained(run)
                    self.assertEqual(run.fence(),
                                     {0: 2 if leading else 3,
                                      1: 1 if leading else 2, 2: 1, 3: 1})
        with self.pool_run(1) as run:
            run.ready(1)
            run.send("tags-nul 1 0", "tags-array 2 1")
            run.result(1, "data", client=0)
            run.result(2, "data", client=1)
            self.assert_pool_drained(run)
            self.assertEqual(self.routing_binds(run.proxy), [[]])
            self.assertEqual(run.fence(), {0: 1, 1: 1, 2: 0, 3: 0})
            if _diagnostic_mode():
                diagnostic = run.diagnostic()
                self.assertEqual(diagnostic["counters"][:9],
                                 [0, 0, 0, 0, 2, 2, 0, 0, 0])

    def test_pool_tags_cancellation_preserves_cohorts(self):
        for phase in ("queued", "active"):
            for mask in range(16):
                with self.subTest(phase=phase, mask=mask), self.pool_run(1) as run:
                    holder = self.tag_holder(run)
                    run.send(*(f"tags {client + 1} {client}" for client in range(4)))
                    run.wait_state(lambda s: s["queued"] == [1, 2, 3, 4])
                    commands = [f"cancel {client}" for client in range(4) if mask & (1 << client)]
                    if phase == "queued" and commands:
                        run.send(*commands)
                    gate = run.proxy.hold_frame(b"Z", 0, timeout=120)
                    holder.release.set()
                    holder_canceled = phase == "queued" and bool(mask & 8)
                    if not holder_canceled:
                        run.result(90000, client=3)
                    run.reached(gate)
                    run.wait_state(lambda s: s["active"] == [[0, id, 1] for id in range(1, 5)])
                    if phase == "active" and commands:
                        run.send(*commands)
                    state = run.state()
                    self.assertEqual(state["outstanding"], 4)
                    self.assertEqual(state["recipients"], 4 - mask.bit_count())
                    gate.release.set()
                    counts = {0: 0, 1: 0, 2: 0, 3: int(not holder_canceled)}
                    for client in range(4):
                        if not mask & (1 << client):
                            run.result(client + 1, client=client)
                            counts[client] += 1
                    self.assert_pool_drained(run)
                    self.assertEqual(run.fence(), counts)
                    self.assertEqual(self.routing_binds(run.proxy)[0], [b"current_user", b"tags"])
        for pairs, cancel in (([(1, 0), (2, 0), (3, 1)], True),
                              ([(1, 0), (1, 1)], False)):
            with self.subTest(pairs=pairs), self.pool_run(1) as run:
                holder = self.tag_holder(run)
                run.send(*(f"tags {id} {client}" for id, client in pairs))
                run.wait_state(lambda s: s["queued"] == [id for id, _ in pairs])
                if cancel:
                    run.send("cancel 0")
                holder.release.set()
                run.result(90000, client=3)
                counts = {0: 0, 1: 0, 2: 0, 3: 1}
                for id, client in pairs:
                    if not cancel or client != 0:
                        run.result(id, client=client)
                        counts[client] += 1
                self.assert_pool_drained(run)
                self.assertEqual(run.fence(), counts)
        with self.pool_run(1) as run:
            holder = self.tag_holder(run)
            run.send("tags 1 0", "tags 2 1")
            run.wait_state(lambda s: s["queued"] == [1, 2])
            gate = run.proxy.hold_frame(b"Z", 0, timeout=120)
            holder.release.set()
            run.result(90000, client=3)
            run.reached(gate)
            run.send("cancel 0", "tags 3 0")
            state = run.wait_state(lambda s: s["queued"] == [3])
            self.assertEqual(state["outstanding"], 3)
            next_gate = run.proxy.hold_frame(b"Z", 0, timeout=120)
            gate.release.set()
            run.result(2, client=1)
            run.reached(next_gate)
            state = run.wait_state(lambda s: s["active"] == [[0, 3, 1]])
            self.assertEqual(state["recipients"], 1)
            self.assertEqual(run.fence(), {0: 0, 1: 1, 2: 0, 3: 1})
            next_gate.release.set()
            run.result(3, client=0)
            self.assert_pool_drained(run)
            self.assertEqual(run.fence(), {0: 1, 1: 1, 2: 0, 3: 1})
        with self.pool_run(1) as run:
            holder = self.tag_holder(run)
            run.send(*(f"tags {id} 0" for id in range(1, 33)), "cancel 0", "tags 33 1")
            run.wait_state(lambda s: s["queued"] == list(range(1, 34)))
            gate = run.proxy.hold_frame(b"Z", 0, timeout=120)
            holder.release.set()
            run.result(90000, client=3)
            run.reached(gate)
            state = run.wait_state(lambda s: len(s["active"]) == 32)
            self.assertEqual(state["queued"], [33])
            self.assertEqual(state["outstanding"], 33)
            gate.release.set()
            run.result(33, client=1)
            self.assert_pool_drained(run)
            self.assertEqual(run.fence(), {0: 0, 1: 1, 2: 0, 3: 1})
            self.assertEqual(self.routing_binds(run.proxy)[0].count(b"tags"), 2)

    def test_pool_tags_sql_failure_fans_out_at_readiness(self):
        for kind in ("26000", "22012"):
            for canceled in (False, True):
                with self.subTest(kind=kind, canceled=canceled), self.pool_run(1) as run:
                    run.ready(1)
                    if kind == "22012":
                        run.send("tags-error-deallocate 80000 3")
                        run.result(80000, client=3)
                        run.send("tags-error-prepare 80001 3")
                        run.result(80001, client=3)
                    holder = self.tag_holder(run, "deallocate" if kind == "26000" else "user")
                    before = run.state()
                    run.send("tags 1 0", "tags 2 1", "tags 3 2")
                    if canceled:
                        run.send("cancel 1")
                    run.wait_state(lambda s: s["queued"] == [1, 2, 3])
                    gate = run.proxy.hold_frame(b"Z", 0, timeout=120)
                    holder.release.set()
                    run.result(90000, client=3)
                    run.reached(gate)
                    run.wait_state(lambda s: s["active"] == [[0, id, 2] for id in (1, 2, 3)])
                    counts = {0: 0, 1: 0, 2: 0, 3: 1 if kind == "26000" else 3}
                    self.assertEqual(run.fence(), counts)
                    gate.release.set()
                    for client in range(3):
                        if not canceled or client != 1:
                            run.result(client + 1, kind, client=client)
                            counts[client] += 1
                    self.assert_pool_drained(run)
                    self.assertEqual(run.state()["generations"],
                                     [before["generations"][0] + (kind == "26000")])
                    self.assertEqual(sum(b.count(b"tags") for b in self.routing_binds(run.proxy)), 1)
                    self.assertEqual(run.fence(), counts)
                    run.send("user 4 0")
                    run.result(4, client=0)
                    counts[0] += 1
                    if kind == "26000":
                        expected = self.tag_snapshot(run)
                        run.send("tags 5 0")
                        self.assertEqual(json.loads(run.result(5, client=0)["payload"])["tags"],
                                         expected)
                        self.assertEqual(sum(b.count(b"tags") for b in self.routing_binds(run.proxy)), 2)
                        counts[0] += 1
                    self.assert_pool_drained(run)
                    self.assertEqual(len(run.proxy.snapshot()), 2 if kind == "26000" else 1)
                    self.assertEqual(run.fence(), counts)

    def test_pool_tags_data_error_reports_once_while_draining(self):
        for ending in ("drain", "loss", "close"):
            with self.subTest(ending=ending), self.pool_run(1) as run:
                holder = self.tag_holder(run)
                run.send("tags 1 0", "tags 2 1", "tags 3 2", "cancel 1")
                run.wait_state(lambda s: s["queued"] == [1, 2, 3])
                run.proxy.corrupt_next_data_row()
                gate = run.proxy.hold_frame(b"Z", 0, timeout=120)
                holder.release.set()
                run.result(90000, client=3)
                run.reached(gate)
                run.result(1, "data", client=0)
                run.result(3, "data", client=2)
                state = run.wait_state(lambda s: s["active"] == [[0, id, 3] for id in (1, 2, 3)])
                self.assertEqual(state["outstanding"], 3)
                self.assertEqual(run.fence(), {0: 1, 1: 0, 2: 1, 3: 1})
                run.send("cancel 0", "tags 4 0")
                run.wait_state(lambda s: s["queued"] == [4])
                if ending == "close":
                    run.send("close", "close")
                    run.result(4, "lost", client=0)
                    state = run.state()
                    self.assertEqual(state["phases"], [5])
                else:
                    if ending == "loss":
                        gate.abort = True
                    gate.release.set()
                    run.result(4, client=0)
                    self.assert_pool_drained(run)
                state = run.state()
                self.assertEqual(state["outstanding"], 0)
                self.assertEqual(state["recipients"], 0)
                self.assertEqual(run.fence(), {0: 2, 1: 0, 2: 1, 3: 1})
                self.assertEqual(sum(b.count(b"tags") for b in self.routing_binds(run.proxy)),
                                 1 if ending == "close" else 2)

        with self.pool_run(1) as run:
            holder = self.tag_holder(run)
            run.send("tags 1 0", "tags 2 0", "tags 3 1", "user 4 2")
            run.wait_state(lambda s: s["queued"] == [1, 2, 3, 4])
            run.proxy.corrupt_next_data_row()
            gate = run.proxy.hold_frame(b"Z", 0, timeout=120)
            holder.release.set()
            run.result(90000, client=3)
            run.reached(gate)
            for id, client in ((1, 0), (2, 0), (3, 1)):
                run.result(id, "data", client=client)
            state = run.wait_state(lambda s: s["active"] == [[0, id, 3] for id in (1, 2, 3)])
            self.assertEqual(state["queued"], [4])
            self.assertEqual(state["outstanding"], 4)
            gate.release.set()
            run.result(4, client=2)
            self.assert_pool_drained(run)
            self.assertEqual(run.fence(), {0: 2, 1: 1, 2: 1, 3: 1})

    def tag_two_holders(self, run):
        run.ready(2)
        run.deadline = time.monotonic() + 90
        gates = [run.proxy.hold_frame(b"Z", connection, timeout=120)
                 for connection in range(2)]
        holders = []
        for id in (90000, 90001):
            before = self.routing_binds(run.proxy)
            run.send(f"user {id} 3")
            state = run.wait_state(lambda s: any(item[1:] == [id, 1] for item in s["active"]))
            after = self.routing_binds(run.proxy)
            connections = [i for i in range(2) if len(after[i]) == len(before[i]) + 1]
            self.assertEqual(len(connections), 1)
            connection = connections[0]
            slot = next(item[0] for item in state["active"] if item[1] == id)
            run.reached(gates[connection])
            holders.append((slot, connection, gates[connection], id))
        self.assertNotEqual(holders[0][0], holders[1][0])
        self.assertNotEqual(holders[0][1], holders[1][1])
        return holders

    def test_pool_tags_loss_settles_members_without_replay(self):
        for outcome, trigger in ((0, "abort"), (0, "retire"),
                                 (1, "abort"), (1, "retire"), (2, "abort")):
            with self.subTest(outcome=outcome, trigger=trigger), self.pool_run(1) as run:
                run.ready(1)
                if outcome == 2:
                    run.send("tags-error-deallocate 80000 3")
                    run.result(80000, client=3)
                    run.send("tags-error-prepare 80001 3")
                    run.result(80001, client=3)
                holder = self.tag_holder(run)
                generation = run.state()["generations"][0]
                run.send("tags 1 0", "tags 2 1", "tags 3 2", "cancel 1")
                run.wait_state(lambda s: s["queued"] == [1, 2, 3])
                gate = run.proxy.hold_frame(b"D" if outcome == 0 else b"Z", 0, timeout=120)
                holder.release.set()
                run.result(90000, client=3)
                run.reached(gate)
                run.wait_state(lambda s: s["active"] == [[0, id, outcome] for id in (1, 2, 3)])
                counts = {0: 0, 1: 0, 2: 0, 3: 3 if outcome == 2 else 1}
                self.assertEqual(run.fence(), counts)
                if trigger == "retire":
                    run.send("retire 0")
                gate.abort = True
                gate.release.set()
                run.result(1, "lost", client=0)
                run.result(3, "lost", client=2)
                self.assert_pool_drained(run)
                self.assertEqual(run.state()["generations"], [generation + 1])
                self.assertEqual(sum(b.count(b"tags") for b in self.routing_binds(run.proxy)), 1)
                counts.update({0: 1, 2: 1})
                self.assertEqual(run.fence(), counts)
                run.send("user 4 0")
                run.result(4, client=0)
        with self.pool_run(2) as run:
            target, survivor = self.tag_two_holders(run)
            target_slot, target_connection, target_gate, target_id = target
            survivor_slot, survivor_connection, survivor_gate, survivor_id = survivor
            run.send("tags 1 0", "tags 2 1")
            run.wait_state(lambda s: s["queued"] == [1, 2])
            group = run.proxy.hold_frame(b"Z", target_connection, timeout=120)
            target_gate.release.set()
            run.result(target_id, client=3)
            run.reached(group)
            run.wait_state(lambda s: [item for item in s["active"] if item[0] == target_slot]
                           == [[target_slot, 1, 1], [target_slot, 2, 1]])
            survivor_gate.release.set()
            run.result(survivor_id, client=3)
            before = run.wait_state(lambda s: s["idle"] == [survivor_slot])
            self.assertEqual(before["queued"], [])
            replacement = len(run.proxy.snapshot())
            preparation = run.proxy.hold_frame(b"1", replacement, timeout=120)
            run.send(f"retire {target_slot}")
            run.result(1, "lost", client=0)
            run.result(2, "lost", client=1)
            run.reached(preparation)
            self.assertEqual(len(run.proxy.snapshot()), replacement + 1)
            run.send("user 4 2")
            run.result(4, client=2)
            binds = self.routing_binds(run.proxy)
            self.assertEqual(binds[survivor_connection], [b"current_user", b"current_user"])
            self.assertEqual(binds[replacement], [])
            self.assertFalse(preparation.release.is_set())
            state = run.state()
            expected_generations = before["generations"].copy()
            expected_generations[target_slot] += 1
            self.assertEqual(state["generations"], expected_generations)
            self.assertEqual(state["phases"][target_slot], 1)
            group.abort = True
            group.release.set()
            preparation.release.set()
            self.assert_pool_drained(run, 2)
            self.assertEqual(run.fence(), {0: 1, 1: 1, 2: 1, 3: 2})

    def test_pool_tags_close_settles_active_and_queued_once(self):
        for outcome in (0, 1):
            with self.subTest(outcome=outcome), self.pool_run(1) as run:
                holder = self.tag_holder(run)
                run.send("tags 1 0", "tags 2 1", "tags 3 2", "cancel 1")
                run.wait_state(lambda s: s["queued"] == [1, 2, 3])
                gate = run.proxy.hold_frame(b"D" if outcome == 0 else b"Z", 0, timeout=120)
                holder.release.set()
                run.result(90000, client=3)
                run.reached(gate)
                run.wait_state(lambda s: s["active"] == [[0, id, outcome] for id in (1, 2, 3)])
                run.send("tags 4 1", "user 5 0", "user 6 3", "cancel 3")
                run.wait_state(lambda s: s["queued"] == [4, 5, 6])
                run.send("close", "close", "tags 7 0")
                for id, client in ((1, 0), (3, 2), (4, 1), (5, 0), (7, 0)):
                    run.result(id, "lost", client=client)
                state = run.state()
                self.assertEqual(state["phases"], [5])
                self.assertEqual(state["queued"], [])
                self.assertEqual(state["active"], [])
                self.assertEqual(state["outstanding"], 0)
                self.assertEqual(state["recipients"], 0)
                gate.abort = True
                gate.release.set()
                self.assertEqual(run.fence(), {0: 3, 1: 1, 2: 1, 3: 1})
                self.assertEqual(self.routing_binds(run.proxy)[0], [b"current_user", b"tags"])

    def test_pool_tags_freshness_after_frozen_result(self):
        names = ["shared-" + uuid.uuid4().hex for _ in range(3)]
        try:
            with self.pool_run(1) as run:
                holder = self.tag_holder(run)
                initial = self.tag_snapshot(run)
                run.send("tags 1 0", "tags 2 1")
                run.wait_state(lambda s: s["queued"] == [1, 2])
                gate = run.proxy.hold_frame(b"Z", 0, timeout=120)
                holder.release.set()
                run.result(90000, client=3)
                run.reached(gate)
                run.wait_state(lambda s: s["active"] == [[0, 1, 1], [0, 2, 1]])
                self.db("INSERT INTO tags(name) VALUES (" + self.literal(names[0]) + ")", run.time_left(30))
                newer = self.tag_snapshot(run)
                self.assertNotIn(names[0], initial)
                self.assertIn(names[0], newer)
                run.send("tags 3 2")
                state = run.wait_state(lambda s: s["queued"] == [3])
                self.assertEqual([item[1] for item in state["active"]], [1, 2])
                gate.release.set()
                for id, client in ((1, 0), (2, 1)):
                    self.assertEqual(json.loads(run.result(id, client=client)["payload"])["tags"], initial)
                self.assertEqual(json.loads(run.result(3, client=2)["payload"])["tags"], newer)
                self.assert_pool_drained(run)
                self.db("INSERT INTO tags(name) VALUES (" + self.literal(names[1]) + ")", run.time_left(30))
                newest = self.tag_snapshot(run)
                self.assertIn(names[1], newest)
                run.send("tags 4 0")
                self.assertEqual(json.loads(run.result(4, client=0)["payload"])["tags"], newest)
                self.assertEqual(self.routing_binds(run.proxy)[0].count(b"tags"), 3)
                self.assert_pool_drained(run)
                self.assertEqual(run.fence(), {0: 2, 1: 1, 2: 1, 3: 1})
            with self.pool_run(2) as run:
                old, new = self.tag_two_holders(run)
                initial = self.tag_snapshot(run)
                run.send("tags 1 0", "tags 2 1")
                run.wait_state(lambda s: s["queued"] == [1, 2])
                old_gate = run.proxy.hold_frame(b"Z", old[1], timeout=120)
                old[2].release.set()
                run.result(old[3], client=3)
                run.reached(old_gate)
                run.wait_state(lambda s: [item for item in s["active"] if item[0] == old[0]]
                               == [[old[0], 1, 1], [old[0], 2, 1]])
                self.db("INSERT INTO tags(name) VALUES (" + self.literal(names[2]) + ")", run.time_left(30))
                newer = self.tag_snapshot(run)
                self.assertNotIn(names[2], initial)
                self.assertIn(names[2], newer)
                run.send("tags 3 0", "tags 4 1")
                run.wait_state(lambda s: s["queued"] == [3, 4])
                new_gate = run.proxy.hold_frame(b"Z", new[1], timeout=120)
                new[2].release.set()
                run.result(new[3], client=3)
                run.reached(new_gate)
                run.wait_state(lambda s: [item for item in s["active"] if item[0] == new[0]]
                               == [[new[0], 3, 1], [new[0], 4, 1]])
                new_gate.release.set()
                for id, client in ((3, 0), (4, 1)):
                    self.assertEqual(json.loads(run.result(id, client=client)["payload"])["tags"], newer)
                self.assertEqual(run.fence(), {0: 1, 1: 1, 2: 0, 3: 2})
                old_gate.release.set()
                for id, client in ((1, 0), (2, 1)):
                    self.assertEqual(json.loads(run.result(id, client=client)["payload"])["tags"], initial)
                self.assert_pool_drained(run, 2)
                self.assertEqual(run.fence(), {0: 2, 1: 2, 2: 0, 3: 2})
                self.assertEqual(self.routing_binds(run.proxy),
                                 [[b"current_user", b"tags"], [b"current_user", b"tags"]])
        finally:
            self.db("DELETE FROM tags WHERE name IN (" + ",".join(map(self.literal, names)) + ")")

    @unittest.skipUnless(_diagnostic_mode(), "diagnostic build only")
    def test_pool_tags_logical_diagnostics(self):
        for ending in ("success", "cancel", "sql", "data", "close"):
            with self.subTest(ending=ending), self.pool_run(1, csv=True) as run:
                holder = self.tag_holder(run, "deallocate" if ending == "sql" else "user")
                baseline = run.diagnostic()
                run.send("tags 1 0", "tags 2 1", "tags 3 2")
                run.wait_state(lambda s: s["queued"] == [1, 2, 3])
                queued = run.diagnostic()
                self.assertEqual(queued["counters"][0] - baseline["counters"][0], 3)
                self.assertEqual(queued["gauges"][:2], [3, 1])
                self.assertEqual(run.csv_sample()["pending"], 3)
                if ending == "cancel":
                    run.send("cancel 1")
                if ending == "data":
                    run.proxy.corrupt_next_data_row()
                gate = run.proxy.hold_frame(b"Z", 0, timeout=120)
                holder.release.set()
                run.result(90000, client=3)
                run.reached(gate)
                outcome = 2 if ending == "sql" else 3 if ending == "data" else 1
                run.wait_state(lambda s: s["active"] == [[0, id, outcome] for id in (1, 2, 3)])
                if ending == "data":
                    for client in range(3):
                        run.result(client + 1, "data", client=client)
                active = run.diagnostic()
                self.assertEqual(active["gauges"][:2], [0, 3])
                self.assertEqual(active["gauges"][7], 1)
                self.assertEqual(run.csv_sample()["busy"], 1)
                self.assertEqual(active["counters"][1] - baseline["counters"][1], 3)
                self.assertEqual(active["counters"][2] - baseline["counters"][2], 1)
                self.assertEqual(active["counters"][5] - baseline["counters"][5],
                                 4 if ending == "data" else 1)
                self.assertEqual(active["histograms"][1] - baseline["histograms"][1], 3)
                if ending == "close":
                    run.send("tags 4 0", "user 5 1")
                    run.wait_state(lambda s: s["queued"] == [4, 5])
                    run.send("close")
                    for id, client in ((1, 0), (2, 1), (3, 2), (4, 0), (5, 1)):
                        run.result(id, "lost", client=client)
                else:
                    gate.release.set()
                    if ending != "data":
                        for client in range(3):
                            if ending != "cancel" or client != 1:
                                run.result(client + 1, "26000" if ending == "sql" else "ok", client=client)
                    self.assert_pool_drained(run)
                final = run.diagnostic()
                accepted = 5 if ending == "close" else 3
                success = 4 if ending in ("success", "cancel") else 1
                failures = accepted if ending in ("sql", "data", "close") else 0
                delivered = accepted + 1 - (ending == "cancel")
                deltas = [a - b for a, b in zip(final["counters"], baseline["counters"])]
                self.assertEqual(deltas[:9], [accepted, 3, accepted + 1,
                    2 if ending == "close" else 0, 0, delivered,
                    int(ending == "cancel"), success, failures])
                self.assertEqual(final["gauges"][:2], [0, 0])
                self.assertEqual(final["histograms"][1] - baseline["histograms"][1], 3)
                self.assertEqual(final["histograms"][2] - baseline["histograms"][2], accepted + 1)
                self.assertEqual(final["histograms"][3] - baseline["histograms"][3], 3)
                self.assertEqual(sum(final["histograms"][4:]) - sum(baseline["histograms"][4:]), 1)
                self.assertEqual(final["histograms"][0], baseline["histograms"][0])

    def test_pool_uses_idle_connection_while_another_is_blocked(self):
        with self.pool_run() as run:
            run.ready(2)
            with SQLSession(self.database) as holder:
                holder.execute("BEGIN; LOCK TABLE tags IN ACCESS EXCLUSIVE MODE;")
                run.send("tags 1 0")
                run.wait_state(lambda state: len(state["active"]) == 1)
                run.send("user 2 0")
                run.result(2)
                state = run.state()
                self.assertEqual([item[1] for item in state["active"]], [1])
                self.assertEqual(state["queued"], [])
                holder.execute("ROLLBACK;")
                run.result(1)
            run.ready(2)

    def test_pool_initial_connections_become_ready_independently(self):
        gates = []
        with self.pool_run(configure=lambda proxy: gates.append(
                proxy.hold_frame(b"1", 0))) as run:
            self.assertTrue(gates[0].reached.wait(5))
            run.wait_state(lambda state: sorted(state["phases"]) == [1, 2])
            run.send("user 1 0")
            run.result(1)
            self.assertEqual(self.routing_binds(run.proxy)[0], [])
            self.assertEqual(sorted(run.state()["phases"]), [1, 2])
            gates[0].release.set()
            run.ready(2)

    def test_pool_retiring_idle_slots_preserves_available_connections(self):
        for count, position in ((1, 0), (3, 0), (3, 1), (3, 2)):
            with self.subTest(count=count, position=position), self.pool_run(
                    count, retry_ns=60_000_000_000) as run:
                before = run.ready(count)
                victim = before["idle"][position]
                survivors = set(before["idle"]) - {victim}
                generations = before["generations"].copy()
                generations[victim] += 1
                run.send(f"retire {victim}")
                retired = run.wait_state(lambda state:
                    state["phases"][victim] == 4)
                self.assertEqual(set(retired["idle"]), survivors)
                self.assertEqual(retired["generations"], generations)
                with SQLSession(self.database) as holder:
                    holder.execute(
                        "BEGIN; LOCK TABLE tags IN ACCESS EXCLUSIVE MODE;")
                    run.send(*(f"tags {id} 0" for id in range(1, count + 1)))
                    busy = run.wait_state(lambda state:
                        len(state["active"]) == len(survivors) and
                        state["queued"] == [count])
                    self.assertEqual({item[0] for item in busy["active"]},
                                     survivors)
                    self.assertEqual({item[1] for item in busy["active"]},
                                     set(range(1, count)))
                    self.assertEqual(busy["idle"], [])
                    self.assertEqual(busy["phases"][victim], 4)
                    holder.execute("ROLLBACK;")
                if survivors:
                    for id in range(1, count + 1):
                        run.result(id)
                    settled = run.wait_state(lambda state:
                        not state["active"] and not state["queued"])
                    self.assertEqual(set(settled["idle"]), survivors)
                    self.assertEqual(settled["phases"][victim], 4)
                else:
                    run.send("close")
                    run.result(1, "lost")
                run.send("close", "close")
                stopped = run.state()
                self.assertEqual(stopped["phases"], [5] * count)
                self.assertEqual(stopped["idle"], [])
                self.assertEqual(stopped["active"], [])
                self.assertEqual(stopped["queued"], [])
                self.assertEqual(stopped["generations"], generations)
                self.assertEqual(stopped["recipients"], 0)
                self.assertEqual(stopped["outstanding"], 0)
                self.assertEqual(run.fence(), {0: count, 1: 0, 2: 0, 3: 0})

    def test_pool_retiring_busy_slot_preserves_other_idle_connections(self):
        with self.pool_run(3, retry_ns=60_000_000_000) as run:
            run.ready(3)
            with SQLSession(self.database) as holder:
                holder.execute(
                    "BEGIN; LOCK TABLE tags IN ACCESS EXCLUSIVE MODE;")
                run.send("tags 1 0")
                before = run.wait_state(lambda state:
                    len(state["active"]) == 1)
                victim = before["active"][0][0]
                survivors = set(before["idle"])
                generations = before["generations"].copy()
                generations[victim] += 1
                run.send(f"retire {victim}")
                run.result(1, "lost")
                retired = run.state()
                self.assertEqual(set(retired["idle"]), survivors)
                self.assertEqual(retired["phases"][victim], 4)
                self.assertEqual(retired["generations"], generations)
                run.send("tags 2 0", "tags 3 0", "tags 4 0")
                busy = run.wait_state(lambda state:
                    len(state["active"]) == 2 and state["queued"] == [4])
                self.assertEqual({item[0] for item in busy["active"]},
                                 survivors)
                self.assertEqual({item[1] for item in busy["active"]}, {2, 3})
                self.assertEqual(busy["idle"], [])
                self.assertEqual(busy["phases"][victim], 4)
                holder.execute("ROLLBACK;")
            for id in (2, 3, 4):
                run.result(id)
            settled = run.wait_state(lambda state:
                not state["active"] and not state["queued"])
            self.assertEqual(set(settled["idle"]), survivors)
            self.assertEqual(settled["phases"][victim], 4)
            run.send("close", "close")
            stopped = run.state()
            self.assertEqual(stopped["phases"], [5] * 3)
            self.assertEqual(stopped["idle"], [])
            self.assertEqual(stopped["outstanding"], 0)
            self.assertEqual(run.fence(), {0: 4, 1: 0, 2: 0, 3: 0})

    def test_pool_fifo_dispatches_detached_jobs_on_each_freed_connection(self):
        with self.pool_run() as run:
            run.ready(2)
            gates = [run.proxy.hold_frame(b"Z", index) for index in range(2)]
            run.send("tags 1 0", "user 2 0")
            for gate in gates:
                self.assertTrue(gate.reached.wait(5))
            run.wait_state(lambda state: len(state["active"]) == 2 and
                           all(item[2] == 1 for item in state["active"]))
            name = "pool-fifo-" + uuid.uuid4().hex
            run.send("tags 3 0", "user 4 1", f"register 5 0 {name}", "cancel 1")
            self.assertEqual(run.state()["queued"], [3, 4, 5])
            following = [run.proxy.hold_frame(b"Z", index) for index in range(2)]
            gates[0].release.set()
            self.assertTrue(following[0].reached.wait(5))
            binds = self.routing_binds(run.proxy)
            self.assertEqual(len(binds[0]), 2)
            self.assertEqual(binds[0][-1], b"tags")
            self.assertEqual(len(binds[1]), 1)
            self.assertEqual(run.state()["queued"], [4, 5])
            gates[1].release.set()
            self.assertTrue(following[1].reached.wait(5))
            binds = self.routing_binds(run.proxy)
            self.assertEqual(len(binds[1]), 2)
            self.assertEqual(binds[1][-1], b"current_user")
            self.assertEqual(run.state()["queued"], [5])
            following[0].release.set()
            run.result(3)
            run.result(5)
            following[1].release.set()
            run.result(1)
            run.result(2)
            run.ready(2)
            self.assertEqual(run.fence(), {0: 4, 1: 0, 2: 0, 3: 0})

    def test_pool_success_and_sql_failure_wait_for_final_readiness(self):
        name = "pool-duplicate-" + uuid.uuid4().hex
        self.db("INSERT INTO users(username,email,password_hash) VALUES (" +
                self.literal(name) + "," + self.literal(name + "@pool.test") +
                ",'test-hash')")
        for command, outcome, kind, bound in [
                ("tags 1 0", 1, "ok", b"tags"),
                (f"register 1 0 {name}", 2, "23505", b"register_user")]:
            with self.subTest(kind=kind), self.pool_run(1) as run:
                run.ready(1)
                gate = run.proxy.hold_frame(b"Z", 0)
                run.send(command, "user 2 0")
                self.assertTrue(gate.reached.wait(5))
                state = run.wait_state(lambda state:
                    state["active"] == [[0, 1, outcome]])
                self.assertEqual(state["queued"], [2])
                self.assertEqual(self.routing_binds(run.proxy)[0], [bound])
                self.assertEqual(run.fence()[0], 0)
                gate.release.set()
                run.result(1, kind)
                run.result(2)
                run.ready(1)
                self.assertEqual(len(run.proxy.snapshot()), 1)
                self.assertEqual(run.fence()[0], 2)

    def test_pool_decode_failure_reports_once_while_draining(self):
        for ending in ("drain", "loss", "close"):
            with self.subTest(ending=ending), self.pool_run(1) as run:
                run.ready(1)
                gate = run.proxy.hold_frame(b"Z", 0)
                run.proxy.corrupt_next_data_row()
                run.send("tags 1 0", "user 2 0")
                self.assertTrue(gate.reached.wait(5))
                run.result(1, "data")
                state = run.wait_state(lambda state:
                    state["active"] == [[0, 1, 3]])
                self.assertEqual(state["queued"], [2])
                self.assertEqual(run.fence()[0], 1)
                if ending == "loss":
                    gate.abort = True
                    gate.release.set()
                elif ending == "close":
                    run.send("close")
                else:
                    gate.release.set()
                run.result(2, "lost" if ending == "close" else "ok")
                run.wait_state(lambda state: not state["queued"] and
                               not state["active"])
                self.assertEqual(run.fence()[0], 2)

    def test_pool_detached_unsent_write_runs_and_new_attachment_survives(self):
        with self.pool_run(1) as run:
            run.ready(1)
            gate = run.proxy.hold_frame(b"Z", 0)
            run.send("tags 1 0")
            self.assertTrue(gate.reached.wait(5))
            name = "pool-detached-" + uuid.uuid4().hex
            run.send(f"register 2 1 {name}", "cancel 1", "user 3 1")
            state = run.state()
            self.assertEqual(state["queued"], [2, 3])
            self.assertEqual(state["recipients"], 2)
            self.assertEqual(state["outstanding"], 3)
            gate.release.set()
            run.result(1)
            run.result(3)
            run.ready(1)
            self.assertEqual(run.fence(), {0: 1, 1: 1, 2: 0, 3: 0})
            self.assertEqual(run.state()["recipients"], 0)
            self.assertEqual(self.db("SELECT count(*) FROM users WHERE username=" +
                                    self.literal(name)), "1")

    def test_pool_detached_startup_write_still_runs(self):
        gates = []
        with self.pool_run(1, configure=lambda proxy: gates.append(
                proxy.hold_frame(b"1", 0))) as run:
            self.assertTrue(gates[0].reached.wait(5))
            name = "pool-startup-" + uuid.uuid4().hex
            run.send(f"register 1 1 {name}", "user 2 0", "cancel 1")
            self.assertEqual(run.state()["queued"], [1, 2])
            gates[0].release.set()
            run.result(2)
            run.ready(1)
            self.assertEqual(run.fence(), {0: 1, 1: 0, 2: 0, 3: 0})
            self.assertEqual(self.db("SELECT count(*) FROM users WHERE username=" +
                                    self.literal(name)), "1")

    def test_pool_connection_loss_does_not_replay_committed_write(self):
        with self.pool_run() as run:
            run.ready(2)
            gates = [run.proxy.hold_frame(b"Z", index) for index in range(2)]
            name = "pool-committed-" + uuid.uuid4().hex
            run.send(f"register 1 0 {name}", "tags 2 0")
            for gate in gates:
                self.assertTrue(gate.reached.wait(5))
            run.wait_state(lambda state: len(state["active"]) == 2 and
                           all(item[2] == 1 for item in state["active"]))
            self.assertEqual(self.db("SELECT count(*) FROM users WHERE username=" +
                                    self.literal(name)), "1")
            binds = self.routing_binds(run.proxy)
            lost = next(index for index, names in enumerate(binds)
                        if names == [b"register_user"])
            replacement = run.proxy.hold_frame(b"1", 2)
            run.send("user 3 0")
            self.assertEqual(run.state()["queued"], [3])
            gates[lost].abort = True
            gates[lost].release.set()
            run.result(1, "lost")
            gates[1 - lost].release.set()
            run.result(2)
            run.result(3)
            self.assertTrue(replacement.reached.wait(5))
            self.assertEqual(self.routing_binds(run.proxy)[2], [])
            replacement.release.set()
            run.ready(2)
            binds = self.routing_binds(run.proxy)
            self.assertEqual(sum(names.count(b"register_user") for names in binds), 1)
            self.assertEqual(sum(kind == b"P" for kind, _ in
                                 run.proxy.snapshot()[2]), 30)
            self.assertEqual(run.fence()[0], 3)

    def test_pool_nonidle_and_missing_statement_retire_only_the_slot(self):
        for command, kind in (("begin 1 0", "lost"),
                              ("deallocate 1 0", "ok")):
            with self.subTest(command=command), self.pool_run(1) as run:
                run.ready(1)
                run.send(command)
                run.result(1, kind)
                if command.startswith("deallocate"):
                    run.send("tags 2 0")
                    run.result(2, "26000")
                run.wait_state(lambda state: state["generations"] == [1])
                run.send("user 3 0")
                run.result(3)
                run.ready(1)
                self.assertEqual(len(run.proxy.snapshot()), 2)
                self.assertEqual(sum(kind == b"P" for kind, _ in
                                     run.proxy.snapshot()[1]), 30)
                self.assertEqual(run.fence()[0], 3 if command.startswith(
                                 "deallocate") else 2)

    def test_pool_stale_retry_token_generation_and_close_are_ignored(self):
        with self.pool_run(1, retry_ns=60_000_000_000) as run:
            run.ready(1)
            run.send("retire 0")
            first = run.wait_state(lambda state: state["phases"] == [4])
            run.send(f"retry 0 {first['request']} 1")
            run.ready(1)
            run.send("retire 0")
            second = run.wait_state(lambda state: state["phases"] == [4])
            run.send(f"retry 0 {first['request']} 2")
            self.assertEqual(run.state()["phases"], [4])
            run.send(f"retry 0 {second['request']} 1")
            self.assertEqual(run.state()["phases"], [4])
            self.assertEqual(len(run.proxy.snapshot()), 2)
            run.send(f"retry 0 {second['request']} 2")
            run.ready(1)
            run.send("retire 0")
            third = run.wait_state(lambda state: state["phases"] == [4])
            run.send("close", f"retry 0 {third['request']} 3")
            state = run.state()
            self.assertEqual(state["phases"], [5])
            self.assertEqual(state["generations"], [3])
            self.assertEqual(len(run.proxy.snapshot()), 3)
            run.send("tags 1 0")
            run.result(1, "lost")
            self.assertEqual(run.fence()[0], 1)

    def test_pool_synchronous_rejections_yield_then_drain(self):
        with self.pool_run(1) as run:
            run.ready(1)
            run.send("badbatch 130 900001")
            partial = run.receive(lambda event: event.get("event") == "state"
                                  and event["request"] == 900001)
            self.assertGreater(len(partial["queued"]), 0)
            self.assertLess(len(partial["queued"]), 130)
            self.assertEqual(partial["active"], [])
            self.assertEqual(partial["idle"], [0])
            self.assertEqual(partial["outstanding"], len(partial["queued"]))
            for id in range(100000, 100130):
                run.result(id, "data")
            run.ready(1)
            self.assertEqual(run.fence()[0], 130)
            self.assertEqual(self.routing_binds(run.proxy)[0], [])
            run.send("user 1 0")
            run.result(1)
            self.assertEqual(len(run.proxy.snapshot()), 1)

    def test_pool_close_settles_attached_jobs_once_and_stops_dispatch(self):
        with self.pool_run(1) as run:
            run.ready(1)
            gate = run.proxy.hold_frame(b"Z", 0)
            run.send("tags 1 0", "user 2 0", "user 3 1", "cancel 1")
            self.assertTrue(gate.reached.wait(5))
            run.wait_state(lambda state: state["active"] == [[0, 1, 1]])
            run.send("close", "close", "user 4 0")
            run.result(1, "lost")
            run.result(2, "lost")
            run.result(4, "lost")
            state = run.state()
            self.assertEqual(state["phases"], [5])
            self.assertEqual(state["recipients"], 0)
            self.assertEqual(state["outstanding"], 0)
            self.assertEqual(self.routing_binds(run.proxy)[0], [b"tags"])
            self.assertEqual(run.fence(), {0: 3, 1: 0, 2: 0, 3: 0})

    @contextmanager
    def routing_server(self, count, readiness=True):
        proxy = ProtocolProxy(self.proxy.database_host,
                              self.proxy.database_port)
        try:
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            env = self.server_env.copy()
            env.update(DATABASE_URL=f"postgres://conduit:conduit@127.0.0.1:"
                       f"{proxy.server_address[1]}/{self.database}",
                       PORT=str(port), CONDUIT_TEST_POOL_SIZE=str(count))
            with tempfile.TemporaryFile(mode="w+b") as log, \
                 tempfile.TemporaryFile(mode="w+b") as metrics:
                server = subprocess.Popen(
                    [str(_executable()), "--test-http", "--db-worker-count=4"],
                    env=env, stderr=log,
                    stdout=metrics)
                try:
                    deadline = time.monotonic() + 15
                    while time.monotonic() < deadline:
                        self.assertIsNone(server.poll())
                        sessions = proxy.snapshot()
                        if len(sessions) == 4 * count and all(
                                any(kind == b"P" and payload == b"rollback\0"
                                    for kind, payload in session)
                                for session in sessions):
                            break
                        time.sleep(0.01)
                    else:
                        self.fail("routing server preparation timed out")
                    if readiness:
                        ready = self.routing_connect(port)
                        try:
                            self.routing_tags(ready, proxy)
                        finally:
                            ready.close()
                    yield port, proxy, metrics, server
                finally:
                    server.terminate()
                    try:
                        server.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait(timeout=5)
                    _check_metric_output(metrics if _diagnostic_mode() else None)
        finally:
            proxy.stop()

    @staticmethod
    def routing_binds(proxy):
        return [[payload.split(b"\0", 2)[1] for kind, payload in session
                 if kind == b"B"] for session in proxy.snapshot()]

    def routing_pool_routes(self, database, connections, proxy, sizes):
        request = b"GET /api/tags HTTP/1.1\r\nHost: localhost\r\n\r\n"
        routes = []
        with SQLSession(database) as holder:
            holder.execute("BEGIN; LOCK TABLE tags IN ACCESS EXCLUSIVE MODE;")
            for connection, count in zip(connections, sizes):
                before = self.routing_binds(proxy)
                deadline = time.monotonic() + 10
                for submitted in range(1, count + 1):
                    connection.sock.sendall(request)
                    while time.monotonic() < deadline:
                        after = self.routing_binds(proxy)
                        self.assertEqual(len(after), len(before))
                        changes = {index: names[len(before[index]):]
                                   for index, names in enumerate(after)
                                   if names != before[index]}
                        if sum(map(len, changes.values())) >= submitted:
                            break
                        time.sleep(0.01)
                    else:
                        self.fail("pool capacity timed out: " + repr(changes))
                self.assertEqual(len(changes), count)
                self.assertTrue(all(names == [b"tags"]
                                    for names in changes.values()))
                route = set(changes)
                for previous in routes:
                    self.assertTrue(route.isdisjoint(previous))
                routes.append(route)
            holder.execute("ROLLBACK;")
        for connection, count in zip(connections, sizes):
            with connection.sock.makefile("rb") as stream:
                for _ in range(count):
                    status, body = self.routing_read_response(stream)
                    self.assertEqual(status, 200)
                    self.assertIsInstance(body["tags"], list)
        return routes

    def csv_output(self, metrics, counts):
        data = os.pread(metrics.fileno(),
                                        os.fstat(metrics.fileno()).st_size, 0)
        data = data[:data.rfind(b"\n") + 1]
        return _split_output(io.BytesIO(data), counts,
                             allow_json=_diagnostic_mode())[0]

    def wait_csv(self, metrics, server, predicate, count=1, timeout=15):
        deadline = time.monotonic() + timeout
        latest = {}
        while time.monotonic() < deadline:
            self.assertIsNone(server.poll())
            csv = self.csv_output(metrics, dict.fromkeys(range(4), count))
            for row in csv.rows:
                latest[row["worker_id"]] = row
            if predicate(latest):
                return latest
            time.sleep(0.02)
        self.fail("CSV state timed out: " + repr(latest))

    def assert_csv_phase(self, row, phase, pending=0):
        for name in CSV_FIELDS[2:8]:
            with self.subTest(phase=phase, column=name):
                self.assertEqual(row[name], int(name == phase), name)
        self.assertEqual(row["pending"], pending)
        self.assertGreater(row["monotonic_ns"], 0)

    def test_worker_csv_periodic_identity(self):
        with self.routing_server(1, readiness=False) as run:
            _, _, metrics, server = run
            self.wait_csv(metrics, server,
                lambda rows: len(rows) == 4 and all(row["idle"] == 1
                                                   for row in rows.values()))
            first = self.csv_output(metrics, dict.fromkeys(range(4), 1))
            previous = {row["worker_id"]: row["monotonic_ns"]
                        for row in first.rows}
            self.wait_csv(metrics, server,
                lambda rows: all(rows.get(worker, {}).get("monotonic_ns", 0)
                                 > stamp for worker, stamp in previous.items()))
            csv = self.csv_output(metrics, dict.fromkeys(range(4), 1))
            self.assertTrue(csv.header)
            self.assertEqual({row["worker_id"] for row in csv.rows}, set(range(4)))
            for worker in range(4):
                rows = [row for row in csv.rows if row["worker_id"] == worker
                        and row["monotonic_ns"] >= previous[worker]]
                self.assertGreaterEqual(len(rows), 2)
                for row in rows:
                    self.assert_csv_phase(row, "idle")
                self.assertTrue(all(a["monotonic_ns"] < b["monotonic_ns"]
                                    for a, b in zip(rows, rows[1:])))

    def test_worker_csv_queue_is_per_worker(self):
        with self.routing_server(1, readiness=False) as run, ExitStack() as cleanup:
            port, proxy, metrics, server = run
            connections = [self.routing_connect(port) for _ in range(4)]
            for connection in connections:
                cleanup.callback(connection.close)
            routes = [self.routing_tags(connection, proxy)
                      for connection in connections]
            self.assertEqual(len(set(routes)), 4)
            gate = proxy.hold_frame(b"Z", routes[0], timeout=60)
            cleanup.callback(gate.release.set)
            request = b"GET /api/tags HTTP/1.1\r\nHost: localhost\r\n\r\n"
            connections[0].sock.sendall(request)
            self.assertTrue(gate.reached.wait(5))
            connections[0].sock.sendall(request * 2)
            held = self.wait_csv(metrics, server,
                lambda rows: rows.get(0, {}).get("pending") == 2)
            self.assert_csv_phase(held[0], "busy", 2)
            stamp = held[0]["monotonic_ns"]
            rows = self.wait_csv(metrics, server,
                lambda rows: len(rows) == 4 and all(
                    row["monotonic_ns"] >= stamp for row in rows.values()))
            self.assert_csv_phase(rows[0], "busy", 2)
            for worker in range(1, 4):
                self.assert_csv_phase(rows[worker], "idle")
            self.assertEqual(self.routing_binds(proxy)[routes[0]], [b"tags"] * 2)
            self.assertFalse(gate.release.is_set())
            gate.release.set()
            with connections[0].sock.makefile("rb") as stream:
                for _ in range(3):
                    status, body = self.routing_read_response(stream)
                    self.assertEqual(status, 200)
                    self.assertIsInstance(body["tags"], list)
            rows = self.wait_csv(metrics, server,
                lambda rows: rows.get(0, {}).get("idle") == 1 and
                    rows[0]["pending"] == 0 and rows[0]["monotonic_ns"] > stamp)
            self.assert_csv_phase(rows[0], "idle")

    def test_pool_csv_busy_pending(self):
        with self.pool_run(1, csv=True) as run:
            run.ready(1)
            gate = run.proxy.hold_frame(b"Z", 0, timeout=60)
            run.send("tags 1 0", "user 2 1", "user 3 1")
            self.assertTrue(gate.reached.wait(5))
            run.wait_state(lambda state: len(state["active"]) == 1 and
                           state["queued"] == [2, 3])
            observed = run.csv_sample()["monotonic_ns"]
            row = run.receive(lambda event: event.get("event") == "csv" and
                              event["row"]["monotonic_ns"] > observed)["row"]
            self.assert_csv_phase(row, "busy", 2)
            self.assertEqual(self.routing_binds(run.proxy)[0], [b"tags"])
            run.send("cancel 1")
            state = run.state()
            self.assertEqual(state["queued"], [2, 3])
            self.assert_csv_phase(run.csv_sample(), "busy", 2)
            gate.release.set()
            run.result(1)
            run.ready(1)
            row = run.receive(lambda event: event.get("event") == "csv" and
                event["row"]["idle"] == 1 and event["row"]["pending"] == 0
                and event["row"]["monotonic_ns"] > row["monotonic_ns"])["row"]
            self.assert_csv_phase(row, "idle")

    def test_pool_csv_phase_mapping(self):
        gates = []
        def configure(proxy):
            gates.append(proxy.hold_frame(b"Z", 0, timeout=60))
            gates.append(proxy.hold_frame(b"1", 0, timeout=60))
        with self.pool_run(1, configure=configure, retry_ns=60_000_000_000,
                           csv=True) as run:
            for code, phase in ((0, "connecting"), (1, "preparing")):
                self.assertTrue(gates[code].reached.wait(5))
                run.wait_state(lambda state: state["phases"] == [code])
                sample = run.csv_sample()
                self.assert_csv_phase(sample, phase)
                event = run.receive(lambda event: event.get("event") == "csv"
                    and event["row"]["monotonic_ns"] > sample["monotonic_ns"])
                self.assert_csv_phase(event["row"], phase)
                gates[code].release.set()
            run.ready(1)
            self.assert_csv_phase(run.csv_sample(), "idle")
            run.send("retire 0")
            run.wait_state(lambda state: state["phases"] == [4])
            sample = run.csv_sample()
            self.assert_csv_phase(sample, "backoff")
            event = run.receive(lambda event: event.get("event") == "csv" and
                event["row"]["monotonic_ns"] > sample["monotonic_ns"])
            self.assert_csv_phase(event["row"], "backoff")
            run.send("close")
            run.wait_state(lambda state: state["phases"] == [5])
            self.assert_csv_phase(run.csv_sample(), "stopped")

    def test_pool_csv_lifecycle(self):
        with self.pool_run(1, csv=True) as run:
            run.ready(1)
            run.receive(lambda event: event.get("event") == "csv")
            run.send("stop-csv", "stop-csv")
            run.csv_fence()
            before = len(run.csv.rows)
            run.csv_fence()
            self.assertEqual(len(run.csv.rows), before)
            run.send("close", "close")
            run.csv_fence()
            self.assertEqual(len(run.csv.rows), before)
            self.assert_csv_phase(run.csv_sample(), "stopped")
            run.send("quit")
            self.assertEqual(run.process.wait(timeout=5), 0)

    def test_listener_close_stops_csv_preserves_workers(self):
        with self.pool_run(1, csv=True, listener=True) as run:
            run.ready(1)
            for worker in range(4):
                run.receive(lambda event: event.get("event") == "csv" and
                            event["row"]["worker_id"] == worker and
                            event["row"]["idle"] == 1)
            run.send("listener-close")
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                run.sequence += 1
                request = run.sequence
                run.send(f"sampling {request}")
                states = [run.receive(lambda event: event.get("event") ==
                    "sampling" and event["request"] == request)
                    for _ in range(4)]
                self.assertEqual({state["worker_id"] for state in states},
                                 set(range(4)))
                self.assertTrue(all(not state["stopped"] for state in states))
                if all(not state["running"] for state in states):
                    break
            else:
                self.fail("listener close left a sampling timer enabled")
            self.assertEqual(len(run.proxy.snapshot()), 4)
            self.assertEqual(self.db("SELECT count(*) FROM pg_stat_activity "
                f"WHERE datname = '{self.database}' AND usename = 'conduit'"),
                "24")
            run.send("tags 1 0")
            run.result(1)
            run.csv_fence()
            before = len(run.csv.rows)
            run.csv_fence()
            self.assertEqual(len(run.csv.rows), before)
            run.send("quit")
            self.assertEqual(run.process.wait(timeout=5), 0)

    def routing_connect(self, port):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            connection = http.client.HTTPConnection("127.0.0.1", port,
                                                     timeout=5)
            try:
                connection.connect()
                return connection
            except ConnectionRefusedError:
                connection.close()
                time.sleep(0.01)
        self.fail("HTTP listener did not become ready")

    def test_four_workers_config_is_per_worker(self):
        with self.routing_server(2, readiness=False) as run:
            port, proxy, metrics, server = run
            self.assertEqual(len(proxy.snapshot()), 8)
            with ExitStack() as cleanup:
                connections = [self.routing_connect(port) for _ in range(4)]
                for connection in connections:
                    cleanup.callback(connection.close)
                routes = self.routing_pool_routes(
                    self.database, connections, proxy, [2] * 4)
                self.assertEqual([len(route) for route in routes], [2] * 4)
                for index, route in enumerate(routes):
                    for other in routes[index + 1:]:
                        self.assertTrue(route.isdisjoint(other))
                self.assertEqual(set.union(*routes), set(range(8)))

    def test_four_workers_round_robin_accepts(self):
        with self.routing_server(1, readiness=False) as run, ExitStack() as cleanup:
            port, proxy, metrics, server = run
            routes = []
            for _ in range(8):
                connection = self.routing_connect(port)
                cleanup.callback(connection.close)
                routes.append(self.routing_tags(connection, proxy))
                if _diagnostic_mode() and len(routes) == 1:
                    self.routing_wait_pool(metrics, server,
                        lambda r: r["counters"][0] == 1, worker_id=0)
                    for worker in range(1, 4):
                        self.routing_wait_pool(metrics, server,
                            lambda r: r["counters"][0] == 0, worker_id=worker)
            self.assertEqual(len(set(routes[:4])), 4)
            self.assertEqual(routes, routes[:4] * 2)
            if _diagnostic_mode():
                for worker_id in range(4):
                    state = self.routing_wait_pool(metrics, server,
                        lambda r: r["counters"][0] == 2, worker_id)
                    self.assertEqual(state["gauges"][6], 1)

    def test_four_workers_keepalive_is_sticky(self):
        title = "sticky-" + uuid.uuid4().hex
        token = self.token(self.author())
        status, created = self.request("POST", "/api/articles",
                                       self.article(title, []), token)
        self.assertEqual(status, 201)
        slug = created["article"]["slug"]
        with self.routing_server(1, readiness=False) as run, ExitStack() as cleanup:
            port, proxy, _, _ = run
            connections = [self.routing_connect(port) for _ in range(4)]
            for connection in connections:
                cleanup.callback(connection.close)
            routes = [self.routing_tags(connection, proxy)
                      for connection in connections]
            self.assertEqual(len(set(routes)), 4)
            for _ in range(3):
                for connection, route in zip(connections, routes):
                    self.assertEqual(self.routing_tags(connection, proxy), route)
            for connection, route in zip(connections, routes):
                content = "sticky " + uuid.uuid4().hex
                status, body, changes = self.routing_request(
                    connection, proxy, "PUT", "/api/articles/" + slug,
                    {"article": {"body": content}}, token)
                self.assertEqual(status, 200)
                self.assertEqual(body["article"]["body"], content)
                self.assertEqual(set(changes), {route})
                self.assertEqual(changes[route], [b"article_update_input",
                    b"article_update", b"article_full_by_id"])

    def test_four_workers_progress_independently(self):
        with self.routing_server(1, readiness=False) as run, ExitStack() as cleanup:
            port, proxy, _, _ = run
            first = self.routing_connect(port)
            cleanup.callback(first.close)
            others = [self.routing_connect(port) for _ in range(3)]
            for connection in others:
                cleanup.callback(connection.close)
            first_route = self.routing_tags(first, proxy)
            routes = [self.routing_tags(connection, proxy)
                      for connection in others]
            self.assertEqual(len(set([first_route] + routes)), 4)
            gate = proxy.hold_frame(b"Z", first_route, timeout=60)
            cleanup.callback(gate.release.set)
            first.request("GET", "/api/tags")
            self.assertTrue(gate.reached.wait(5), "first worker was not held")
            for connection, route in zip(others, routes):
                self.assertEqual(self.routing_tags(connection, proxy), route)
            self.assertTrue(gate.reached.is_set())
            self.assertFalse(gate.release.is_set())
            gate.release.set()
            response = first.getresponse()
            self.assertEqual(response.status, 200)
            self.assertIsInstance(json.loads(response.read())["tags"], list)
            proxy.assert_healthy()

    def test_four_workers_close_cancels_only_assigned_work(self):
        if not _diagnostic_mode():
            self.skipTest("diagnostic cancellation observation required")
        with self.routing_server(1, readiness=False) as run, ExitStack() as cleanup:
            port, proxy, metrics, server = run
            first = self.routing_connect(port)
            second = self.routing_connect(port)
            cleanup.callback(first.close)
            cleanup.callback(second.close)
            routes = [self.routing_tags(connection, proxy)
                      for connection in (first, second)]
            self.assertNotEqual(*routes)
            gates = [proxy.hold_frame(b"Z", route, timeout=60)
                     for route in routes]
            for gate in gates:
                cleanup.callback(gate.release.set)
            held_deadline = time.monotonic() + 40
            for connection in (first, second):
                connection.request("GET", "/api/tags")
            for gate in gates:
                self.assertTrue(gate.reached.wait(5), "query was not held")
            first.sock.sendall(b"GET /api/tags HTTP/1.1\r\n"
                               b"Host: localhost\r\n\r\n")
            self.routing_wait_pool(metrics, server,
                lambda r: r["gauges"][:2] == [1, 1], worker_id=0,
                deadline=held_deadline)
            first.sock.shutdown(socket.SHUT_RDWR)
            first.close()
            detached = self.routing_wait_pool(metrics, server,
                lambda r: r["counters"][6] == 1, worker_id=0,
                deadline=held_deadline)
            survivor = self.routing_wait_pool(metrics, server,
                lambda r: r["gauges"][1] == 1, worker_id=1,
                deadline=held_deadline)
            self.assertLess(time.monotonic(), held_deadline)
            self.assertEqual(detached["gauges"][1], 1)
            self.assertEqual(detached["gauges"][0], 1)
            self.assertEqual(survivor["counters"][6], 0)
            self.assertTrue(all(not gate.release.is_set() for gate in gates))
            proxy.assert_healthy()
            gates[1].release.set()
            response = second.getresponse()
            self.assertEqual(response.status, 200)
            self.assertIsInstance(json.loads(response.read())["tags"], list)
            self.assertEqual(self.routing_tags(second, proxy), routes[1])
            gates[0].release.set()
            self.routing_wait_pool(metrics, server,
                lambda r: r["counters"][2] == 3 and r["gauges"][:2] == [0, 0],
                worker_id=0)
            self.assertEqual(self.routing_binds(proxy)[routes[0]],
                             [b"tags"] * 3)
            proxy.assert_healthy()

    def test_four_workers_listen_failure_closes_all(self):
        proxy = ProtocolProxy(self.proxy.database_host,
                              self.proxy.database_port)
        try:
            with socket.socket() as occupied, tempfile.TemporaryFile() as metrics:
                occupied.bind(("127.0.0.1", 0))
                occupied.listen()
                env = self.server_env | {
                    "PORT": str(occupied.getsockname()[1]),
                    "CONDUIT_TEST_POOL_SIZE": "1",
                    "DATABASE_URL": "postgres://conduit:conduit@127.0.0.1:"
                    f"{proxy.server_address[1]}/{self.database}"}
                result = subprocess.run(
                    [str(_executable()), "--test-http", "--db-worker-count=4"],
                    env=env,
                    stdout=metrics, stderr=subprocess.PIPE, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                with proxy.lock:
                    frontends = list(proxy.frontends)
                for frontend in frontends:
                    try:
                        frontend.settimeout(2)
                        self.assertEqual(frontend.recv(1), b"")
                    except socket.timeout:
                        self.fail("failed listener left a database socket open")
                    except OSError:
                        pass
                if _diagnostic_mode():
                    _check_metric_output(metrics)
        finally:
            proxy.stop()

    def test_four_workers_diagnostic_identity(self):
        if not _diagnostic_mode():
            self.skipTest("diagnostic variant only")
        with self.routing_server(1, readiness=False) as run, ExitStack() as cleanup:
            port, proxy, metrics, server = run
            for _ in range(4):
                connection = self.routing_connect(port)
                cleanup.callback(connection.close)
                self.routing_tags(connection, proxy)
            for worker_id in range(4):
                self.routing_wait_pool(metrics, server,
                    lambda r: r["counters"][0] == 1, worker_id)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                data = os.pread(metrics.fileno(),
                                os.fstat(metrics.fileno()).st_size, 0)
                data = data[:data.rfind(b"\n") + 1]
                try:
                    _check_metric_output(io.BytesIO(data), require_activity=True)
                    break
                except AssertionError:
                    time.sleep(0.05)
            else:
                _check_metric_output(io.BytesIO(data), require_activity=True)
            proxy.reject_new = True
            for index in range(4):
                proxy.drop_backend(index)
            deadline = time.monotonic() + 35
            missing_workers = set()
            while time.monotonic() < deadline:
                data = os.pread(metrics.fileno(),
                                os.fstat(metrics.fileno()).st_size, 0)
                data = data[:data.rfind(b"\n") + 1]
                missing_workers = {record["worker_id"] for record in
                    _metric_records(io.BytesIO(data))
                    if record.get("missing") and
                    record.get("reason") == "unavailable"}
                if missing_workers == set(range(4)):
                    break
                self.assertIsNone(server.poll())
                time.sleep(0.05)
            self.assertEqual(missing_workers, set(range(4)))
            _check_metric_output(io.BytesIO(data), require_activity=True)

    def routing_request(self, connection, proxy, method="GET", path="/api/tags",
                        body=None, token=None):
        before = self.routing_binds(proxy)
        original_socket = connection.sock
        headers = {"Content-Type": "application/json"}
        if token is not None:
            headers["Authorization"] = "Token " + token
        connection.request(method, path,
                           None if body is None else json.dumps(body), headers)
        response = connection.getresponse()
        data = response.read()
        self.assertIsNotNone(connection.sock)
        if original_socket is not None:
            self.assertIs(connection.sock, original_socket)
        after = self.routing_binds(proxy)
        self.assertEqual(len(after), len(before))
        changes = {index: names[len(before[index]):]
                   for index, names in enumerate(after)
                   if names != before[index]}
        return response.status, json.loads(data) if data else None, changes

    def routing_tags(self, connection, proxy):
        status, body, changes = self.routing_request(connection, proxy)
        self.assertEqual(status, 200)
        self.assertIsInstance(body["tags"], list)
        self.assertEqual(len(changes), 1)
        worker, names = next(iter(changes.items()))
        self.assertEqual(names, [b"tags"])
        return worker

    def test_no_sql_request_sends_no_database_query(self):
        with self.routing_server(3) as run:
            port, proxy, _, _ = run
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            try:
                for path, expected in (("/api/user", 401),
                                       ("/missing-routing-test", 404)):
                    status, body, changes = self.routing_request(
                        connection, proxy, path=path)
                    self.assertEqual(status, expected)
                    self.assertIsInstance(body["errors"]["body"], list)
                    self.assertEqual(changes, {})
                self.routing_tags(connection, proxy)
            finally:
                connection.close()

    def test_operation_followups_use_available_connections(self):
        title = "routing-" + uuid.uuid4().hex
        token = self.token(self.author())
        status, created = self.request("POST", "/api/articles",
                                       self.article(title, []), token)
        self.assertEqual(status, 201)
        slug = created["article"]["slug"]
        with self.routing_server(3) as run:
            port, proxy, _, _ = run
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            try:
                self.routing_tags(connection, proxy)
                content = "routing body " + uuid.uuid4().hex
                status, body, changes = self.routing_request(
                    connection, proxy, "PUT", "/api/articles/" + slug,
                    {"article": {"body": content}}, token)
                self.assertEqual(status, 200)
                self.assertEqual(body["article"]["body"], content)
                self.assertEqual(body["article"]["slug"], slug)
                names = [name for commands in changes.values() for name in commands]
                self.assertCountEqual(names, [b"article_update_input",
                                             b"article_update",
                                             b"article_full_by_id"])

            finally:
                connection.close()

    def routing_wait_pool(self, metrics, server, predicate, worker_id=0,
                          deadline=None):
        if deadline is None:
            deadline = time.monotonic() + 25
        latest = None
        while time.monotonic() < deadline:
            self.assertIsNone(server.poll())
            data = os.pread(metrics.fileno(),
                                        os.fstat(metrics.fileno()).st_size, 0)
            end = data.rfind(b"\n")
            for record in _metric_records(io.BytesIO(data[:end + 1])):
                if (record.get("owner") == 1 and not record.get("missing") and
                        record.get("worker_id") == worker_id):
                    latest = record
            if latest is not None and predicate(latest):
                return latest
            time.sleep(0.05)
        self.fail("pool state timed out: " + repr(latest))

    def routing_read_response(self, stream):
        status = stream.readline().split()
        self.assertGreaterEqual(len(status), 2)
        headers = {}
        while (line := stream.readline()) != b"\r\n":
            self.assertTrue(line)
            name, value = line.split(b":", 1)
            headers[name.lower()] = value.strip()
        size = int(headers[b"content-length"])
        body = stream.read(size)
        self.assertEqual(len(body), size)
        return int(status[1]), json.loads(body) if body else None

    def test_http_disconnect_detaches_shared_queue_preserves_other_client(self):
        if not _diagnostic_mode():
            self.skipTest("diagnostic variant only")
        count = 3
        with self.routing_server(count) as run, ExitStack() as cleanup:
            port, proxy, metrics, server = run
            baseline = self.routing_wait_pool(metrics, server,
                lambda r: r["counters"][0] == 1 and r["gauges"][1] == 0)
            with SQLSession(self.database) as holder:
                holder.execute("BEGIN; LOCK TABLE tags IN ACCESS EXCLUSIVE MODE;")
                for _ in range(3):
                    with socket.create_connection(("127.0.0.1", port), 10):
                        pass
                abandoned = socket.create_connection(("127.0.0.1", port), 10)
                cleanup.callback(abandoned.close)
                request = b"GET /api/tags HTTP/1.1\r\nHost: localhost\r\n\r\n"
                abandoned.sendall(request * (count + 1))
                self.routing_wait_pool(metrics, server,
                    lambda r: r["counters"][0] == 5 and r["gauges"][:2] == [1, 3])
                for _ in range(3):
                    with socket.create_connection(("127.0.0.1", port), 10):
                        pass
                survivor = socket.create_connection(("127.0.0.1", port), 10)
                cleanup.callback(survivor.close)
                survivor.sendall(request * count)
                self.routing_wait_pool(metrics, server,
                    lambda r: r["counters"][0] == 8 and r["gauges"][:2] == [4, 3])
                abandoned.shutdown(socket.SHUT_RDWR)
                abandoned.close()
                detached = self.routing_wait_pool(metrics, server,
                    lambda r: r["counters"][6] - baseline["counters"][6] == 1)
                self.assertEqual(detached["gauges"][:2], [4, 3])
                holder.execute("ROLLBACK;")
                stream = survivor.makefile("rb")
                cleanup.callback(stream.close)
                for _ in range(count):
                    status, body = self.routing_read_response(stream)
                    self.assertEqual(status, 200)
                    self.assertIsInstance(body["tags"], list)
                survivor.sendall(request)
                status, body = self.routing_read_response(stream)
                self.assertEqual(status, 200)
                self.assertIsInstance(body["tags"], list)
                final = self.routing_wait_pool(metrics, server,
                    lambda r: r["counters"][0] == 9 and r["gauges"][:2] == [0, 0])
                self.assertEqual(final["counters"][2], 9)
                self.assertEqual(final["counters"][5] - baseline["counters"][5], 4)

    def test_shared_pool_uses_all_available_connections(self):
        with self.routing_server(5, readiness=False) as run, ExitStack() as cleanup:
            port, proxy, _, _ = run
            connections = [self.routing_connect(port) for _ in range(4)]
            for connection in connections:
                cleanup.callback(connection.close)
            routes = self.routing_pool_routes(
                self.database, connections, proxy, [5] * 4)
            self.assertEqual([len(route) for route in routes], [5] * 4)
            self.assertEqual(set.union(*routes), set(range(20)))
            proxy.assert_healthy()

    def test_named_rollback_after_failed_transaction(self):
        before = len(self.proxy.snapshot())
        executable = _executable()
        result = subprocess.run([str(executable), "--test-named-rollback"],
                                env=self.server_env | {
                                    "CONDUIT_TEST_POOL_SIZE": "1"},
                                capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, _failure_output(result.stderr))
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

    def test_database_hostname_connects(self):
        env = self.server_env.copy()
        env["DATABASE_URL"] = env["DATABASE_URL"].replace(
            "@127.0.0.1:", "@localhost:")
        executable = _executable()
        result = subprocess.run([str(executable), "--test-named-rollback"],
                                env=env, capture_output=True, text=True,
                                timeout=10)
        self.assertEqual(result.returncode, 0, _failure_output(result.stderr))
        self.assertEqual(result.stdout.strip(),
                         "named rollback after failed transaction passed")

    def test_dns_resolution_does_not_block_scheduler(self):
        source = Path(__file__).with_name("slow_dns.c")
        with tempfile.TemporaryDirectory() as directory:
            preload = Path(directory) / "slow_dns.so"
            subprocess.run(["cc", "-shared", "-fPIC", str(source), "-ldl",
                            "-o", str(preload)], check=True)
            env = self.server_env.copy()
            env["DATABASE_URL"] = env["DATABASE_URL"].replace(
                "@127.0.0.1:", "@localhost:")
            env["LD_PRELOAD"] = str(preload)
            marker = Path(directory) / "dns-entered"
            release = Path(directory) / "dns-release"
            env["CONDUIT_DNS_MARKER"] = str(marker)
            env["CONDUIT_DNS_RELEASE"] = str(release)
            executable = _executable()
            process = subprocess.Popen(
                [str(executable), "--ponymaxthreads=1", "--test-dns-progress"],
                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True)
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stderr, selectors.EVENT_READ)
                    self.assertTrue(selector.select(5),
                                    "delayed DNS hook was not entered")
                self.assertTrue(
                    process.stderr.readline().strip() == "DNS delay entered",
                    "DNS delay marker absent")
                self.assertTrue(marker.exists())
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    self.assertTrue(selector.select(5),
                                    "DNS resolution blocked the scheduler")
                self.assertEqual(process.stdout.readline().strip(),
                                 "scheduler progressed")
                release.touch()
                _, errors = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, _failure_output(errors))
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_session_rejects_truncated_strings_and_preserves_status(self):
        executable = _executable()
        result = subprocess.run([str(executable), "--test-session-boundary"],
                                env=self.server_env | {
                                    "CONDUIT_TEST_POOL_SIZE": "invalid"},
                                capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, _failure_output(result.stderr))
        self.assertEqual(result.stdout.strip(), "session boundaries passed")

    def test_session_shutdown_settles_accepted_commands(self):
        executable = _executable()
        result = subprocess.run([str(executable), "--test-session-shutdown"],
                                env=self.server_env | {
                                    "CONDUIT_TEST_POOL_SIZE": "1"},
                                capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, _failure_output(result.stderr))
        self.assertEqual(result.stdout.strip(),
                         "session shutdown settled commands")

    def test_startup_shutdown_settles_accepted_commands(self):
        source = Path(__file__).with_name("slow_dns.c")
        with tempfile.TemporaryDirectory() as directory:
            preload = Path(directory) / "slow_dns.so"
            subprocess.run(["cc", "-shared", "-fPIC", str(source), "-ldl",
                            "-o", str(preload)], check=True)
            env = self.server_env.copy()
            env["DATABASE_URL"] = env["DATABASE_URL"].replace(
                "@127.0.0.1:", "@localhost:")
            env["LD_PRELOAD"] = str(preload)
            marker = Path(directory) / "dns-entered"
            release = Path(directory) / "dns-release"
            env["CONDUIT_DNS_MARKER"] = str(marker)
            env["CONDUIT_DNS_RELEASE"] = str(release)
            executable = _executable()
            process = subprocess.Popen([str(executable),
                                        "--test-startup-shutdown"], env=env,
                                       stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    self.assertTrue(selector.select(5),
                                    "shutdown did not finish during DNS")
                output = process.stdout.readline().strip()
                self.assertTrue(marker.exists(),
                                "delayed DNS hook was not entered")
                release.touch()
                _, errors = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, _failure_output(errors))
                self.assertTrue("DNS delay entered" in errors,
                                "DNS delay marker absent")
                self.assertEqual(output,
                                 "startup shutdown settled commands")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_connection_fields_reject_nul(self):
        executable = _executable()
        result = subprocess.run([str(executable), "--test-connection-nul"],
                                env=self.server_env | {
                                    "CONDUIT_TEST_POOL_SIZE": "1"},
                                capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, _failure_output(result.stderr))
        self.assertEqual(result.stdout.strip(),
                         "connection fields rejected NUL")

    def test_result_shapes_reject_nested_arrays_and_keep_infinities(self):
        executable = _executable()
        result = subprocess.run([str(executable), "--test-result-shapes"],
                                env=self.server_env | {
                                    "CONDUIT_TEST_POOL_SIZE": "1"},
                                capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, _failure_output(result.stderr))
        self.assertEqual(result.stdout.strip(), "result shapes passed")

    @contextmanager
    def query_storage_library(self):
        with tempfile.TemporaryDirectory(
                prefix="conduit-query-storage-") as temp:
            library = Path(temp) / "control.so"
            source = Path(__file__).with_name("query_transport_control.c")
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                            "-shared", "-fPIC", "-I/usr/include/postgresql",
                            str(source), "-o", str(library), "-ldl",
                            "-pthread"],
                           check=True, capture_output=True, timeout=30)
            yield library

    def query_storage_case(self, mode, api, count, library=None,
                           control="clear", expect_success=True):
        scenarios = {"send0": 1, "flush-error": 2, "writing": 3,
                     "replacement": 4, "reject-writing": 5,
                     "reject-reading": 6, "pending": 7, "root": 8,
                     "validate": 9, "close-failure": 9, "close-result": 10,
                     "close-completion": 12}
        scenario = scenarios.get(mode, 0)
        expressions = []
        for p in range(1, count + 1):
            parameter = f"${p}::text"
            value = parameter
            if mode in ("pending", "root") and p == 1:
                value = f"md5({parameter})"
            expressions += [value, f"({parameter}) IS NULL",
                            f"length({parameter})"]
        marker = "storage_selected" if api == "named" else (
            "SELECT " + ", ".join(expressions) + " /*storage*/")
        host = os.environ.get("PGHOST", "127.0.0.1")
        if host.startswith("/"):
            host = "127.0.0.1"
        port = os.environ.get("PGPORT", "5432")
        env = self.server_env | {
            "DATABASE_URL": f"postgres://conduit:conduit@{host}:"
                            f"{port}/{self.database}",
            "CONDUIT_QUERY_CASE": mode, "CONDUIT_QUERY_API": api,
            "CONDUIT_QUERY_COUNT": str(count),
            "CONDUIT_QUERY_SCENARIO": str(scenario),
            "CONDUIT_QUERY_MARKER": marker,
            "CONDUIT_QUERY_ROOT_CONTROL": control}
        env.pop("LD_PRELOAD", None)
        if library is not None:
            env["LD_PRELOAD"] = str(library)
        result = subprocess.run(
            [str(_executable()), "--test-query-storage", "--ponymaxthreads=1"],
            env=env, capture_output=True, text=True,
            timeout=30 if mode == "pending" else 10)
        if not expect_success:
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("query storage passed", result.stdout)
            return []
        self.assertEqual(result.returncode, 0, (mode, api, count,
                         _failure_output(result.stderr)))
        lines = result.stdout.splitlines()
        self.assertEqual(lines[-1], "query storage passed " + mode)
        ledger = []
        for index, line in enumerate(lines[:-1]):
            parts = line.split()
            self.assertEqual(len(parts), 6)
            self.assertEqual(parts[0], "ledger")
            values = list(map(int, parts[1:]))
            self.assertEqual(values[0], index)
            self.assertEqual(values[1], 1)
            self.assertIn(values[2], (1, 2, 3, 4))
            self.assertIn(values[3], (0, 1))
            self.assertNotEqual(values[4], -(1 << 63))
            ledger.append(tuple(values[2:]))
        self.assertLessEqual(len(ledger), 256)
        return ledger

    def test_query_storage_native_control(self):
        self.query_storage_case("send0", "plain", 3, expect_success=False)
        with self.query_storage_library() as library:
            for api in ("plain", "named"):
                for mode in ("boundary", "fresh", "property"):
                    with self.subTest(api=api, mode=mode):
                        self.assertEqual(
                            self.query_storage_case(mode, api, 3), [])
                for count in (3, 9):
                    for mode in ("send0", "flush-error", "writing",
                                 "replacement", "reject-writing",
                                 "reject-reading", "validate", "close-result",
                                 "close-failure", "close-completion"):
                        with self.subTest(api=api, count=count, mode=mode):
                            ledger = self.query_storage_case(mode, api, count,
                                                             library)
                            send = 1 if api == "plain" else 2
                            if mode in ("validate", "close-failure"):
                                self.assertEqual(ledger, [])
                                continue
                            self.assertEqual(ledger[0],
                                             (send, int(mode == "send0"),
                                              int(mode != "send0")))
                            flushes = ledger[1:]
                            if mode == "send0":
                                self.assertEqual(flushes, [])
                            elif mode == "flush-error":
                                self.assertEqual(flushes, [(3, 1, -1)])
                            elif mode in ("writing", "replacement"):
                                scripted = 2 if mode == "writing" else 1
                                self.assertEqual(flushes[:scripted],
                                                 [(3, 1, 1)] * scripted)
                                self.assertEqual(flushes[-1], (3, 0, 0))
                                self.assertTrue(all(
                                    row == (3, 0, 1)
                                    for row in flushes[scripted:-1]))
                            elif mode == "reject-writing":
                                self.assertEqual(flushes, [(3, 1, 1)])
                            elif mode == "reject-reading":
                                self.assertEqual(flushes[0], (3, 1, 1))
                                self.assertEqual(flushes[-1], (3, 0, 0))
                            else:
                                self.assertEqual(flushes[-1], (3, 0, 0))

    def test_query_storage_real_pending(self):
        with self.query_storage_library() as library:
            for api in ("plain", "named"):
                for count in (3, 9):
                    with self.subTest(api=api, count=count):
                        ledger = self.query_storage_case("pending", api, count,
                                                         library)
                        send = 1 if api == "plain" else 2
                        self.assertEqual(ledger[0][:2], (4, 0))
                        self.assertEqual(ledger[1], (send, 0, 1))
                        self.assertIn((3, 0, 1), ledger[2:],
                                      "actual pending precondition unmet")
                        self.assertEqual(ledger[-1], (3, 0, 0))
                        self.assertTrue(all(row in ((3, 0, 1), (3, 0, 0))
                                            for row in ledger[2:]))

    def test_query_storage_root_release(self):
        with self.query_storage_library() as library:
            for control in ("clear", "held", "never"):
                with self.subTest(control=control):
                    ledger = self.query_storage_case("root", "plain", 1,
                                                     library, control)
                    self.assertEqual(ledger, [(1, 1, 0)])

    def scalar_decode_case(self, oid, payload, kind, value="", atomic=None,
                           row=0, column=0):
        host = os.environ.get("PGHOST", "127.0.0.1")
        if host.startswith("/"):
            host = "127.0.0.1"
        proxy = ProtocolProxy(host, os.environ.get("PGPORT", "5432"), capacity=2)
        try:
            proxy.replace_scalar_field(0, row, column, oid, payload)
            env = self.server_env | {
                "DATABASE_URL": "postgres://conduit:conduit@127.0.0.1:"
                                f"{proxy.server_address[1]}/{self.database}",
                "CONDUIT_TEST_DECODE_OID": str(oid),
                "CONDUIT_TEST_DECODE_KIND": kind,
                "CONDUIT_TEST_DECODE_VALUE": str(value)}
            flag = "--test-decode-scalar"
            if atomic is not None:
                flag = "--test-decode-atomic"
                env["CONDUIT_TEST_DECODE_ATOMIC_CASE"] = atomic
            result = subprocess.run(
                [str(_executable()), flag, "--ponymaxthreads=2"], env=env,
                capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, _failure_output(result.stderr))
            self.assertEqual(result.stdout.strip(),
                             "scalar decoding and recovery passed")
            proxy.assert_healthy()
            receipts = proxy.scalar_mutations()
            self.assertEqual(len(receipts), 1)
            receipt = receipts[0]
            self.assertEqual(receipt["connection"], 0)
            self.assertEqual(receipt["row"], row)
            self.assertEqual(receipt["column"], column)
            self.assertEqual(receipt["oid"], oid)
            before, after = receipt["before"], receipt["after"]
            self.assertEqual(len(after), len(before))
            self.assertEqual(after[column], payload)
            for index, original in enumerate(before):
                if index != column:
                    self.assertEqual(after[index], original)
            for name, fields in (("old_length", before), ("new_length", after)):
                length = 6 + sum(4 + (len(v) if v is not None else 0)
                                 for v in fields)
                self.assertEqual(receipt[name], length)
            self.assertEqual(len(receipt["preceding"]), row)
            if atomic is not None:
                self.assertEqual(before[0], b"first" if row == 0 else b"second")
                self.assertIsNone(before[1])
                original = b"11" if oid == 20 else b"2000-01-01 00:00:00"
                self.assertEqual(before[2], original)
                if row == 1:
                    self.assertEqual(receipt["preceding"][0],
                                     (b"first", None, original))
        finally:
            proxy.stop()

    def test_decode_scalar_payload_compatibility(self):
        for oid in (20, 21, 23):
            kind = "i64" if oid == 20 else "i32"
            width = 64 if oid == 20 else 32
            minimum, maximum = -(1 << (width - 1)), (1 << (width - 1)) - 1
            cases = [(b"0", 0), (b"-0", 0), (b"1", 1), (b"-1", -1),
                     (b"00012", 12), (str(minimum).encode(), minimum),
                     (str(maximum).encode(), maximum), (b"0x7f", 127),
                     (b"-0b10", -2), (b"1_2", 12), (b"12_", 12),
                     (b"_12", 12), (b"12\0x", 12), (b"-0b10\0x", -2)]
            if oid == 20:
                cases += [(b"2147483648", 2147483648),
                          (b"-2147483649", -2147483649)]
            if oid == 21:
                cases.append((b"32768", 32768))
            for payload, expected in cases:
                with self.subTest(oid=oid, payload=payload, expected=expected):
                    self.scalar_decode_case(oid, payload, kind, expected)
            invalid = [b"", b"-", b"+1", b" 1", b"1 ", b"12x", b"0x",
                       b"_", b"\0", str(minimum - 1).encode(),
                       str(maximum + 1).encode(), b"9223372036854775808",
                       b"-9223372036854775809"]
            for payload in invalid:
                with self.subTest(oid=oid, payload=payload, outcome="DataError"):
                    self.scalar_decode_case(oid, payload, "error")
            with self.subTest(oid=oid, payload=None):
                self.scalar_decode_case(oid, None, "none")
        for payload, expected in ((b"t", "true"), (b"f", "false"),
                                  (b"", "false"), (b"true", "false"),
                                  (b"T", "false"), (b"t\0x", "true")):
            with self.subTest(oid=16, payload=payload):
                self.scalar_decode_case(16, payload, "bool", expected)
        self.scalar_decode_case(16, None, "none")
        for oid in (1114, 1184):
            cases = [(b"infinity", (1 << 63) - 1),
                     (b"-infinity", -(1 << 63)),
                     (b"infinity\0x", (1 << 63) - 1),
                     (b"2000-01-01 00:00:00.1", 100000),
                     (b"2000-01-01 00:00:00.1+00", 100000),
                     (b"2000-01-01 00:00:00.1+00:00", 100000)]
            for payload, expected in cases:
                with self.subTest(oid=oid, payload=payload, expected=expected):
                    self.scalar_decode_case(oid, payload, "timestamp", expected)
            for payload in (b"", b"not-a-timestamp", b"infinityx",
                            b"2000-01-01 00:00:00.1234567"):
                with self.subTest(oid=oid, payload=payload, outcome="DataError"):
                    self.scalar_decode_case(oid, payload, "error")
            self.scalar_decode_case(oid, None, "none")

    def test_decode_scalar_failure_is_atomic(self):
        for family, oid, payload in (("integer", 20, b"12x"),
                                     ("timestamp", 1114, b"not-a-timestamp")):
            for placement, row in (("late-column", 0), ("late-row", 1)):
                case = family + "-" + placement
                with self.subTest(case=case):
                    self.scalar_decode_case(oid, payload, "error", atomic=case,
                                            row=row, column=2)

    def test_deep_rejection_queue_drains(self):
        executable = _executable()
        result = subprocess.run([str(executable), "--test-queue-drain"],
                                env=self.server_env | {
                                    "CONDUIT_TEST_POOL_SIZE": "1"},
                                capture_output=True,
                                text=True, timeout=30)
        self.assertEqual(result.returncode, 0, _failure_output(result.stderr))
        self.assertEqual(result.stdout.strip(), "deep rejection queue drained")

    def test_database_url_rejects_nul(self):
        env = self.server_env.copy()
        env["DATABASE_URL"] = env["DATABASE_URL"].replace(
            "/" + self.database, "/%00")
        executable = _executable()
        result = subprocess.run([str(executable), "--test-named-rollback"],
                                env=env, capture_output=True, text=True,
                                timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertTrue("Invalid configuration" in result.stderr,
                        "configuration error absent")

    def test_idle_notice_does_not_complete_query(self):
        before = len(self.proxy.snapshot())
        self.assertGreater(self.proxy.send_notice(), 0)
        time.sleep(1.2)
        self.assertEqual(self.request("GET", "/api/tags")[0], 200)
        self.assertEqual(len(self.proxy.snapshot()), before)

    def test_notice_does_not_complete_inflight_query(self):
        before = len(self.proxy.snapshot())
        self.proxy.hold_command_complete_after(0)
        try:
            with ThreadPoolExecutor(max_workers=1) as pool:
                request = pool.submit(self.request, "GET", "/api/tags")
                self.assertTrue(self.proxy.command_complete_held.wait(5))
                with self.proxy.lock:
                    frontend = self.proxy.held_frontend
                offset = os.fstat(self.server_log.fileno()).st_size
                self.assertGreater(self.proxy.send_notice(frontend), 0)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    size = os.fstat(self.server_log.fileno()).st_size
                    if b"idle notice" in os.pread(
                            self.server_log.fileno(), size - offset, offset):
                        break
                    time.sleep(0.01)
                else:
                    self.fail("libpq did not consume the notice")
                self.assertFalse(request.done())
                self.proxy.release_command_complete()
                self.assertEqual(request.result(timeout=5)[0], 200)
        finally:
            self.proxy.release_command_complete(abort=True)
        self.assertEqual(len(self.proxy.snapshot()), before)

    def test_presend_data_error_keeps_worker_query_order(self):
        before = len(self.proxy.snapshot())
        executable = _executable()
        result = subprocess.run([str(executable), "--test-worker-data-error"],
                                env=self.server_env | {
                                    "CONDUIT_TEST_POOL_SIZE": "1"},
                                capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, _failure_output(result.stderr))
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
        executable = _executable()
        result = subprocess.run([str(executable), "--test-worker-decode-error"],
                                env=self.server_env | {
                                    "CONDUIT_TEST_POOL_SIZE": "1"},
                                capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, _failure_output(result.stderr))
        self.assertEqual(result.stdout.strip(),
                         "worker decode error followed by query passed")
        sessions = self.proxy.snapshot()[before:]
        self.assertEqual(len(sessions), 1)
        bound = [payload.split(b"\0", 2)[1] for kind, payload
                 in sessions[0] if kind == b"B"]
        self.assertEqual(bound, [b"tags", b"current_user"])

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
        executable = _executable()
        before = len(self.proxy.snapshot())
        self.proxy.hold_command_complete_after(1)
        process = subprocess.Popen(
            [str(executable), "--test-worker-overlap"],
            env=self.server_env | {"CONDUIT_TEST_POOL_SIZE": "1"},
            stdout=subprocess.PIPE,
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
            self.assertEqual(process.returncode, 0, _failure_output(stderr))
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

    def test_explicit_worker_close_fails_each_submitted_job(self):
        executable = _executable()
        self.proxy.hold_command_complete_after(1)
        process = subprocess.Popen(
            [str(executable), "--test-worker-close-drain"],
            env=self.server_env | {"CONDUIT_TEST_POOL_SIZE": "1"},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1)
        try:
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, _failure_output(stderr))
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

    def test_private_worker_count_configuration(self):
        executable = _executable()
        for count in ("", "invalid", "0", "96"):
            with self.subTest(count=count):
                env = self.server_env.copy()
                env["CONDUIT_TEST_POOL_SIZE"] = count
                result = subprocess.run(
                    [str(executable), "--test-http", "--db-worker-count=4"],
                    env=env,
                                        capture_output=True, text=True,
                                        timeout=5)
                self.assertEqual(result.returncode, 1)
                self.assertTrue("CONDUIT_TEST_POOL_SIZE" in result.stderr,
                                "worker-count error absent")

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
                CONDUIT_TEST_POOL_SIZE="1")
            executable = _executable()
            with tempfile.TemporaryFile(mode="w+b") as log, \
                 tempfile.TemporaryFile(mode="w+b") as metrics:
                server = subprocess.Popen(
                    [str(executable), "--test-http", "--db-worker-count=4"],
                    env=env,
                                          stdout=(metrics if _diagnostic_mode()
                                                  else None),
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
                        self.assertTrue(
                            b"Database prepare tags failed" in diagnostic,
                            "expected prepare failure absent")
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
                    _check_metric_output(metrics if _diagnostic_mode()
                                         else None)
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
                       f"{proxy.server_address[1]}/{database}",
                       CONDUIT_TEST_POOL_SIZE="1")
            executable = _executable()
            process = subprocess.Popen(
                [str(executable), "--test-worker-pending-cancel"], env=env,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, bufsize=1)
            try:
                self.probe_line(process, "pending cancellation accepted")
                self.sql("ALTER TABLE tags_hidden RENAME TO tags", database)
                stdout, stderr = process.communicate(timeout=15)
                self.assertEqual(process.returncode, 0, _failure_output(stderr))
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

    def reconnect_snapshot(self, metrics, server, counter, minimum, after=None):
        deadline = time.monotonic() + 25
        latest = []
        while time.monotonic() < deadline:
            self.assertIsNone(server.poll())
            data = os.pread(metrics.fileno(),
                            os.fstat(metrics.fileno()).st_size, 0)
            data = data[:data.rfind(b"\n") + 1]
            latest = [record for record in _metric_records(io.BytesIO(data))
                      if record.get("owner") in (1, 2) and
                      not record.get("missing")]
            active = {r["worker_id"] for r in latest
                      if r["owner"] == 1 and r["counters"][0] > 0}
            if active:
                self.assertEqual(len(active), 1)
                worker_id = next(iter(active))
                if after is not None:
                    self.assertEqual(worker_id, after["worker_id"])
                transports = {(r["worker_id"], r["slot"], r["request"],
                               r["observed_ns"]): r for r in latest
                              if r["owner"] == 2}
                for worker in reversed(latest):
                    if (worker["owner"] != 1 or
                            worker["worker_id"] != worker_id or
                            worker["request"] <= (after["request"]
                                                  if after else 0) or
                            worker["counters"][counter] < minimum):
                        continue
                    identity = (worker_id, worker["slot"], worker["request"],
                                worker["observed_ns"])
                    if identity in transports:
                        return worker, transports[identity]
            time.sleep(0.05)
        self.fail(f"missing reconnect snapshot for counter {counter} >= "
                  f"{minimum}; latest records: {latest[-8:]}")

    def assert_reconnect_snapshot(self, pair, generation, prepares,
                                  accepted, started, settled, succeeded,
                                  failed, retired, inflight):
        worker, transport = pair
        self.assertEqual(worker["slot"], 0)
        self.assertEqual(transport["generation"], generation)
        for index, expected in zip((0, 1, 2, 7, 8, 9),
                (accepted, started, settled, succeeded, failed, retired)):
            self.assertEqual(worker["counters"][index], expected,
                             f"generation {generation} worker counter {index}")
        self.assertEqual(worker["gauges"][0], 0)
        self.assertEqual(worker["gauges"][1], inflight)
        completed = prepares + 1
        for index, expected in enumerate(
                (completed + inflight, completed, 0, 0)):
            self.assertEqual(transport["counters"][index], expected,
                f"generation {generation} transport counter {index}")
        self.assertEqual(transport["histograms"][6]["count"], completed)

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
                       PORT=str(port), CONDUIT_TEST_POOL_SIZE="1")
            executable = _executable()
            with tempfile.TemporaryFile(mode="w+b") as log, \
                 tempfile.TemporaryFile(mode="w+b") as metrics:
                server = subprocess.Popen(
                    [str(executable), "--test-http", "--db-worker-count=4"],
                    env=env,
                                          stdout=(metrics if _diagnostic_mode()
                                                  else None),
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
                        original_socket = connection.sock
                        self.assertIsNotNone(original_socket)

                        def check_socket():
                            self.assertIs(connection.sock, original_socket)
                            self.assertGreaterEqual(original_socket.fileno(), 0)

                        response = connection.getresponse()
                        self.assertEqual(response.status, 200)
                        self.assertIn("tags", json.loads(response.read()))
                        check_socket()
                        sessions = proxy.snapshot()
                        self.assertEqual(len(sessions), 4)
                        serving = [index for index, session in enumerate(sessions)
                                   if any(kind == b"B" for kind, _ in session)]
                        self.assertEqual(len(serving), 1)
                        if _diagnostic_mode():
                            initial = self.reconnect_snapshot(
                                metrics, server, 2, 1)
                            prepares = sum(kind == b"P" for kind, _
                                           in sessions[serving[0]])
                            self.assert_reconnect_snapshot(initial, 0, prepares,
                                1, 1, 1, 1, 0, 0, 0)
                            check_socket()
                        proxy.drop_backend(serving[0])
                        deadline = time.monotonic() + 5
                        while time.monotonic() < deadline:
                            sessions = proxy.snapshot()
                            if len(sessions) == 5 and sum(kind == b"P"
                                    for kind, _ in sessions[4]) == 30:
                                break
                            time.sleep(0.01)
                        else:
                            self.fail("worker did not prepare a replacement connection")
                        connection.request("GET", "/api/tags")
                        check_socket()
                        response = connection.getresponse()
                        self.assertEqual(response.status, 200)
                        self.assertIn("tags", json.loads(response.read()))
                        check_socket()
                        sessions = proxy.snapshot()
                        self.assertEqual(len(sessions), 5)
                        self.assertEqual(sum(kind == b"P" for kind, _
                                             in sessions[4]), 30)
                        self.assertIn(b"tags", [payload.split(b"\0", 2)[1]
                            for kind, payload in sessions[4] if kind == b"B"])
                        with SQLSession(self.database) as holder:
                            holder.execute("BEGIN; LOCK TABLE tags IN "
                                           "ACCESS EXCLUSIVE MODE;")
                            try:
                                before = self.routing_binds(proxy)
                                connection.request("GET", "/api/tags")
                                check_socket()
                                deadline = time.monotonic() + 5
                                while time.monotonic() < deadline:
                                    after = self.routing_binds(proxy)
                                    changed = [index for index in range(len(after))
                                        if len(after[index]) > len(before[index])]
                                    if changed:
                                        break
                                    time.sleep(0.01)
                                else:
                                    self.fail("blocked query was not submitted")
                                self.assertEqual(changed, [4])
                                if _diagnostic_mode():
                                    blocked = self.reconnect_snapshot(
                                        metrics, server, 1, 3, initial[0])
                                    prepares = sum(kind == b"P" for kind, _
                                                   in proxy.snapshot()[4])
                                    self.assert_reconnect_snapshot(
                                        blocked, 1, prepares,
                                        3, 3, 2, 2, 0, 1, 1)
                                    check_socket()
                                proxy.drop_backend(changed[0])
                                response = connection.getresponse()
                                self.assertEqual(response.status, 500)
                                body = json.loads(response.read())
                                self.assertEqual(body["errors"]["body"],
                                                 ["connection lost"])
                                check_socket()
                            finally:
                                holder.execute("ROLLBACK;")
                        deadline = time.monotonic() + 5
                        while time.monotonic() < deadline:
                            sessions = proxy.snapshot()
                            if len(sessions) == 6 and sum(kind == b"P" for
                                    kind, _ in sessions[5]) == 30:
                                break
                            time.sleep(0.01)
                        self.assertEqual(len(sessions), 6)
                        self.assertFalse(any(kind == b"B" for kind, _
                                             in sessions[5]))
                        connection.request("GET", "/api/tags")
                        check_socket()
                        response = connection.getresponse()
                        self.assertEqual(response.status, 200)
                        self.assertIn("tags", json.loads(response.read()))
                        check_socket()
                        sessions = proxy.snapshot()
                        self.assertIn(b"tags", [payload.split(b"\0", 2)[1]
                            for kind, payload in sessions[5] if kind == b"B"])
                        if _diagnostic_mode():
                            final = self.reconnect_snapshot(
                                metrics, server, 2, 4, blocked[0])
                            prepares = sum(kind == b"P" for kind, _
                                           in sessions[5])
                            self.assert_reconnect_snapshot(final, 2, prepares,
                                4, 4, 4, 3, 1, 2, 0)
                            check_socket()
                    finally:
                        connection.close()
                finally:
                    server.terminate()
                    try:
                        server.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait(timeout=5)
                    _check_metric_output(metrics if _diagnostic_mode()
                                         else None)
        finally:
            proxy.stop()

    def test_atomic_failure_reuses_all_workers(self):
        token = self.token(9223372036854775807)
        before = self.routing_binds(self.proxy)[:20]
        self.assertEqual(len(before), 20)
        for _ in range(20):
            status, body = self.request("POST", "/api/articles", {
                "article": {"title": "rollback", "description": "d", "body": "b"}},
                token)
            self.assertEqual(status, 500)
            self.assertIsInstance(body["errors"]["body"], list)
        after_failure = self.routing_binds(self.proxy)[:20]
        failures = [after[len(initial):]
                    for initial, after in zip(before, after_failure)]
        self.assertEqual(sum(map(len, failures)), 20)
        self.assertGreaterEqual(sum(bool(names) for names in failures), 4)
        self.assertTrue(all(name == b"article_insert"
                            for names in failures for name in names))
        for _ in range(20):
            self.assertEqual(self.request("GET", "/api/tags")[0], 200)
        after_read = self.routing_binds(self.proxy)[:20]
        self.assertEqual([after[len(failed):]
            for failed, after in zip(after_failure, after_read)],
            [[b"tags"] * len(names) for names in failures])
        states = self.sql(
            "SELECT count(*), count(*) FILTER (WHERE state = 'idle') "
            "FROM pg_stat_activity "
            f"WHERE datname = '{self.database}' AND usename = 'conduit'")
        self.assertEqual(states, "20|20")

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

    def test_direct_json_response_wiring(self):
        def strict(data):
            def unique(pairs):
                result = {}
                for key, value in pairs:
                    if key in result:
                        raise ValueError("duplicate JSON key")
                    result[key] = value
                return result
            return json.loads(data, object_pairs_hook=unique)

        for data in ('{"a":1,"a":2}', '{"a":{"b":1,"b":2}}'):
            with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
                strict(data)
        self.assertEqual(strict('{"a":{"b":1}}'), {"a": {"b": 1}})

        def fetch(method, path, body=None, token=None):
            connection = http.client.HTTPConnection("127.0.0.1", self.port,
                                                    timeout=5)
            try:
                headers = {"Content-Type": "application/json"}
                if token:
                    headers["Authorization"] = "Token " + token
                payload = None if body is None else json.dumps(
                    body, ensure_ascii=False).encode()
                connection.request(method, path, payload, headers)
                response = connection.getresponse()
                data = response.read()
                self.assertEqual(int(response.getheader("Content-Length")),
                                 len(data))
                return response.status, strict(data)
            finally:
                connection.close()

        def keys(value, expected):
            self.assertIs(type(value), dict)
            self.assertEqual(set(value), set(expected))

        def profile(value, username, bio, image, following):
            keys(value, ("username", "bio", "image", "following"))
            self.assertEqual(value["username"], username)
            self.assertEqual(value["bio"], bio)
            self.assertEqual(value["image"], image)
            self.assertIs(type(value["following"]), bool)
            self.assertIs(value["following"], following)

        def deleted(path, token):
            request = (f"DELETE {path} HTTP/1.1\r\nHost: localhost\r\n"
                       f"Authorization: Token {token}\r\n"
                       "Connection: close\r\n\r\n").encode()
            with socket.create_connection(("127.0.0.1", self.port), 5) as sock:
                sock.sendall(request)
                deadline = time.monotonic() + 5
                data = bytearray()
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        self.fail("DELETE response did not close")
                    sock.settimeout(remaining)
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    data.extend(chunk)
                    self.assertLess(len(data), 65536)
            head, body = bytes(data).split(b"\r\n\r\n", 1)
            self.assertEqual(head.split(b"\r\n", 1)[0].split()[1], b"204")
            self.assertEqual(body, b"")

        suffix = uuid.uuid4().hex
        username, target = "writer_" + suffix, "reader_" + suffix
        password = "direct-json-password"
        email = username + "@example.invalid"
        user_keys = ("username", "email", "bio", "image", "token")
        for name in (username, target):
            status, response = fetch("POST", "/api/users", {"user": {
                "username": name, "email": name + "@example.invalid",
                "password": password}})
            self.assertEqual(status, 201)
            keys(response, ("user",))
            user = response["user"]
            keys(user, user_keys)
            self.assertEqual(user["username"], name)
            self.assertEqual(user["email"], name + "@example.invalid")
            self.assertIsNone(user["bio"])
            self.assertIsNone(user["image"])
            self.assertIs(type(user["token"]), str)
            if name == target:
                target_token = user["token"]
        status, response = fetch("POST", "/api/users/login", {"user": {
            "email": email, "password": password}})
        self.assertEqual(status, 200)
        keys(response, ("user",))
        keys(response["user"], user_keys)
        self.assertEqual(response["user"]["username"], username)
        self.assertIs(type(response["user"]["token"]), str)
        token = response["user"]["token"]
        status, response = fetch("GET", "/api/user", token=token)
        self.assertEqual(status, 200)
        keys(response, ("user",))
        keys(response["user"], user_keys)
        self.assertEqual(response["user"]["token"], token)
        special = 'quote"\\\b\f\n\r\t\x1f雪🐎tail'
        for bio, image in ((special, ""), ("", special)):
            status, response = fetch("PUT", "/api/user", {"user": {
                "bio": bio, "image": image}}, token)
            self.assertEqual(status, 200)
            keys(response, ("user",))
            keys(response["user"], user_keys)
            self.assertEqual(response["user"]["username"], username)
            self.assertEqual(response["user"]["email"], email)
            self.assertEqual(response["user"]["bio"], bio)
            self.assertEqual(response["user"]["image"], image)
            self.assertEqual(response["user"]["token"], token)
        status, response = fetch("GET", "/api/profiles/" + username)
        self.assertEqual(status, 200)
        keys(response, ("profile",))
        profile(response["profile"], username, "", special, False)
        for method, following in (("POST", True), ("DELETE", False)):
            status, response = fetch(method,
                "/api/profiles/" + target + "/follow", token=token)
            self.assertEqual(status, 200)
            keys(response, ("profile",))
            profile(response["profile"], target, None, None, following)
            status, response = fetch("GET", "/api/profiles/" + target,
                                     token=token)
            self.assertEqual(status, 200)
            profile(response["profile"], target, None, None, following)

        status, response = fetch("POST", "/api/articles", {"article": {
            "title": "direct_" + suffix, "description": special,
            "body": "body_" + special, "tagList": [special]}}, token)
        self.assertEqual(status, 201)
        keys(response, ("article",))
        article = response["article"]
        keys(article, ("slug", "title", "description", "body", "createdAt",
                       "updatedAt", "tagList", "favoritesCount", "favorited",
                       "author"))
        self.assertEqual(article["title"], "direct_" + suffix)
        self.assertEqual(article["description"], special)
        self.assertEqual(article["body"], "body_" + special)
        self.assertEqual(article["tagList"], [special])
        self.assertIs(type(article["favoritesCount"]), int)
        self.assertEqual(article["favoritesCount"], 0)
        self.assertIs(article["favorited"], False)
        profile(article["author"], username, "", special, False)
        path = "/api/articles/" + article["slug"]
        status, response = fetch("GET", path, token=token)
        self.assertEqual(status, 200)
        self.assertEqual(response["article"], article)
        status, response = fetch("PUT", path, {"article": {
            "description": "updated_" + special,
            "body": "updated body_" + special}}, token)
        self.assertEqual(status, 200)
        self.assertEqual(response["article"]["description"],
                         "updated_" + special)
        self.assertEqual(response["article"]["body"], "updated body_" + special)
        for method, favorited, count in (("POST", True, 1),
                                         ("DELETE", False, 0)):
            status, response = fetch(method, path + "/favorite", token=token)
            self.assertEqual(status, 200)
            self.assertIs(response["article"]["favorited"], favorited)
            self.assertIs(type(response["article"]["favoritesCount"]), int)
            self.assertEqual(response["article"]["favoritesCount"], count)
        status, response = fetch("GET", path + "/comments", token=token)
        self.assertEqual(status, 200)
        keys(response, ("comments",))
        self.assertEqual(response["comments"], [])
        status, response = fetch("POST", "/api/profiles/" + target + "/follow",
                                 token=token)
        self.assertEqual(status, 200)
        profile(response["profile"], target, None, None, True)
        comments = []
        for name, auth, bio, image in ((target, target_token, None, None),
                                       (username, token, "", special)):
            status, response = fetch("POST", path + "/comments",
                {"comment": {"body": name + special}}, auth)
            self.assertEqual(status, 201)
            keys(response, ("comment",))
            comment = response["comment"]
            keys(comment, ("id", "body", "createdAt", "updatedAt", "author"))
            self.assertIs(type(comment["id"]), int)
            self.assertEqual(comment["body"], name + special)
            profile(comment["author"], name, bio, image, False)
            comments.append(comment)
            status, listed = fetch("GET", path + "/comments", token=token)
            self.assertEqual(status, 200)
            keys(listed, ("comments",))
            self.assertEqual([c["id"] for c in listed["comments"]],
                             [c["id"] for c in reversed(comments)])
            for c in listed["comments"]:
                expected = next(x for x in comments if x["id"] == c["id"])
                self.assertEqual(c["body"], expected["body"])
                author = expected["author"]
                profile(c["author"], author["username"], author["bio"],
                        author["image"], author["username"] == target)
        for comment, auth in zip(comments, (target_token, token)):
            deleted(path + "/comments/" + str(comment["id"]), auth)
        deleted(path, token)
        for method, url, body, expected, message in (
                ("GET", "/api/user", None, 401, "unauthorized"),
                ("GET", "/unknown", None, 404, "not found"),
                ("POST", "/api/users", {"user": {}}, 422, "invalid request")):
            status, response = fetch(method, url, body)
            self.assertEqual(status, expected)
            keys(response, ("errors",))
            keys(response["errors"], ("body",))
            self.assertEqual(response["errors"]["body"], [message])

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

    def test_timestamp_values_across_postgres_epoch(self):
        title = "timestamp_" + uuid.uuid4().hex
        status, created = self.request("POST", "/api/articles",
            self.article(title, []), self.token(self.author()))
        self.assertEqual(status, 201)
        slug = self.literal(created["article"]["slug"])
        self.db("UPDATE articles SET "
                "created_at = TIMESTAMPTZ '1999-12-31 23:59:59.123456+00', "
                "updated_at = TIMESTAMPTZ '2000-01-01 00:00:00.987654+00' "
                f"WHERE slug = {slug}")
        status, fetched = self.request(
            "GET", "/api/articles/" + created["article"]["slug"])
        self.assertEqual(status, 200)
        self.assertEqual(fetched["article"]["createdAt"],
                         "1999-12-31T23:59:59.123Z")
        self.assertEqual(fetched["article"]["updatedAt"],
                         "2000-01-01T00:00:00.987Z")

    def test_comments_states_use_one_statement(self):
        slug = "comments_states_" + uuid.uuid4().hex
        author = self.author()
        article = self.db("WITH inserted AS (INSERT INTO articles "
            "(slug, author_id, title, description, body) VALUES "
            f"('{slug}', {author}, 'comments', 'd', 'b') RETURNING id) "
            "SELECT id FROM inserted")
        with self.routing_server(1) as run:
            port, proxy, _, _ = run
            connection = self.routing_connect(port)
            try:
                for token in (None, self.token(author)):
                    status, body, changes = self.routing_request(
                        connection, proxy, path="/api/articles/" + slug
                        + "_missing/comments", token=token)
                    self.assertEqual(status, 404)
                    self.assertEqual(body["errors"]["body"],
                                     ["article not found"])
                    self.assertEqual(sum(map(len, changes.values())), 1)
                    status, body, changes = self.routing_request(
                        connection, proxy, path="/api/articles/" + slug
                        + "/comments", token=token)
                    self.assertEqual(status, 200)
                    self.assertEqual(body["comments"], [])
                    self.assertEqual(sum(map(len, changes.values())), 1)
                comment = int(self.db("WITH inserted AS (INSERT INTO comments "
                    "(article_id, author_id, body) VALUES "
                    f"({article}, {author}, 'one') RETURNING id) "
                    "SELECT id FROM inserted"))
                for token in (None, self.token(author)):
                    status, body, changes = self.routing_request(
                        connection, proxy, path="/api/articles/" + slug
                        + "/comments", token=token)
                    self.assertEqual(status, 200)
                    self.assertEqual([c["id"] for c in body["comments"]],
                                     [comment])
                    self.assertEqual(sum(map(len, changes.values())), 1)
                proxy.assert_healthy()
            finally:
                connection.close()

    def test_comments_newest_hundred(self):
        suffix = uuid.uuid4().hex
        names = [f"comments_{suffix}_{index}" for index in range(3)]
        users = [int(self.db("WITH inserted AS (INSERT INTO users "
            "(username, email, password_hash) VALUES "
            f"('{name}', '{name}@example.invalid', 'unused') RETURNING id) "
            "SELECT id FROM inserted"))
            for name in names]
        slug = "comments_order_" + suffix
        articles = [int(self.db("WITH inserted AS (INSERT INTO articles "
            "(slug, author_id, title, description, body) VALUES "
            f"('{name}', {users[0]}, 'comments', 'd', 'b') RETURNING id) "
            "SELECT id FROM inserted"))
            for name in (slug, slug + "_decoy")]
        self.db("INSERT INTO follows (follower_id, followee_id) "
                f"VALUES ({users[2]}, {users[0]})")
        records = json.loads(self.db("WITH inserted AS (INSERT INTO comments "
            "(article_id, author_id, body, created_at, updated_at) SELECT "
            f"{articles[0]}, CASE WHEN n % 2 = 0 THEN {users[0]} "
            f"ELSE {users[1]} END, 'comment_' || n, "
            "CASE WHEN n = 0 THEN '2026-01-02 00:00:00.123456+00'::timestamptz "
            "ELSE '2026-01-01 00:00:00+00'::timestamptz END, "
            "'2026-01-03 00:00:00.987654+00'::timestamptz "
            "FROM generate_series(0, 101) n ORDER BY n "
            "RETURNING id, author_id, body) SELECT json_agg("
            "json_build_object('id', id, 'author_id', author_id, "
            "'body', body)) "
            "FROM inserted"))
        self.db("INSERT INTO comments "
            "(article_id, author_id, body, created_at) VALUES "
            f"({articles[1]}, {users[0]}, 'decoy', "
            "'2026-01-04 00:00:00+00')")
        expected = sorted(records,
            key=lambda row: (row["body"] == "comment_0", row["id"]),
            reverse=True)[:100]
        with self.routing_server(1) as run:
            port, proxy, _, _ = run
            connection = self.routing_connect(port)
            try:
                for token in (None, self.token(users[2])):
                    status, body, changes = self.routing_request(
                        connection, proxy, path="/api/articles/" + slug
                        + "/comments", token=token)
                    self.assertEqual(status, 200)
                    comments = body["comments"]
                    self.assertEqual(len(comments), 100)
                    self.assertEqual([c["id"] for c in comments],
                                     [row["id"] for row in expected])
                    for comment, row in zip(comments, expected):
                        self.assertIs(comment["author"]["following"],
                            token is not None and row["author_id"] == users[0])
                    self.assertEqual(comments[0]["body"], "comment_0")
                    self.assertEqual(comments[0]["createdAt"],
                                     "2026-01-02T00:00:00.123Z")
                    self.assertEqual(comments[0]["updatedAt"],
                                     "2026-01-03T00:00:00.987Z")
                    self.assertEqual(comments[0]["author"]["username"],
                                     names[0])
                    self.assertEqual(sum(map(len, changes.values())), 1)
                proxy.assert_healthy()
            finally:
                connection.close()

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


class WorkerCSVParser(unittest.TestCase):
    def test_exact_schema_and_mixed_diagnostic_output(self):
        records = DiagnosticParser.records(4)
        stream = CSV_HEADER + "\n" + "11,3,0,0,0,1,0,0,2\n"
        csv, lines = _split_output(io.StringIO(stream), {3: 1}, allow_json=False)
        self.assertTrue(csv.header)
        self.assertEqual(lines, [])
        self.assertEqual(csv.rows[0]["worker_id"], 3)
        self.assertEqual(csv.rows[0]["busy"], 1)
        self.assertEqual(csv.rows[0]["pending"], 2)
        mixed = (json.dumps(records[0]) + "\n" + stream +
                 "".join(json.dumps(record) + "\n" for record in records[1:]))
        _check_metric_output(io.StringIO(mixed), require_activity=True)
        with self.assertRaisesRegex(AssertionError, "unexpected JSON"):
            _split_output(io.StringIO(mixed), allow_json=False)

    def test_high_worker_ids_use_supplied_topology(self):
        for worker in (4, 7, 94):
            text = CSV_HEADER + f"\n11,{worker},0,0,1,0,0,0,2\n"
            csv, _ = _split_output(io.StringIO(text), {worker: 1})
            self.assertEqual(csv.rows[0]["worker_id"], worker)
            with self.assertRaisesRegex(AssertionError, "worker identity"):
                _split_output(io.StringIO(text), {worker - 1: 1})

    def test_malformed_csv_is_rejected(self):
        good = "11,0,0,0,1,0,0,0,2\n"
        for text, message in (
                (good, "missing CSV header"),
                (CSV_HEADER + "\n" + CSV_HEADER + "\n", "duplicate CSV header"),
                (CSV_HEADER + "\n" + good.replace("11,", "-1,", 1), "invalid CSV row"),
                (CSV_HEADER + "\n" + good.replace("11,", "1.0,", 1), "invalid CSV row"),
                (CSV_HEADER + "\n" + good.replace("11,", str(1 << 64) + ",", 1),
                 "invalid CSV value"),
                (CSV_HEADER + "\n" + "11,4,0,0,1,0,0,0,2\n", "worker identity"),
                (CSV_HEADER + "\n" + good.rstrip() + ",0\n", "invalid CSV row"),
                (CSV_HEADER + "\n" + "arbitrary output\n", "invalid CSV row"),
                (CSV_HEADER + "\n" + good.replace(",1,0,0,0,2", ",2,0,0,0,2"),
                 "invalid CSV state total")):
            with self.subTest(text=text), self.assertRaisesRegex(
                    AssertionError, message):
                _split_output(io.StringIO(text), {0: 1})
        records = DiagnosticParser.records(1)
        mixed = (CSV_HEADER + "\n11,1,0,0,1,0,0,0,2\n" +
                 "".join(json.dumps(record) + "\n" for record in records))
        with self.assertRaisesRegex(AssertionError, "CSV worker identity"):
            _check_metric_output(io.StringIO(mixed))


class DiagnosticParser(unittest.TestCase):
    def test_shared_worker_inflight_bounds(self):
        for busy in range(5):
            for inflight in range(32 * busy + 2):
                with self.subTest(busy=busy, inflight=inflight):
                    records = self.records([4])
                    for record in records:
                        if record["owner"] == 1:
                            record["counters"] = [inflight, inflight, 0,
                                                  0, 0, 0, 0, 0, 0, 0]
                            record["gauges"] = [0, inflight, 0, 0, 0, 0,
                                                4 - busy, busy, 0, 0]
                    if busy <= inflight <= 32 * busy:
                        _check_metric_output(self.stream(records),
                                             require_activity=False)
                    else:
                        with self.assertRaisesRegex(AssertionError,
                                "physical slot states"):
                            _check_metric_output(self.stream(records),
                                                 require_activity=False)

    @staticmethod
    def records(actor_count=2):
        sizes = ([1] * actor_count if isinstance(actor_count, int)
                 else actor_count)
        actor_count = len(sizes)
        records = []
        for worker_id, size in enumerate(sizes):
            records.append({"kind": "conduit_diag", "schema": 3,
                "owner": 0, "worker_id": worker_id, "database_actor_count": actor_count,
                "connection_count": size, "total_connection_count": sum(sizes),
                "period_ns": 10000000000})
            for slot in range(size):
                for owner in (1, 2):
                    histograms = [{"count": 0, "sum_ns": 0, "max_ns": 0,
                        "overflow": False, "buckets": [0] * 27}
                        for _ in range(33 if owner == 1 else 8)]
                    if owner == 2:
                        histograms[6].update(count=1, sum_ns=1, max_ns=1,
                                             buckets=[1] + [0] * 26)
                    records.append({"kind": "conduit_diag", "schema": 3,
                        "owner": owner, "worker_id": worker_id, "slot": slot,
                        "generation": 0, "request": 1, "report_ns": 10,
                        "observed_ns": 9, "overflow": False, "invalid_clock": 0,
                        "counters": ([1, 1, 1, 0, 0, 1, 0, 1, 0, 0]
                                     if owner == 1 else [1, 0, 0, 0]),
                        "gauges": ([0, 0, 0, 0, 0, 0, size, 0, 0, 0]
                                   if owner == 1 else [0, 0, 0, 0]),
                        "histograms": histograms})
            records.append({"kind": "conduit_diag", "schema": 3,
                "owner": 0, "worker_id": worker_id, "report_ns": 11,
                "next_request": 2})
        return records

    @staticmethod
    def stream(records):
        return io.StringIO("".join(json.dumps(record) + "\n" for record in records))

    def test_interleaved_workers_and_single_worker_probes(self):
        for actor_count in (1, 2, 4, 8, 95, [48, 47], [12] * 7 + [11]):
            with self.subTest(actor_count=actor_count):
                records = self.records(actor_count)
                _check_metric_output(self.stream(records), require_activity=True)
        for generation in (0, 1):
            final = dict(records[2], request=0, generation=generation)
            records.append(final)
        _check_metric_output(self.stream(records), require_activity=True)

    def test_missing_worker_identity_is_rejected_on_every_record_kind(self):
        for index in range(4):
            with self.subTest(record=index):
                records = self.records()
                del records[index]["worker_id"]
                with self.assertRaisesRegex(AssertionError, "worker identity"):
                    _check_metric_output(self.stream(records))

    def test_invalid_metadata_and_unknown_worker_are_rejected(self):
        for key, value, message in (
                ("total_connection_count", 3, "conflicting diagnostic startup"),
                ("worker_id", 4, "worker identity"),
                ("schema", 2, "unexpected diagnostic")):
            records = self.records()
            records[0][key] = value
            with self.subTest(key=key), self.assertRaisesRegex(AssertionError, message):
                _check_metric_output(self.stream(records))
        records = self.records()
        records[4]["period_ns"] += 1
        with self.assertRaisesRegex(AssertionError, "conflicting diagnostic startup"):
            _check_metric_output(self.stream(records))

    def test_unequal_topology_validation(self):
        for mutate, message in (
                (lambda records: records[0].update(connection_count=47),
                 "physical slot states"),
                (lambda records: [record.update(total_connection_count=94)
                    for record in records if "connection_count" in record],
                 "pool configuration total"),
                (lambda records: records[1].update(slot=48), "diagnostic slot"),
                (lambda records: records[0].update(connection_count=0),
                 "pool configuration"),
                (lambda records: records.append(records[0]),
                 "duplicate diagnostic startup"),
                (lambda records: records[0].update(worker_id=True),
                 "worker identity"),
                (lambda records: records[0].pop("period_ns"),
                 "startup record")):
            records = self.records([48, 47])
            mutate(records)
            with self.subTest(message=message), \
                    self.assertRaisesRegex(AssertionError, message):
                _check_metric_output(self.stream(records))
        records = self.records([48, 47])
        records = [record for record in records if record["worker_id"] == 0]
        records[0]["total_connection_count"] = 48
        with self.assertRaisesRegex(AssertionError, "missing worker startup"):
            _check_metric_output(self.stream(records))
        stream = self.stream(self.records([48, 47])).getvalue()
        stream = stream.replace('"schema": 3', '"schema": 3, "schema": 3', 1)
        with self.assertRaisesRegex(AssertionError,
                                    "invalid diagnostic record"):
            _check_metric_output(io.StringIO(stream))

    def test_duplicate_snapshots_within_worker_are_rejected(self):
        for index, message in ((1, "duplicate Worker snapshot"),
                               (2, "duplicate diagnostic record")):
            records = self.records()
            records.append(records[index])
            with self.subTest(owner=records[index]["owner"]), \
                    self.assertRaisesRegex(AssertionError, message):
                _check_metric_output(self.stream(records))

    def test_repeated_overdue_reports_are_valid(self):
        records = self.records()
        for report_ns in (20, 30):
            records.append({"kind": "conduit_diag", "schema": 3,
                "owner": 1, "worker_id": 0, "slot": 0, "generation": None,
                "request": 2, "report_ns": report_ns, "missing": True,
                "reason": "overdue"})
        _check_metric_output(self.stream(records), require_activity=True)

    def test_pairing_cannot_borrow_other_workers_snapshot(self):
        records = self.records()
        records[5]["request"] = 2
        with self.assertRaisesRegex(AssertionError, "unmatched connection snapshot"):
            _check_metric_output(self.stream(records), require_activity=True)

    def test_each_worker_requires_traffic_and_complete_rotation(self):
        for owner, message in ((1, "missing pool traffic"),
                               (2, "missing transport traffic")):
            records = self.records()
            record = next(record for record in records
                          if record["worker_id"] == 1 and record["owner"] == owner)
            record["counters"] = [0] * len(record["counters"])
            with self.subTest(owner=owner), self.assertRaisesRegex(AssertionError, message):
                _check_metric_output(self.stream(records), require_activity=True)
        records = self.records()
        records = [record for record in records if not (
            record["owner"] == 1 and record["worker_id"] == 1)]
        with self.assertRaisesRegex(AssertionError, "missing selected connection slot"):
            _check_metric_output(self.stream(records), require_activity=True)


class WorkerCountCLI(unittest.TestCase):
    def test_rejected_flags_and_private_sizes_do_not_connect(self):
        cases = [["--db-worker-count=" + value] for value in
                 ("", "0", "96", "-1", "+1", "1x", " 1", "1 ",
                  "9223372036854775808")]
        cases += [["--db-worker-count"],
                  ["--db-worker-count", "--ponymaxthreads=1"],
                  ["--db-worker-count=2", "--db-worker-count", "2"],
                  ["--db-worker-count=2", "--db-worker-count=2"],
                  ["--db-worker-count", "1", "--db-worker-count", "2"]]
        for args, size in [(args, "1") for args in cases] + [
                (["--test-http", "--db-worker-count=4"], size)
                for size in ("", "invalid", "0", "24",
                             "9223372036854775808")] + [
                (["--test-pool"], "invalid")]:
            with self.subTest(args=args, private_size=size), \
                    socket.socket() as backend:
                backend.bind(("127.0.0.1", 0))
                backend.listen(128)
                backend.settimeout(0.02)
                attempts = []
                done = threading.Event()
                def accept():
                    while not done.is_set():
                        try:
                            connection, _ = backend.accept()
                            attempts.append(connection)
                        except socket.timeout:
                            pass
                thread = threading.Thread(target=accept)
                thread.start()
                try:
                    env = os.environ.copy()
                    env.update(DATABASE_URL="postgres://test:test@127.0.0.1:"
                        f"{backend.getsockname()[1]}/test",
                        JWT_SECRET="cli-test",
                        CONDUIT_TEST_POOL_SIZE=size)
                    result = subprocess.run([str(_executable()), *args,
                        "--ponymaxthreads=1"], env=env, capture_output=True,
                        text=True, timeout=5)
                    self.assertEqual(result.returncode, 1)
                    expected = ("--db-worker-count" if args in cases else
                                "CONDUIT_TEST_POOL_SIZE")
                    self.assertIn(expected, result.stderr)
                finally:
                    done.set()
                    thread.join(timeout=2)
                    self.assertFalse(thread.is_alive())
                    backend.setblocking(False)
                    while True:
                        try:
                            connection, _ = backend.accept()
                            attempts.append(connection)
                        except BlockingIOError:
                            break
                    for connection in attempts:
                        connection.close()
                self.assertEqual(len(attempts), 0,
                                 "rejected input opened a backend")

    def test_accepted_spellings_with_runtime_flags(self):
        for args in (["--db-worker-count=008"], ["--db-worker-count", "2"],
                     ["--db-worker-count=95"]):
            with self.subTest(args=args):
                result = subprocess.run([str(_executable()), *args,
                    "--self-test", "--ponymaxthreads=1", "--ponynoblock"],
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Self-tests passed", result.stdout)


class DefaultTopology(unittest.TestCase):
    routing_binds = staticmethod(Integration.routing_binds)
    routing_request = Integration.routing_request
    routing_pool_routes = Integration.routing_pool_routes
    routing_read_response = Integration.routing_read_response

    def test_default_one_scheduler_worker(self):
        self.check_topology([], [95], schedulers=1)

    def test_default_two_scheduler_workers(self):
        self.check_topology([], [48, 47], schedulers=2)

    def test_default_eight_workers(self):
        self.check_topology([], [12] * 7 + [11])

    def test_two_unequal_workers_and_routing(self):
        self.check_topology(["--db-worker-count", "2"], [48, 47])

    def test_maximum_worker_count(self):
        self.check_topology(["--db-worker-count=95"], [1] * 95, schedulers=1)

    def check_topology(self, args, sizes, schedulers=8):
        database = "pony_default_" + uuid.uuid4().hex
        Integration.sql(f"CREATE DATABASE {database} TEMPLATE conduit_dev")
        try:
            self.run_topology(database, args, sizes, schedulers)
        finally:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                remaining = Integration.sql(
                    "SELECT count(*) FROM pg_stat_activity "
                    f"WHERE datname = '{database}' AND usename = 'conduit'")
                if remaining == "0":
                    break
                time.sleep(0.02)
            Integration.sql(f"DROP DATABASE {database} WITH (FORCE)")
            self.assertEqual(remaining, "0", "server backend sessions remained")

    def run_topology(self, database, args, sizes, schedulers=8):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        env = os.environ.copy()
        host = env.get("PGHOST", "127.0.0.1")
        if host.startswith("/"):
            host = "127.0.0.1"
        proxy = ProtocolProxy(host, env.get("PGPORT", "5432"))
        try:
            env.update(DATABASE_URL="postgres://conduit:conduit@127.0.0.1:"
                f"{proxy.server_address[1]}/{database}",
                JWT_SECRET="topology-secret",
                HOST="127.0.0.1", PORT=str(port), DB_WORKERS="invalid",
                CONDUIT_TEST_POOL_SIZE="1")
            counts = dict(enumerate(sizes))
            with tempfile.TemporaryFile() as log, \
                    tempfile.TemporaryFile() as metrics:
                server = subprocess.Popen([str(_executable()), *args,
                    f"--ponymaxthreads={schedulers}"],
                    env=env, stdout=metrics, stderr=log)
                try:
                    deadline = time.monotonic() + 40
                    while time.monotonic() < deadline:
                        self.assertIsNone(server.poll(),
                                          "topology server exited")
                        state = Integration.sql(
                            "SELECT count(*), count(*) FILTER "
                            "(WHERE state = 'idle') FROM pg_stat_activity "
                            f"WHERE datname = '{database}' "
                            "AND usename = 'conduit'")
                        csv = Integration.csv_output(self, metrics, counts)
                        ready = {row["worker_id"] for row in csv.rows
                                 if row["idle"] == counts[row["worker_id"]]}
                        data = os.pread(metrics.fileno(),
                                        os.fstat(metrics.fileno()).st_size, 0)
                        data = data[:data.rfind(b"\n") + 1]
                        records = _metric_records(io.BytesIO(data))
                        selected = {(record["worker_id"], record["slot"])
                                    for record in records
                                    if record.get("owner") == 1
                                    and "counters" in record}
                        expected = {(worker, slot)
                                    for worker, count in counts.items()
                                    for slot in range(count)}
                        if state == "95|95" and (not _diagnostic_mode() or (
                                ready == set(counts) and selected == expected)):
                            break
                        time.sleep(0.05)
                    self.assertEqual(state, "95|95")
                    if _diagnostic_mode():
                        self.assertEqual(ready, set(counts))
                        self.assertEqual(selected, expected)
                        startups = [record for record in records
                                    if "connection_count" in record]
                        self.assertEqual(len(startups), len(sizes))
                        self.assertEqual(
                            {record["worker_id"]: record["connection_count"]
                             for record in startups}, counts)
                        for record in startups:
                            self.assertEqual(
                                record["total_connection_count"], 95)
                            self.assertEqual(
                                record["database_actor_count"], len(sizes))
                    else:
                        self.assertEqual(data, b"",
                                         "ordinary startup emitted metrics")
                    if sizes == [48, 47]:
                        with ExitStack() as cleanup:
                            connections = [Integration.routing_connect(
                                self, port) for _ in sizes]
                            for connection in connections:
                                cleanup.callback(connection.close)
                            routes = self.routing_pool_routes(
                                database, connections, proxy, sizes)
                            self.assertEqual([len(route) for route in routes],
                                             sizes)
                            self.assertTrue(routes[0].isdisjoint(routes[1]))
                            self.assertEqual(routes[0] | routes[1],
                                             set(range(95)))
                    proxy.assert_healthy()
                finally:
                    server.terminate()
                    try:
                        server.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait(timeout=5)
                    if _diagnostic_mode():
                        _check_metric_output(metrics)
        finally:
            proxy.stop()

if __name__ == "__main__":
    unittest.main()
