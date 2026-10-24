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
                    if sum(g[4:10]) != connection_count or g[7] != g[1]:
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

    def __init__(self, database_host, database_port, frame_timeout=15, capacity=128,
                 complete_capture=False, record_limit=4096,
                 name_bytes_limit=1048576, name_limit=128):
        self.database_host = database_host
        self.database_port = int(database_port)
        self.frame_timeout = frame_timeout
        self.messages = []
        self.frame_gates = []
        self.failures = []
        self.capacity = capacity
        self.complete_capture = complete_capture
        self.record_limit = record_limit
        self.name_bytes_limit = name_bytes_limit
        self.name_limit = name_limit
        self.name_bytes = 0
        self.handlers = set()
        self.requests = set()
        self.backends = []
        self.frontends = []
        self.mutate_next_row = False
        self.row_corruptions = []
        self.prepare_replacement = None
        self.prepare_receipts = []
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

    def capture(self, messages, kind, payload):
        with self.lock:
            names = payload.split(b"\0", 2)
            needed = 1 if kind == b"P" else 2
            if self.complete_capture:
                if len(names) <= needed:
                    self.failures.append("unterminated captured name")
                    raise EOFError
                fields = names[:needed]
                if any(len(name) > self.name_limit for name in fields):
                    self.failures.append("captured name length limit")
                    raise EOFError
                captured = b"".join(name + b"\0" for name in fields)
                if len(messages) >= self.record_limit:
                    self.failures.append("capture record limit")
                    raise EOFError
                if self.name_bytes + len(captured) > self.name_bytes_limit:
                    self.failures.append("capture total name bytes limit")
                    raise EOFError
                self.name_bytes += len(captured)
                messages.append((kind, captured))
            elif len(messages) < 1024:
                captured = b"".join(name[:128] + b"\0"
                                    for name in names[:needed])
                messages.append((kind, captured))

    def drop_backend(self, index=-1):
        with self.lock:
            backend = self.backends[index]
        backend.shutdown(socket.SHUT_RDWR)
        backend.close()

    def corrupt_next_data_row(self):
        with self.lock:
            self.mutate_next_row = True

    def replace_prepare(self, connection, name):
        with self.lock:
            if self.prepare_replacement is not None:
                raise ValueError("prepare replacement already armed")
            self.prepare_replacement = (connection, name)

    def replace_prepare_payload(self, connection, payload):
        with self.lock:
            change = self.prepare_replacement
            if change is None or change[0] != connection:
                return payload
            name, sql, remainder = payload.split(b"\0", 2)
            if name != change[1]:
                return payload
            self.prepare_replacement = None
            self.prepare_receipts.append((connection, name))
            return name + b"\0SELECT FROM\0" + remainder

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
        thread = threading.current_thread()
        with self.lock:
            self.handlers.add(thread)
            self.requests.add(request)
        try:
            super().process_request_thread(request, client_address)
        finally:
            with self.lock:
                self.requests.discard(request)
            self.connections.release()

    def stop(self):
        self.release_command_complete(abort=True)
        for gate in self.frame_gates:
            gate.abort = True
            gate.release.set()
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=5)
        with self.lock:
            sockets = list(self.requests) + list(self.backends)
            handlers = list(self.handlers)
        for connection in sockets:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        for handler in handlers:
            handler.join(timeout=5)
        if self.thread.is_alive() or any(h.is_alive() for h in handlers):
            raise AssertionError("proxy did not stop all handlers")


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
                                       self.server.database_port), timeout=5) as backend:
            backend.settimeout(None)
            messages = []
            with self.server.lock:
                index = len(self.server.messages)
                if index < self.server.capacity:
                    self.server.messages.append(messages)
                    self.server.backends.append(backend)
                    self.server.frontends.append(self.request)
                elif self.server.complete_capture:
                    self.server.failures.append("capture connection lifetime limit")
                    return

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
                                self.server.row_corruptions.append(index)
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
                        self.server.capture(messages, kind, payload)
                    if kind == b"P":
                        payload = self.server.replace_prepare_payload(index, payload)
                        size = (len(payload) + 4).to_bytes(4, "big")
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
                if thread.is_alive():
                    with self.server.lock:
                        self.server.failures.append("proxy downstream did not stop")


class PoolRun:
    def __init__(self, case, process, proxy, csv=False, count=2, actors=1,
                 deadline=None, counts=None):
        self.case = case
        self.process = process
        self.proxy = proxy
        self.buffer = b""
        self.events = []
        self.history = []
        self.sequence = 0
        self.deadline = deadline
        self.csv = WorkerCSV(counts if counts is not None else
                             dict.fromkeys(range(actors), count)) if csv else None
        self.selector = selectors.DefaultSelector()
        self.selector.register(process.stdout, selectors.EVENT_READ)
        self.receive(lambda event: event.get("event") == "started")

    def send(self, *commands):
        self.remaining(10, "send pool command")
        self.process.stdin.write(("\n".join(commands) + "\n").encode())
        self.process.stdin.flush()
        self.remaining(10, "sent pool command")

    def remaining(self, timeout, event):
        if self.deadline is not None:
            timeout = min(timeout, self.deadline - time.monotonic())
        if timeout <= 0:
            raise AssertionError("scenario deadline: " + event)
        return timeout

    def receive(self, predicate, timeout=10, deadline=None,
                event_name="pool probe response"):
        end = time.monotonic() + self.remaining(timeout, event_name)
        if deadline is not None:
            end = min(end, deadline)
        while True:
            if time.monotonic() >= end:
                raise AssertionError(event_name + " timed out")
            for index, event in enumerate(self.events):
                if predicate(event):
                    self.remaining(end - time.monotonic(), event_name)
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
            remaining = end - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise AssertionError(event_name + " timed out")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise AssertionError("pool probe exited before response")
            self.buffer += chunk

    def state(self, worker=0, deadline=None):
        self.sequence += 1
        request = self.sequence
        self.send(f"state {request} {worker}")
        state = self.receive(lambda event: event.get("event") == "state"
                             and event["request"] == request,
                             deadline=deadline,
                             event_name=f"worker {worker} state {request}")
        self.case.assertEqual(state["worker"], worker)
        idle = state["idle"]
        self.case.assertEqual(len(idle), len(set(idle)))
        self.case.assertEqual(set(idle), {index for index, code in
                              enumerate(state["phases"]) if code == 2})
        self.case.assertEqual(state["outstanding"],
                              len(state["queued"]) + len(state["write_queued"])
                              + len(state["active"]))
        self.remaining(10, "state assertions")
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

    def wait_state(self, predicate, timeout=10, worker=0,
                   event_name="pool state condition"):
        deadline = time.monotonic() + self.remaining(timeout, event_name)
        while time.monotonic() < deadline:
            try:
                state = self.state(worker=worker, deadline=deadline)
            except AssertionError as failure:
                if time.monotonic() >= deadline:
                    raise AssertionError(event_name + " timed out") from failure
                raise
            if predicate(state):
                if time.monotonic() >= deadline:
                    raise AssertionError(event_name + " timed out")
                return state
            time.sleep(min(0.01, max(0, deadline - time.monotonic())))
        raise AssertionError(event_name + " timed out")

    def ready(self, count):
        return self.wait_state(lambda state: state["phases"] == [2] * count)

    def result(self, id, kind="ok"):
        result = self.receive(lambda event: event.get("event") == "result"
                              and event["id"] == id)
        self.case.assertEqual(result["kind"], kind)
        return result

    def fence(self):
        self.sequence += 1
        request = self.sequence
        self.send(f"fence {request}")
        values = {}
        for _ in range(4):
            event = self.receive(lambda event: event.get("event") == "fence"
                                 and event["request"] == request)
            self.case.assertNotIn(event["client"], values)
            values[event["client"]] = event["callbacks"]
        return values

    def checkpoint(self, request):
        state = self.receive(lambda event: event.get("event") == "state"
                             and event["request"] == request,
                             event_name=f"dispatch checkpoint {request}")
        counts = {}
        for _ in range(4):
            event = self.receive(lambda event: event.get("event") == "fence"
                                 and event["request"] == request,
                                 event_name=f"checkpoint {request} client fence")
            self.case.assertNotIn(event["client"], counts)
            counts[event["client"]] = event["callbacks"]
        prefix = []
        for event in self.history:
            if (event["event"] == "fence" and event["request"] == request
                    and event["client"] == 0):
                break
            if event["event"] == "result" and event["client"] == 0:
                prefix.append((event["id"], event["kind"]))
        return state, counts, prefix

    def barrier(self):
        self.sequence += 1
        request = self.sequence
        self.send(f"barrier {request}")
        return self.receive(lambda value: value.get("event") == "barrier"
                            and value["request"] == request,
                            event_name=f"worker barrier {request}")["pending"]

    def diag(self):
        self.sequence += 1
        request = self.sequence
        self.send(f"diag {request}")
        return self.receive(lambda value: value.get("event") == "diag"
                            and value["request"] == request,
                            event_name=f"worker diagnostic {request}")


class SQLSession:
    def __init__(self, database, env=None, deadline=None):
        self.deadline = deadline
        if deadline is not None and time.monotonic() >= deadline:
            raise TimeoutError("scenario deadline before SQL session")
        self.process = subprocess.Popen(
            ["psql", "-XAt", "-v", "ON_ERROR_STOP=1", "-d", database],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, bufsize=0, env=env)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""

    def execute(self, statement):
        deadline = time.monotonic() + 10
        if self.deadline is not None:
            deadline = min(deadline, self.deadline)
        if time.monotonic() >= deadline:
            raise TimeoutError("scenario deadline before SQL command")
        marker = uuid.uuid4().hex.encode()
        self.process.stdin.write(statement.encode() + b"\n\\echo " + marker + b"\n")
        lines = []
        while True:
            if time.monotonic() >= deadline:
                raise TimeoutError("scenario deadline awaiting SQL acknowledgement")
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                if line == marker:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("SQL response after scenario deadline")
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
            [str(_executable()), "--test-session-resume-close", "--db-write-sessions=95"],
            env=self.server_env | {"CONDUIT_TEST_POOL_SIZE": "invalid"},
            capture_output=True, text=True, timeout=10)
        self.assertEqual(process.returncode, 0,
                         _failure_output(process.stderr))
        self.assertEqual(process.stdout.strip(),
                         "rejected preparation closed")

    def test_direct_callback_diagnostic_accounting(self):
        if not _diagnostic_mode():
            self.skipTest("diagnostic variant only")
        for writes in (0, 1):
            with self.subTest(writes=writes):
                self._direct_callback_diagnostic_accounting(writes)

    def _direct_callback_diagnostic_accounting(self, writes):
        database = f"pony_diag_callback_{os.getpid()}"
        self.sql(f"CREATE DATABASE {database} TEMPLATE conduit_dev")
        try:
            self.sql("ALTER TABLE tags RENAME TO tags_hidden", database)
            env = self.server_env.copy()
            env.update(DATABASE_URL=f"postgres://conduit:conduit@"
                       f"{self.proxy.database_host}:"
                       f"{self.proxy.database_port}/{database}",
                       CONDUIT_TEST_POOL_SIZE="2" if writes else "1")
            process = subprocess.run(
                [str(_executable()), "--test-worker-diagnostic",
                 f"--db-write-sessions={writes}"],
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
                 listener=False, writes=None, complete_capture=False,
                 deadline=None):
        if deadline is not None and time.monotonic() >= deadline:
            raise AssertionError("scenario deadline before pool fixture")
        proxy = ProtocolProxy(self.proxy.database_host,
                              self.proxy.database_port,
                              complete_capture=complete_capture)
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
            args = [str(_executable()),
                 ("--test-listener-csv" if listener else
                  "--test-pool-csv" if csv else "--test-pool"),
                 "--ponymaxthreads=1"]
            if writes is not None:
                args.append(f"--db-write-sessions={writes}")
            process = subprocess.Popen(args,
                env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=errors)
            run = None
            try:
                run = PoolRun(self, process, proxy, csv, count,
                              4 if listener else 1, deadline)
                if listener:
                    run.port = int(env["PORT"])
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

    def split_hold(self, run, command, query_id, role, held=(), outcome=1,
                   worker=0):
        self.assertTrue(run.proxy.complete_capture)
        generations = run.state(worker)["generations"]
        before = run.proxy.snapshot()
        excluded = {entry["connection"] for entry in held}
        gates = {index: run.proxy.hold_frame(b"Z", index, timeout=60)
                 for index in range(len(before)) if index not in excluded}
        run.send(f"target {worker} " + command if worker else command)
        state = run.wait_state(lambda value: any(
            item[1:] == [query_id, outcome] for item in value["active"]),
            worker=worker, event_name=f"worker {worker} query {query_id} outcome {outcome}")
        connection, slot, name = self.split_mapping(before, run.proxy.snapshot(),
                                                  state, generations, query_id, role)
        self.assertIn(connection, gates)
        self.assertTrue(gates[connection].reached.wait(
            run.remaining(5, f"query {query_id} ReadyForQuery gate")))
        run.proxy.assert_healthy()
        with run.proxy.lock:
            for index, gate in gates.items():
                if index != connection:
                    gate.claimed = True
                    gate.release.set()
        return dict(connection=connection, slot=slot,
                    generation=state["generations"][slot],
                    gate=gates[connection], name=name, id=query_id)

    def split_mapping(self, before, after, state, generations, query_id, role):
        active = [item for item in state["active"] if item[1] == query_id]
        self.assertEqual(len(active), 1, "mapping active ID count")
        slot = active[0][0]
        self.assertEqual(state["roles"][slot], role, "mapping role mismatch")
        self.assertEqual(state["generations"][slot], generations[slot],
                         "mapping generation mismatch")
        self.assertEqual(len(after), len(before), "mapping connection inventory changed")
        candidates = [(index, name) for index, messages in enumerate(after)
                      for kind, name in messages[len(before[index]):]
                      if kind == b"B"]
        self.assertEqual(len(candidates), 1, "mapping Bind count")
        connection, name = candidates[0]
        return connection, slot, name

    def split_successor(self, run, predecessor, query_id, role, queued,
                        predecessor_callback=True):
        gate = run.proxy.hold_frame(b"Z", predecessor["connection"], timeout=60)
        predecessor["gate"].release.set()
        if predecessor_callback:
            run.result(predecessor["id"])
        self.assertTrue(gate.reached.wait(
            run.remaining(5, f"successor {query_id} ReadyForQuery gate")))
        state = run.wait_state(lambda value:
            [predecessor["slot"], query_id, 1] in value["active"],
            event_name=f"successor {query_id} in slot {predecessor['slot']}")
        run.proxy.assert_healthy()
        self.assertEqual(state["roles"][predecessor["slot"]], role)
        self.assertEqual(state["generations"][predecessor["slot"]],
                         predecessor["generation"])
        self.assertEqual(state["write_queued" if role == 2 else "queued"], queued)
        return dict(predecessor, gate=gate, id=query_id)

    def test_split_catalog_enqueue_placement(self):
        table = [
            ("tags", 1), ("register_user", 2), ("login_user", 1),
            ("current_user", 1), ("update_user", 2), ("profile", 1),
            ("follow_target", 1), ("follow_insert", 2), ("follow_delete", 2),
            ("article_page_all", 1), ("article_page_feed", 1),
            ("article_page_tag", 1), ("article_page_author", 1),
            ("article_page_favorited", 1), ("article_full_by_slug", 1),
            ("article_full_by_id", 1), ("article_insert", 2),
            ("article_id_and_author_by_slug", 1), ("article_update_input", 1),
            ("article_update", 2), ("article_delete", 2),
            ("article_id_by_slug", 1), ("favorite_insert", 2),
            ("favorite_delete", 2), ("comments_by_slug", 1),
            ("comment_input", 1), ("comment_insert", 2),
            ("comment_owner", 1), ("comment_delete", 2)]
        for writes in (1, None, 0):
            with self.subTest(writes=writes), self.pool_run(
                    writes=writes, complete_capture=True) as run:
                state = run.ready(2)
                self.assertEqual(state["roles"], [1, 2] if writes else [0, 0])
                read = self.split_hold(run, "tags 1 3", 1, 1 if writes else 0)
                write = self.split_hold(run,
                    f"register 2 3 split_{uuid.uuid4().hex}", 2,
                    2 if writes else 0, [read])
                self.assertEqual(read["name"], b"\0tags\0")
                self.assertEqual(write["name"], b"\0register_user\0")
                before = run.proxy.snapshot()
                run.send(*(f"typed {101 + i} 0 {name}"
                           for i, (name, _) in enumerate(table)))
                state = run.state()
                read_ids = [101 + i for i, (_, role) in enumerate(table)
                            if role == 1 or not writes]
                write_ids = [101 + i for i, (_, role) in enumerate(table)
                             if role == 2 and writes]
                self.assertEqual(state["queued"], read_ids)
                self.assertEqual(state["write_queued"], write_ids)
                self.assertEqual(sorted(item[1] for item in state["active"]),
                                 [1, 2])
                self.assertEqual(state["outstanding"], 31)
                self.assertEqual(state["recipients"], 2)
                run.send("close")
                for query_id in range(101, 130):
                    self.assertEqual(run.result(query_id, "lost")["client"], 0)
                for query_id in (1, 2):
                    self.assertEqual(run.result(query_id, "lost")["client"], 3)
                state = run.wait_state(lambda value: value["phases"] == [5, 5])
                self.assertEqual(state["queued"], [])
                self.assertEqual(state["write_queued"], [])
                self.assertEqual(state["outstanding"], 0)
                self.assertEqual(run.fence(), {0: 29, 1: 0, 2: 0, 3: 2})
                run.proxy.assert_healthy()
                self.assertEqual(run.proxy.snapshot(), before)

    def test_split_named_execution_and_cte_effects(self):
        name = "named_" + uuid.uuid4().hex
        author = int(self.db("INSERT INTO users(username,email,password_hash) VALUES ("
            + self.literal(name) + "," + self.literal(name + "@pool.test")
            + ",'test-hash') RETURNING id" ).splitlines()[0])
        article = json.dumps({"article": {"title": name, "description": name,
                             "body": name, "tagList": [name]}}, separators=(",", ":"))
        with self.pool_run(writes=1, complete_capture=True) as run:
            self.assertEqual(run.ready(2)["roles"], [1, 2])
            expected_prepares = {"tags", "register_user", "login_user", "current_user",
                "update_user", "profile", "follow_target", "follow_insert",
                "follow_delete", "article_page_all", "article_page_feed",
                "article_page_tag", "article_page_author", "article_page_favorited",
                "article_full_by_slug", "article_full_by_id", "article_insert",
                "article_id_and_author_by_slug", "article_update_input", "article_update",
                "article_delete", "article_id_by_slug", "favorite_insert", "favorite_delete",
                "comments_by_slug", "comment_input", "comment_insert", "comment_owner",
                "comment_delete", "rollback"}
            for messages in run.proxy.snapshot():
                names = [name[:-1].decode() for kind, name in messages if kind == b"P"]
                self.assertEqual(len(names), 30)
                self.assertEqual(set(names), expected_prepares)
            def execute(query_id, selector, role, params, effect):
                held = self.split_hold(run,
                    " ".join(["typed", str(query_id), "0", selector, *params]),
                    query_id, role)
                self.assertEqual(held["name"], b"\0" + selector.encode() + b"\0")
                effect()
                held["gate"].release.set()
                run.result(query_id)
                run.ready(2)
                effect()
            def count(table, predicate):
                return int(self.db(f"SELECT count(*) FROM {table} WHERE {predicate}"))
            execute(1, "tags", 1, [], lambda: self.assertEqual(
                count("articles", "title=" + self.literal(name)), 0))
            registered = name + "_register"
            execute(2, "register_user", 2,
                ["s:" + registered, "s:" + registered + "@pool.test", "s:test-hash"],
                lambda: self.assertEqual(count("users", "username="
                                               + self.literal(registered)), 1))
            execute(3, "article_update_input", 1,
                ["s:missing", 's:{"article":{"body":"unchanged"}}'],
                lambda: self.assertEqual(count("articles", "title=" + self.literal(name)), 0))
            def article_effect():
                self.assertEqual(count("articles", "title=" + self.literal(name)), 1)
                self.assertEqual(count("tags", "name=" + self.literal(name)), 1)
                self.assertEqual(count("article_tags at JOIN articles a ON a.id=at.article_id "
                    "JOIN tags t ON t.id=at.tag_id", "a.title=" + self.literal(name)
                    + " AND t.name=" + self.literal(name)), 1)
            execute(4, "article_insert", 2, [f"i:{author}", "s:" + article], article_effect)
            row = self.db("SELECT id,slug FROM articles WHERE title=" + self.literal(name))
            article_id, slug = row.split("|")
            execute(5, "comment_input", 1,
                ["s:" + slug, 's:{"comment":{"body":"' + name + '"}}'],
                lambda: self.assertEqual(count("comments", "body=" + self.literal(name)), 0))
            execute(6, "comment_insert", 2,
                ["i:" + article_id, f"i:{author}", "s:" + name],
                lambda: self.assertEqual(count("comments", "body=" + self.literal(name)), 1))
            self.assertEqual(run.fence(), {0: 6, 1: 0, 2: 0, 3: 0})
            if _diagnostic_mode():
                self.assertEqual(run.diag()["counters"][:9],
                                 [6, 2, 6, 4, 2, 6, 1, 0, 6])
            run.proxy.assert_healthy()
            binds = [value for messages in run.proxy.snapshot()
                     for kind, value in messages if kind == b"B"]
            self.assertCountEqual(binds, [b"\0" + name.encode() + b"\0" for name in
                ("tags", "register_user", "article_update_input", "article_insert",
                 "comment_input", "comment_insert")])

    def test_split_saturation_progress_fifo(self):
        for roles in ([1, 1, 2], [1, 2, 2], [1, 2]):
            for blocked in (1, 2):
                with self.subTest(roles=roles, blocked=blocked), self.pool_run(
                        count=len(roles), writes=roles.count(2),
                        complete_capture=True) as run:
                    self.assertEqual(run.ready(len(roles))["roles"], roles)
                    def command(query_id, role):
                        return (f"tags {query_id} 0" if role == 1 else
                                f"register {query_id} 0 s_{uuid.uuid4().hex}")
                    held = []
                    for i, role in enumerate(roles):
                        held.append(self.split_hold(run, command(i + 1, role),
                                                    i + 1, role, held))
                    blocked_entries = [entry for entry in held
                                       if roles[entry["slot"]] == blocked]
                    for entry in held:
                        if roles[entry["slot"]] != blocked:
                            entry["gate"].release.set()
                            run.result(entry["id"])
                    run.send(*(command(i, blocked) for i in (11, 12, 13)),
                             command(21, 3 - blocked))
                    run.result(21)
                    state = run.state()
                    key = "write_queued" if blocked == 2 else "queued"
                    self.assertEqual(state[key], [11, 12, 13])
                    selected = blocked_entries[0]
                    selected = self.split_successor(run, selected, 11, blocked,
                                                    [12, 13])
                    run.send(command(27, blocked))
                    self.assertEqual(run.state()[key], [12, 13, 27])
                    for query_id, suffix in ((12, [13, 27]), (13, [27]), (27, [])):
                        selected = self.split_successor(run, selected, query_id,
                                                        blocked, suffix)
                    selected["gate"].release.set()
                    run.result(27)
                    for entry in blocked_entries[1:]:
                        entry["gate"].release.set()
                        run.result(entry["id"])
                    state = run.ready(len(roles))
                    self.assertEqual(state["outstanding"], 0)
                    self.assertEqual(run.fence()[0], len(roles) + 5)
                    run.proxy.assert_healthy()

        for writes in (None, 0):
            with self.subTest(shared=writes), self.pool_run(
                    writes=writes, complete_capture=True) as run:
                self.assertEqual(run.ready(2)["roles"], [0, 0])
                read = self.split_hold(run, "tags 1 0", 1, 0)
                write = self.split_hold(run, f"register 2 0 s_{uuid.uuid4().hex}",
                                        2, 0, [read])
                run.send("tags 11 0", f"register 21 0 s_{uuid.uuid4().hex}")
                write = self.split_successor(run, write, 11, 0, [21])
                write = self.split_successor(run, write, 21, 0, [])
                for entry in (read, write):
                    entry["gate"].release.set()
                    run.result(entry["id"])
                self.assertEqual(run.ready(2)["outstanding"], 0)
                self.assertEqual(run.fence(), {0: 4, 1: 0, 2: 0, 3: 0})

    def test_split_cancel_cohorts_across_queues(self):
        with self.pool_run(writes=1, complete_capture=True) as run:
            self.assertEqual(run.ready(2)["roles"], [1, 2])
            read = self.split_hold(run, "tags 10 0", 10, 1)
            write = self.split_hold(run,
                f"register 11 0 s_{uuid.uuid4().hex}", 11, 2, [read])
            cancelled_name = "s_" + uuid.uuid4().hex
            run.send("tags 12 0", f"register 13 0 {cancelled_name}", "cancel 0",
                     "tags 20 0", f"register 21 0 s_{uuid.uuid4().hex}",
                     "tags 30 1", f"register 31 1 s_{uuid.uuid4().hex}")
            state = run.state()
            self.assertEqual(state["queued"], [12, 20, 30])
            self.assertEqual(state["write_queued"], [13, 21, 31])
            self.assertEqual(state["outstanding"], 8)
            self.assertEqual(state["recipients"], 2)
            self.assertEqual(run.fence(), {0: 0, 1: 0, 2: 0, 3: 0})
            read = self.split_successor(run, read, 12, 1, [20, 30], False)
            write = self.split_successor(run, write, 13, 2, [21, 31], False)
            self.assertEqual(run.fence(), {0: 0, 1: 0, 2: 0, 3: 0})
            self.assertEqual(self.db("SELECT count(*) FROM users WHERE username="
                                     + self.literal(cancelled_name)), "1")
            read = self.split_successor(run, read, 20, 1, [30], False)
            write = self.split_successor(run, write, 21, 2, [31], False)
            self.assertEqual(run.fence(), {0: 0, 1: 0, 2: 0, 3: 0})
            self.assertEqual(run.state()["recipients"], 2)
            read = self.split_successor(run, read, 30, 1, [])
            write = self.split_successor(run, write, 31, 2, [])
            self.assertEqual(run.fence(), {0: 2, 1: 0, 2: 0, 3: 0})
            for entry in (read, write):
                entry["gate"].release.set()
                self.assertEqual(run.result(entry["id"])["client"], 1)
            state = run.ready(2)
            self.assertEqual(state["recipients"], 0)
            self.assertEqual(run.fence(), {0: 2, 1: 2, 2: 0, 3: 0})
            completed = [(event["client"], event["id"]) for event in run.history
                         if event["event"] == "result"]
            self.assertEqual(sorted(completed), [(0, 20), (0, 21), (1, 30), (1, 31)])
            run.proxy.assert_healthy()
            binds = [name for messages in run.proxy.snapshot()
                     for kind, name in messages if kind == b"B"]
            self.assertEqual(binds.count(b"\0tags\0"), 4)
            self.assertEqual(binds.count(b"\0register_user\0"), 4)
        for startup in (False, True):
            gates = []
            def configure(proxy):
                if startup:
                    gates.extend(proxy.hold_frame(b"1", index, timeout=60)
                                 for index in range(2))
            with self.subTest(startup=startup), self.pool_run(
                    writes=1, complete_capture=True, configure=configure) as run:
                if startup:
                    for gate in gates:
                        self.assertTrue(gate.reached.wait(5))
                    self.assertEqual(run.state()["phases"], [1, 1])
                else:
                    run.ready(2)
                    read = self.split_hold(run, "tags 1 3", 1, 1)
                    write = self.split_hold(run, f"register 2 3 s_{uuid.uuid4().hex}",
                                            2, 2, [read])
                run.send("tags 10 0", f"register 11 0 s_{uuid.uuid4().hex}", "cancel 0",
                         "tags 20 0", f"register 21 0 s_{uuid.uuid4().hex}",
                         "tags 30 1", f"register 31 1 s_{uuid.uuid4().hex}")
                state = run.state()
                self.assertEqual(state["queued"], [10, 20, 30])
                self.assertEqual(state["write_queued"], [11, 21, 31])
                self.assertEqual(state["outstanding"], 6 if startup else 8)
                self.assertEqual(state["recipients"], 2 if startup else 3)
                if startup:
                    completions = [run.proxy.hold_frame(b"Z", index, skipped=30,
                                                       timeout=60) for index in range(2)]
                    for gate in gates:
                        gate.release.set()
                    for gate in completions:
                        self.assertTrue(gate.reached.wait(10))
                    state = run.wait_state(lambda value:
                        sorted(item[1:] for item in value["active"]) == [[10, 1], [11, 1]])
                    actual = {}
                    for connection, messages in enumerate(run.proxy.snapshot()):
                        binds = [name for kind, name in messages if kind == b"B"]
                        self.assertEqual(len(binds), 1)
                        role = 1 if binds[0] == b"\0tags\0" else 2
                        self.assertEqual(binds[0], b"\0tags\0" if role == 1 else b"\0register_user\0")
                        query_id = 10 if role == 1 else 11
                        slots = [slot for slot, ident, _ in state["active"] if ident == query_id]
                        self.assertEqual(len(slots), 1)
                        slot = slots[0]
                        self.assertEqual(state["roles"][slot], role)
                        self.assertNotIn(role, actual)
                        actual[role] = dict(connection=connection, slot=slot,
                            generation=state["generations"][slot], id=query_id,
                            gate=completions[connection])
                    self.assertEqual(set(actual), {1, 2})
                    read, write = actual[1], actual[2]
                else:
                    read = self.split_successor(run, read, 10, 1, [20, 30])
                    write = self.split_successor(run, write, 11, 2, [21, 31])
                self.assertEqual(run.fence()[0], 0)
                read = self.split_successor(run, read, 20, 1, [30], False)
                write = self.split_successor(run, write, 21, 2, [31], False)
                self.assertEqual(run.fence()[0], 0)
                read = self.split_successor(run, read, 30, 1, [])
                write = self.split_successor(run, write, 31, 2, [])
                for entry in (read, write):
                    entry["gate"].release.set()
                    run.result(entry["id"])
                self.assertEqual(run.ready(2)["outstanding"], 0)
                self.assertEqual(run.fence(), {0: 2, 1: 2, 2: 0,
                                               3: 0 if startup else 2})

    def test_split_close_drains_both_queues(self):
        with self.pool_run(writes=1, complete_capture=True) as run:
            self.assertEqual(run.ready(2)["roles"], [1, 2])
            read = self.split_hold(run, "tags 1 0", 1, 1)
            self.split_hold(run, f"register 2 0 s_{uuid.uuid4().hex}",
                            2, 2, [read])
            queued_name = "s_" + uuid.uuid4().hex
            cancelled_name = "s_" + uuid.uuid4().hex
            run.send("tags 3 0", f"register 4 0 {queued_name}",
                     "tags 5 1", f"register 6 1 {cancelled_name}", "cancel 1")
            state = run.state()
            self.assertEqual(state["queued"], [3, 5])
            self.assertEqual(state["write_queued"], [4, 6])
            self.assertEqual(state["outstanding"], 6)
            before = run.proxy.snapshot()
            run.send("close", "close", "tags 7 0",
                     f"register 8 0 s_{uuid.uuid4().hex}")
            for query_id in (1, 2, 3, 4, 7, 8):
                self.assertEqual(run.result(query_id, "lost")["client"], 0)
            state = run.wait_state(lambda value: value["phases"] == [5, 5])
            for key in ("queued", "write_queued", "idle", "active"):
                self.assertEqual(state[key], [], key)
            self.assertEqual(state["recipients"], 0)
            self.assertEqual(state["outstanding"], 0)
            self.assertEqual(run.fence(), {0: 6, 1: 0, 2: 0, 3: 0})
            self.assertEqual(self.db("SELECT count(*) FROM users WHERE username IN ("
                + self.literal(queued_name) + "," + self.literal(cancelled_name)
                + ")"), "0")
            run.proxy.assert_healthy()
            self.assertEqual(run.proxy.snapshot(), before)

        with self.pool_run(writes=1, complete_capture=True) as run:
            run.ready(2)
            before = run.proxy.snapshot()
            run.send("split-close-batch 65 65 100000 900")
            state, counts, prefix = run.checkpoint(900)
            self.assertEqual(prefix, [(i, "data") for i in range(100000, 100064)]
                             + [(i, "lost") for i in range(100064, 100130, 2)]
                             + [(i, "lost") for i in range(100065, 100130, 2)])
            self.assertEqual(counts, {0: 130, 1: 0, 2: 0, 3: 0})
            self.assertEqual(state["phases"], [5, 5])
            self.assertEqual(state["outstanding"], 0)
            self.assertEqual(run.state()["phases"], [5, 5])
            run.proxy.assert_healthy()
            self.assertEqual(run.proxy.snapshot(), before)
        gates = []
        with self.pool_run(writes=1, configure=lambda proxy: gates.extend(
                proxy.hold_frame(b"1", index, timeout=60) for index in range(2))) as run:
            for gate in gates:
                self.assertTrue(gate.reached.wait(5))
            self.assertEqual(run.state()["phases"], [1, 1])
            run.send("tags 1 0", f"register 2 0 s_{uuid.uuid4().hex}", "close")
            run.result(1, "lost")
            run.result(2, "lost")
            self.assertEqual(run.state()["phases"], [5, 5])
            self.assertEqual(run.fence(), {0: 2, 1: 0, 2: 0, 3: 0})
        for role in (1, 2):
            deadline = time.monotonic() + 120
            retry_ns = 600_000_000_000
            self.assertGreater(retry_ns / 1e9, 120)
            with self.subTest(backoff_close=role), self.pool_run(writes=1,
                    retry_ns=retry_ns, deadline=deadline, complete_capture=True) as run:
                run.ready(2)
                command = "tags 1 0" if role == 1 else f"register 1 0 s_{uuid.uuid4().hex}"
                held = self.split_hold(run, command, 1, role)
                run.send(f"retire {held['slot']}")
                run.result(1, "lost")
                state = run.wait_state(lambda value: value["phases"][held["slot"]] == 4)
                token = state["request"]
                opposite = ("tags 4 0" if role == 2 else
                            f"register 4 0 s_{uuid.uuid4().hex}")
                self.split_hold(run, opposite, 4, 3 - role, [held])
                run.send("tags 2 0", f"register 3 0 s_{uuid.uuid4().hex}", "close",
                         f"retry {held['slot']} {token} 1")
                for query_id in (2, 3, 4):
                    run.result(query_id, "lost")
                self.assertEqual(run.state()["phases"], [5, 5])
                self.assertEqual(run.fence(), {0: 4, 1: 0, 2: 0, 3: 0})

    def test_split_dispatch_budget_and_continuation(self):
        for reads, writes in ((65, 65), (63, 0), (64, 0), (65, 0), (130, 0),
                              (0, 63), (0, 64), (0, 65), (0, 130)):
            with self.subTest(reads=reads, writes=writes), self.pool_run(
                    writes=1, complete_capture=True) as run:
                self.assertEqual(run.ready(2)["roles"], [1, 2])
                before = run.proxy.snapshot()
                run.send(f"split-batch {reads} {writes} 100000 900")
                state, counts, prefix = run.checkpoint(900)
                started = min(64, reads + writes)
                self.assertEqual(prefix, [(i, "data")
                                         for i in range(100000, 100000 + started)])
                self.assertEqual(counts, {0: started, 1: 0, 2: 0, 3: 0})
                remaining = list(range(100000 + started, 100000 + reads + writes))
                expected_reads = ([i for i in remaining if i % 2 == 0]
                                  if reads and writes else remaining if reads else [])
                expected_writes = ([i for i in remaining if i % 2 == 1]
                                   if reads and writes else remaining if writes else [])
                self.assertEqual(state["queued"], expected_reads)
                self.assertEqual(state["write_queued"], expected_writes)
                self.assertEqual(state["outstanding"], len(remaining))
                for query_id in range(100000, 100000 + reads + writes):
                    run.result(query_id, "data")
                self.assertEqual(run.ready(2)["outstanding"], 0)
                self.assertEqual(run.fence()[0], reads + writes)
                run.proxy.assert_healthy()
                self.assertEqual(run.proxy.snapshot(), before)
        with self.pool_run(writes=1, complete_capture=True) as run:
            run.ready(2)
            run.send("split-batch 2 1 100000 910")
            _, counts, prefix = run.checkpoint(910)
            self.assertEqual(prefix, [(100000, "data"), (100001, "data"),
                                      (100002, "data")])
            self.assertEqual(counts[0], 3)
            run.send("split-batch 3 3 100003 911")
            _, counts, prefix = run.checkpoint(911)
            self.assertEqual([item[0] for item in prefix[3:]],
                             [100004, 100003, 100006, 100005, 100008, 100007])
            self.assertEqual(counts[0], 9)
        with self.pool_run(writes=1, complete_capture=True) as run:
            run.ready(2)
            before = run.proxy.snapshot()
            run.send("coalescing 920")
            for request, consumed, last in ((920, 64, 100256),
                                             (921, 192, 100512),
                                             (922, 256, 100512)):
                state, counts, prefix = run.checkpoint(request)
                self.assertEqual(prefix, [(i, "data")
                                         for i in range(100000, 100000 + consumed)])
                self.assertEqual(counts, {0: consumed, 1: 0, 2: 0, 3: 0})
                self.assertEqual(state["queued"],
                                 list(range(100000 + consumed, last, 2)))
                self.assertEqual(state["write_queued"],
                                 list(range(100001 + consumed, last, 2)))
            for query_id in range(100000, 100512):
                run.result(query_id, "data")
            self.assertEqual(run.ready(2)["outstanding"], 0)
            self.assertEqual(run.fence()[0], 512)
            run.proxy.assert_healthy()
            self.assertEqual(run.proxy.snapshot(), before)
        for blocked in (1, 2):
            with self.subTest(incompatible=blocked), self.pool_run(
                    writes=1, complete_capture=True) as run:
                run.ready(2)
                command = ("tags 1 3" if blocked == 1 else
                           f"register 1 3 s_{uuid.uuid4().hex}")
                held = self.split_hold(run, command, 1, blocked)
                queued = ("tags 2 3" if blocked == 1 else
                          f"register 2 3 s_{uuid.uuid4().hex}")
                run.send(queued, "incompatible " +
                         ("write" if blocked == 1 else "read") + " 930")
                state, counts, prefix = run.checkpoint(930)
                self.assertEqual(prefix, [(i, "data") for i in range(100000, 100128)])
                self.assertEqual(counts, {0: 128, 1: 0, 2: 0, 3: 0})
                self.assertEqual(state["queued" if blocked == 1 else "write_queued"],
                                 [2])
                self.assertEqual(state["write_queued" if blocked == 1 else "queued"],
                                 list(range(100128, 100320)))
                self.assertEqual(state["active"], [[held["slot"], 1, 1]])
                for query_id in range(100000, 100320):
                    run.result(query_id, "data")
                successor = self.split_successor(run, held, 2, blocked, [])
                successor["gate"].release.set()
                run.result(2)
                self.assertEqual(run.ready(2)["outstanding"], 0)
                self.assertEqual(run.fence(), {0: 320, 1: 0, 2: 0, 3: 2})

    def test_split_completion_and_recovery(self):
        def command(query_id, role, client=0, name=None):
            return (f"tags {query_id} {client}" if role == 1 else
                    f"register {query_id} {client} {name or 's_' + uuid.uuid4().hex}")
        for role in (1, 2):
            for outcome in (1, 2, 3):
                with self.subTest(role=role, outcome=outcome), self.pool_run(
                        writes=1, complete_capture=True) as run:
                    self.assertEqual(run.ready(2)["roles"], [1, 2])
                    sql = command(1, role)
                    if outcome == 2:
                        sql = "raw-error 1 0 " + ("read" if role == 1 else "write")
                    if outcome == 3:
                        run.proxy.corrupt_next_data_row()
                    held = self.split_hold(run, sql, 1, role, outcome=outcome)
                    if outcome == 3:
                        self.assertEqual(run.proxy.row_corruptions, [held["connection"]])
                        run.result(1, "data")
                    self.assertEqual(run.fence()[0], 1 if outcome == 3 else 0)
                    run.send(command(2, role), command(3, 3 - role, client=1))
                    run.result(3)
                    state = run.state()
                    self.assertEqual(state["queued" if role == 1 else "write_queued"], [2])
                    self.assertEqual(state["active"], [[held["slot"], 1, outcome]])
                    gate = run.proxy.hold_frame(b"Z", held["connection"], timeout=60)
                    held["gate"].release.set()
                    if outcome != 3:
                        run.result(1, "ok" if outcome == 1 else "22012")
                    self.assertTrue(gate.reached.wait(5))
                    run.wait_state(lambda value: [held["slot"], 2, 1] in value["active"])
                    self.assertEqual(run.fence()[0], 1)
                    gate.release.set()
                    run.result(2)
                    run.ready(2)
                    for mode in ("invalid-array", "invalid-nul"):
                        selector = "tags" if role == 1 else "register_user"
                        run.send(f"{mode} 4 0 {selector}")
                        run.result(4, "data")
                    self.assertEqual(run.fence(), {0: 4, 1: 1, 2: 0, 3: 0})
                    self.assertEqual(run.state()["outstanding"], 0)
                    run.proxy.assert_healthy()
        for role in (1, 2):
            deadline = time.monotonic() + 120
            retry_ns = 600_000_000_000
            self.assertGreater(retry_ns / 1e9, 120)
            with self.subTest(recovery_role=role), self.pool_run(
                    writes=1, retry_ns=retry_ns, deadline=deadline,
                    complete_capture=True) as run:
                run.ready(2)
                name = "s_" + uuid.uuid4().hex
                held = self.split_hold(run, command(10, role, name=name), 10, role)
                run.send(f"save-connection {held['slot']}", command(11, role),
                         f"retire {held['slot']}")
                run.result(10, "lost")
                backoff = run.wait_state(lambda value: value["phases"][held["slot"]] == 4)
                first_token = backoff["request"]
                self.assertEqual(backoff["generations"][held["slot"]], 1)
                self.assertEqual(backoff["roles"], [1, 2])
                self.assertEqual(backoff["queued" if role == 1 else "write_queued"], [11])
                if role == 2:
                    with SQLSession(self.database, deadline=deadline) as sql:
                        self.assertEqual(sql.execute("SELECT count(*) FROM users WHERE username="
                                                    + self.literal(name) + ";"), ["1"])
                run.send(command(20, 3 - role, client=1))
                run.result(20)
                replacement = len(run.proxy.snapshot())
                prepare_gate = run.proxy.hold_frame(b"1", replacement, timeout=60)
                run.send(f"retry {held['slot']} {first_token} 1")
                self.assertTrue(prepare_gate.reached.wait(run.remaining(5, "replacement preparation")))
                preparing = run.wait_state(lambda value: value["phases"][held["slot"]] == 1)
                self.assertEqual(preparing["queued" if role == 1 else "write_queued"], [11])
                gate = run.proxy.hold_frame(b"Z", replacement, skipped=30, timeout=60)
                prepare_gate.release.set()
                self.assertTrue(gate.reached.wait(run.remaining(10, "replacement query completion")))
                current = run.wait_state(lambda value: [held["slot"], 11, 1] in value["active"])
                self.assertEqual(current["roles"][held["slot"]], role)
                captures = run.proxy.snapshot()[replacement]
                self.assertEqual(sum(kind == b"P" for kind, _ in captures), 30)
                self.assertEqual([name for kind, name in captures if kind == b"B"],
                                 [b"\0tags\0" if role == 1 else b"\0register_user\0"])
                for same in ("old", "same"):
                    request = 500 if same == "old" else 501
                    run.send(f"stale-callbacks {held['slot']} {same} {request}")
                    after, counts, _ = run.checkpoint(request)
                    self.assertEqual(after["active"], current["active"])
                    self.assertEqual(after["generations"], current["generations"])
                    self.assertEqual(after["phases"], current["phases"])
                    self.assertEqual(counts, {0: 1, 1: 1, 2: 0, 3: 0})
                gate.release.set()
                run.result(11)
                run.ready(2)
                run.send(f"retire {held['slot']}")
                second = run.wait_state(lambda value: value["phases"][held["slot"]] == 4)
                second_token = second["request"]
                self.assertEqual(second["generations"][held["slot"]], 2)
                for token, generation in ((first_token, 2), (second_token, 1)):
                    run.send(f"retry {held['slot']} {token} {generation}")
                    state = run.state()
                    self.assertEqual(state["phases"][held["slot"]], 4)
                    self.assertEqual(state["generations"][held["slot"]], 2)
                run.send(f"retry {held['slot']} {second_token} 2")
                run.ready(2)
                run.send(command(12, role))
                run.result(12)
                if role == 2:
                    with SQLSession(self.database, deadline=deadline) as sql:
                        self.assertEqual(sql.execute("SELECT count(*) FROM users WHERE username="
                                                    + self.literal(name) + ";"), ["1"])
                run.send("close", f"retry {held['slot']} {second_token} 2")
                self.assertEqual(run.state()["phases"], [5, 5])
                self.assertEqual(run.fence(), {0: 3, 1: 1, 2: 0, 3: 0})
                run.proxy.assert_healthy()

        for role in (1, 2):
            for busy in (False, True):
                deadline = time.monotonic() + 120
                self.assertGreater(600_000_000_000 / 1e9, 120)
                with self.subTest(retire_role=role, busy=busy), self.pool_run(
                        count=4, writes=2, retry_ns=600_000_000_000,
                        deadline=deadline, complete_capture=True) as run:
                    self.assertEqual(run.ready(4)["roles"], [1, 1, 2, 2])
                    held = []
                    for query_id, selected_role in enumerate((1, 1, 2, 2), 1):
                        held.append(self.split_hold(run, command(query_id, selected_role),
                                                    query_id, selected_role, held))
                    victim = next(entry for entry in held
                                  if (1 if entry["slot"] < 2 else 2) == role)
                    if not busy:
                        victim["gate"].release.set()
                        run.result(victim["id"])
                        run.wait_state(lambda value: value["phases"][victim["slot"]] == 2)
                    run.send(f"retire {victim['slot']}")
                    if busy:
                        run.result(victim["id"], "lost")
                    state = run.wait_state(lambda value: value["phases"][victim["slot"]] == 4)
                    expected_generations = [0] * 4
                    expected_generations[victim["slot"]] = 1
                    self.assertEqual(state["generations"], expected_generations)
                    self.assertEqual(state["roles"], [1, 1, 2, 2])
                    survivors = [entry for entry in held if entry is not victim]
                    self.assertEqual(sorted(state["active"]),
                                     sorted([entry["slot"], entry["id"], 1] for entry in survivors))
                    self.assertEqual(state["idle"], [])
                    for entry in survivors:
                        entry["gate"].release.set()
                        run.result(entry["id"])
                    expected_phases = [2] * 4
                    expected_phases[victim["slot"]] = 4
                    run.wait_state(lambda value: value["phases"] == expected_phases)
                    exercised = []
                    for query_id, entry in enumerate(survivors, 20):
                        selected_role = 1 if entry["slot"] < 2 else 2
                        exercised.append(self.split_hold(run, command(query_id, selected_role),
                            query_id, selected_role, [victim, *exercised]))
                    self.assertEqual({entry["slot"] for entry in exercised},
                                     {entry["slot"] for entry in survivors})
                    for entry in exercised:
                        entry["gate"].release.set()
                        run.result(entry["id"])
                    self.assertEqual(run.fence(), {0: 7, 1: 0, 2: 0, 3: 0})
            deadline = time.monotonic() + 120
            self.assertGreater(600_000_000_000 / 1e9, 120)
            with self.subTest(prepare_failure=role), self.pool_run(writes=1,
                    retry_ns=600_000_000_000, deadline=deadline,
                    complete_capture=True) as run:
                run.ready(2)
                held = self.split_hold(run, command(1, role), 1, role)
                held["gate"].release.set()
                run.result(1)
                run.send(f"retire {held['slot']}", command(2, role))
                state = run.wait_state(lambda value: value["phases"][held["slot"]] == 4)
                replacement = len(run.proxy.snapshot())
                run.proxy.replace_prepare(replacement, b"tags")
                run.send(f"retry {held['slot']} {state['request']} 1")
                failed = run.wait_state(lambda value: value["phases"][held["slot"]] == 4
                                        and value["generations"][held["slot"]] == 2)
                self.assertEqual(run.proxy.prepare_receipts, [(replacement, b"tags")])
                self.assertEqual(failed["queued" if role == 1 else "write_queued"], [2])
                self.assertEqual(run.fence()[0], 1)
                run.send(command(3, 3 - role, client=1))
                run.result(3)
                replacement = len(run.proxy.snapshot())
                gate = run.proxy.hold_frame(b"Z", replacement, skipped=31, timeout=60)
                run.send(f"retry {held['slot']} {failed['request']} 2")
                self.assertTrue(gate.reached.wait(run.remaining(10, "recovered prepared execution")))
                state = run.wait_state(lambda value: [held["slot"], 2, 1] in value["active"])
                self.assertEqual(state["roles"][held["slot"]], role)
                messages = run.proxy.snapshot()[replacement]
                self.assertEqual(sum(kind == b"P" for kind, _ in messages), 30)
                self.assertEqual([name for kind, name in messages if kind == b"B"],
                                 [b"\0tags\0" if role == 1 else b"\0register_user\0"])
                gate.release.set()
                run.result(2)
                run.ready(2)
                run.proxy.assert_healthy()
            deadline = time.monotonic() + 120
            self.assertGreater(600_000_000_000 / 1e9, 120)
            with self.subTest(nonidle_missing_statement=role), self.pool_run(
                    writes=1, retry_ns=600_000_000_000, deadline=deadline,
                    complete_capture=True) as run:
                self.assertEqual(run.ready(2)["roles"], [1, 2])
                run.send("begin 1 0 " + ("read" if role == 1 else "write"))
                run.result(1, "lost")
                state = run.wait_state(lambda value: 4 in value["phases"])
                slot = state["phases"].index(4)
                self.assertEqual(state["roles"][slot], role)
                run.send(f"retry {slot} {state['request']} 1")
                run.ready(2)
                run.send("deallocate 2 0 " + ("read" if role == 1 else "write"))
                run.result(2)
                run.send(command(3, role))
                run.result(3, "26000")
                state = run.wait_state(lambda value: value["phases"][slot] == 4)
                self.assertEqual(state["generations"][slot], 2)
                run.send(command(4, 3 - role, client=1))
                run.result(4)
                self.assertEqual(run.fence(), {0: 3, 1: 1, 2: 0, 3: 0})
            for action in ("retire", "close"):
                deadline = time.monotonic() + 120
                self.assertGreater(600_000_000_000 / 1e9, 120)
                with self.subTest(data_error_role=role, action=action), self.pool_run(
                        writes=1, retry_ns=600_000_000_000, deadline=deadline,
                        complete_capture=True) as run:
                    run.ready(2)
                    run.proxy.corrupt_next_data_row()
                    held = self.split_hold(run, command(1, role), 1, role, outcome=3)
                    run.result(1, "data")
                    run.send(command(2, role), "close" if action == "close"
                             else f"retire {held['slot']}")
                    if action == "close":
                        run.result(2, "lost")
                        self.assertEqual(run.state()["phases"], [5, 5])
                    else:
                        state = run.wait_state(lambda value: value["phases"][held["slot"]] == 4)
                        self.assertEqual(run.fence()[0], 1)
                        run.send(f"retry {held['slot']} {state['request']} 1")
                        run.result(2)
                        run.ready(2)
                    self.assertEqual(run.fence(), {0: 2, 1: 0, 2: 0, 3: 0})

    def test_split_http_continuations_and_durability(self):
        author = self.author()
        token = self.token(author)
        title = "split_http_" + uuid.uuid4().hex
        article_id = self.db("INSERT INTO articles(slug,author_id,title,description,body) "
            f"VALUES ('{title}',{author},'{title}','description','original') RETURNING id")
        article_id = int(article_id.splitlines()[0])
        with self.pool_run(count=2, writes=4, csv=True, listener=True,
                           complete_capture=True) as run:
            for worker in range(4):
                state = run.wait_state(lambda value: value["phases"] == [2, 2], worker=worker)
                self.assertEqual(state["roles"], [1, 2])
            held = []
            mapping = {}
            for worker in range(4):
                for role in (1, 2):
                    query_id = 1000 + worker * 2 + role
                    command = (f"tags {query_id} 3" if role == 1 else
                               f"register {query_id} 3 s_{uuid.uuid4().hex}")
                    entry = self.split_hold(run, command, query_id, role, held,
                                            worker=worker)
                    mapping[(worker, entry["slot"])] = entry
                    held.append(entry)
            self.assertEqual(len({entry["connection"] for entry in held}), 8)
            for entry in held:
                entry["gate"].release.set()
                run.result(entry["id"])
            for worker in range(4):
                run.wait_state(lambda value: value["phases"] == [2, 2], worker=worker)
            cases = [
                ("PUT", "/api/articles/" + title, {"article": {"body": "changed"}},
                 [(18, "article_update_input", 1), (19, "article_update", 2),
                  (15, "article_full_by_id", 1)], 200),
                ("POST", "/api/articles", self.article(title + "_new", [title + "_tag"]),
                 [(16, "article_insert", 2), (15, "article_full_by_id", 1)], 201),
                ("POST", "/api/articles/" + title + "/comments",
                 {"comment": {"body": title + "_comment"}},
                 [(25, "comment_input", 1), (26, "comment_insert", 2)], 201)]
            for method, path, body, stages, expected_status in cases:
                with self.subTest(method=method, path=path):
                    connection = self.routing_connect(run.port)
                    try:
                        baseline = run.proxy.snapshot()
                        gates = {entry["connection"]: run.proxy.hold_frame(
                            b"Z", entry["connection"], timeout=60) for entry in held}
                        history_start = len(run.history)
                        connection.request(method, path, json.dumps(body),
                            {"Content-Type": "application/json", "Authorization": "Token " + token})
                        accepted = run.receive(lambda value: value.get("event") == "accepted")
                        client = accepted["connection"]
                        request_id = accepted["id"]
                        assigned = None
                        for ordinal, (kind, name, role) in enumerate(stages):
                            sql = run.receive(lambda value: value.get("event") == "sql"
                                and value["connection"] == client and value["id"] == request_id)
                            self.assertEqual(sql["kind"], kind)
                            matches = []
                            deadline = time.monotonic() + 10
                            while not matches:
                                self.assertLess(time.monotonic(), deadline,
                                                "HTTP active stage deadline")
                                for worker in range(4):
                                    state = run.state(worker, deadline=deadline)
                                    for slot, query_id, outcome in state["active"]:
                                        if query_id == request_id and outcome == 1:
                                            matches.append((worker, slot, state))
                            self.assertEqual(len(matches), 1)
                            worker, slot, state = matches[0]
                            if assigned is None:
                                assigned = worker
                            self.assertEqual(worker, assigned)
                            self.assertEqual(state["roles"][slot], role)
                            entry = mapping[(worker, slot)]
                            self.assertEqual(state["generations"][slot], entry["generation"])
                            self.assertTrue(gates[entry["connection"]].reached.wait(5))
                            run.proxy.assert_healthy()
                            current = run.proxy.snapshot()
                            new_binds = [(index, captured) for index, messages in enumerate(current)
                                         for tag, captured in messages[len(baseline[index]):]
                                         if tag == b"B"]
                            self.assertEqual(new_binds,
                                             [(entry["connection"], b"\0" + name.encode() + b"\0")])
                            checkpoint = 700 + ordinal
                            run.send(f"connstate {client} {checkpoint}")
                            application = run.receive(lambda value:
                                value.get("event") == "connection" and
                                value["connection"] == client and value["request"] == checkpoint)
                            self.assertEqual(application["pending"], 0)
                            run.receive(lambda value: value.get("event") == "application_fence"
                                and value["connection"] == client and value["request"] == checkpoint)
                            selected = gates[entry["connection"]]
                            with run.proxy.lock:
                                for gate in gates.values():
                                    if gate is not selected:
                                        gate.claimed = True
                                        gate.release.set()
                            baseline = current
                            if ordinal + 1 < len(stages):
                                gates = {entry["connection"]: run.proxy.hold_frame(
                                    b"Z", entry["connection"], timeout=60) for entry in held}
                            selected.release.set()
                        response = connection.getresponse()
                        result = json.loads(response.read())
                        self.assertEqual(response.status, expected_status)
                        if method == "PUT":
                            self.assertEqual(result["article"]["body"], "changed")
                            self.assertEqual(result["article"]["slug"], title)
                            self.assertEqual(self.db(f"SELECT body FROM articles WHERE id={article_id}"),
                                             "changed")
                        elif path.endswith("comments"):
                            self.assertEqual(result["comment"]["body"], title + "_comment")
                            self.assertEqual(self.db("SELECT count(*) FROM comments WHERE body="
                                + self.literal(title + "_comment")), "1")
                        else:
                            self.assertEqual(result["article"]["title"], title + "_new")
                            self.assertEqual(result["article"]["tagList"], [title + "_tag"])
                            self.assertEqual(self.db("SELECT count(*) FROM articles a JOIN article_tags "
                                "at ON at.article_id=a.id JOIN tags t ON t.id=at.tag_id WHERE a.title="
                                + self.literal(title + "_new") + " AND t.name="
                                + self.literal(title + "_tag")), "1")
                        run.send(f"connstate {client} 799")
                        final = run.receive(lambda value: value.get("event") == "connection"
                            and value["connection"] == client and value["request"] == 799)
                        run.receive(lambda value: value.get("event") == "application_fence"
                            and value["connection"] == client and value["request"] == 799)
                        self.assertEqual(final["operations"], 0)
                        self.assertEqual([value["kind"] for value in run.history[history_start:]
                            if value.get("event") == "sql" and value["connection"] == client],
                            [stage[0] for stage in stages])
                    finally:
                        connection.close()
            original_port = type(self).port
            try:
                type(self).port = run.port
                self.test_direct_json_response_wiring()
                self.test_article_failure_is_atomic()
                self.test_submitted_write_survives_http_close()
                self.test_pipelined_response_order()
            finally:
                type(self).port = original_port

    def test_split_aggregate_diagnostics_and_csv(self):
        with self.pool_run(writes=1, complete_capture=True, csv=True) as run:
            run.ready(2)
            read = self.split_hold(run, "tags 1 0", 1, 1)
            write = self.split_hold(run, f"register 2 0 s_{uuid.uuid4().hex}",
                                    2, 2, [read])
            run.send("tags 3 0", "tags 5 0", f"register 4 0 s_{uuid.uuid4().hex}",
                     f"register 6 0 s_{uuid.uuid4().hex}")
            self.assertEqual(run.barrier(), 4)
            state = run.state()
            self.assertEqual(state["queued"], [3, 5])
            self.assertEqual(state["write_queued"], [4, 6])
            self.assertEqual(state["outstanding"], 6)
            sample = run.csv_sample()
            self.assertEqual(sample["pending"], 4)
            self.assertEqual(sample["busy"], 2)
            if _diagnostic_mode():
                gauges = run.diag()["gauges"]
                self.assertEqual(gauges[0], 4)
                self.assertEqual(gauges[1], 2)
                self.assertGreater(gauges[2], 0)
                self.assertEqual(gauges[3], 4)
            read["gate"].release.set()
            for query_id in (1, 3, 5):
                run.result(query_id)
            self.assertEqual(run.barrier(), 2)
            self.assertEqual(run.csv_sample()["pending"], 2)
            if _diagnostic_mode():
                self.assertEqual(run.diag()["gauges"][0], 2)
            write["gate"].release.set()
            for query_id in (2, 4, 6):
                run.result(query_id)
            run.ready(2)
            self.assertEqual(run.barrier(), 0)
            self.assertEqual(run.csv_sample()["pending"], 0)
            if _diagnostic_mode():
                self.assertEqual(run.diag()["gauges"][:4], [0, 0, 0, 4])
        if not _diagnostic_mode():
            return
        for first_role in (1, 2):
            with self.subTest(first_role=first_role), self.pool_run(
                    writes=1, complete_capture=True) as run:
                run.ready(2)
                def command(query_id, role):
                    return (f"tags {query_id} 0" if role == 1 else
                            f"register {query_id} 0 s_{uuid.uuid4().hex}")
                first = self.split_hold(run, command(1, first_role), 1, first_role)
                second = self.split_hold(run, command(2, 3 - first_role),
                                         2, 3 - first_role, [first])
                before_first = run.diag()["observed_ns"]
                run.send(command(3, first_role))
                after_first = run.diag()["observed_ns"]
                before_second = run.diag()["observed_ns"]
                self.assertLess(after_first, before_second)
                run.send(command(4, 3 - first_role))
                after_second = run.diag()["observed_ns"]
                def oldest_between(snapshot, before, after):
                    enqueue = snapshot["observed_ns"] - snapshot["gauges"][2]
                    self.assertGreaterEqual(enqueue, before)
                    self.assertLessEqual(enqueue, after)
                a = run.diag()
                b = run.diag()
                oldest_between(a, before_first, after_first)
                oldest_between(b, before_first, after_first)
                self.assertEqual(b["gauges"][2] - a["gauges"][2],
                                 b["observed_ns"] - a["observed_ns"])
                first = self.split_successor(run, first, 3, first_role, [])
                oldest_between(run.diag(), before_second, after_second)
                second = self.split_successor(run, second, 4, 3 - first_role, [])
                self.assertEqual(run.diag()["gauges"][2], 0)
                for held in (first, second):
                    held["gate"].release.set()
                    run.result(held["id"])
                run.ready(2)
        for first_role in (1, 2):
            with self.subTest(peak_first=first_role), self.pool_run(
                    writes=1, complete_capture=True) as run:
                run.ready(2)
                for first_id, role, count in ((1, first_role, 3), (10, 3 - first_role, 5)):
                    def command(query_id):
                        return (f"tags {query_id} 0" if role == 1 else
                                f"register {query_id} 0 s_{uuid.uuid4().hex}")
                    held = self.split_hold(run, command(first_id), first_id, role)
                    run.send(*(command(i) for i in range(first_id + 1, first_id + count + 1)))
                    self.assertEqual(run.diag()["gauges"][3], count)
                    held["gate"].release.set()
                    for query_id in range(first_id, first_id + count + 1):
                        run.result(query_id)
                    run.ready(2)
                    self.assertEqual(run.diag()["gauges"][0], 0)
                self.assertEqual(run.diag()["gauges"][3], 5)

    def test_split_capture_limits_and_mapping(self):
        def capture_case(groups, **limits):
            with socket.socket() as backend_listener:
                backend_listener.bind(("127.0.0.1", 0))
                backend_listener.listen(8)
                backend_listener.settimeout(5)
                failures = []
                forwarded = []
                def upstream():
                    try:
                        for frames in groups:
                            connection, _ = backend_listener.accept()
                            with connection:
                                connection.settimeout(5)
                                try:
                                    length = int.from_bytes(ProtocolConnection.read_exact(connection, 4), "big")
                                except EOFError:
                                    continue
                                ProtocolConnection.read_exact(connection, length - 4)
                                for _ in frames:
                                    try:
                                        kind = ProtocolConnection.read_exact(connection, 1)
                                        size = ProtocolConnection.read_exact(connection, 4)
                                        payload = ProtocolConnection.read_exact(connection,
                                            int.from_bytes(size, "big") - 4)
                                        forwarded.append((kind, payload))
                                    except EOFError:
                                        break
                    except Exception as failure:
                        failures.append(repr(failure))
                thread = threading.Thread(target=upstream)
                thread.start()
                proxy = ProtocolProxy("127.0.0.1", backend_listener.getsockname()[1],
                                      complete_capture=True, **limits)
                try:
                    for frames in groups:
                        with socket.create_connection(proxy.server_address, timeout=5) as connection:
                            connection.settimeout(5)
                            connection.sendall(struct.pack("!II", 8, 196608))
                            for kind, payload in frames:
                                connection.sendall(kind + struct.pack("!I", len(payload) + 4) + payload)
                            try:
                                self.assertEqual(connection.recv(1), b"")
                            except ConnectionResetError:
                                pass
                        with proxy.lock:
                            handlers = list(proxy.handlers)
                        for handler in handlers:
                            handler.join(timeout=5)
                            self.assertFalse(handler.is_alive())
                finally:
                    proxy.stop()
                    thread.join(timeout=5)
                self.assertFalse(thread.is_alive())
                self.assertEqual(failures, [])
                return proxy.snapshot(), proxy.failures, forwarded
        for field in ("parse", "portal", "statement"):
            for size in (7, 8, 9):
                with self.subTest(field=field, size=size):
                    name = b"x" * size
                    if field == "parse":
                        kind, payload = b"P", name + b"\0SELECT 1\0\0\0"
                        expected = name + b"\0"
                    elif field == "portal":
                        kind, payload = b"B", name + b"\0s\0" + b"\0" * 6
                        expected = name + b"\0s\0"
                    else:
                        kind, payload = b"B", b"p\0" + name + b"\0" + b"\0" * 6
                        expected = b"p\0" + name + b"\0"
                    records, failures, forwarded = capture_case([[(kind, payload)]], name_limit=8)
                    if size <= 8:
                        self.assertEqual(records, [[(kind, expected)]])
                        self.assertEqual(failures, [])
                        self.assertEqual(forwarded, [(kind, payload)])
                    else:
                        self.assertEqual(records, [[]])
                        self.assertEqual(failures, ["captured name length limit"])
                        self.assertEqual(forwarded, [])
        bind = (b"B", b"\0xxxxxxxx\0" + b"\0" * 6)
        records, failures, forwarded = capture_case([[bind]], name_limit=8)
        self.assertEqual(records, [[(b"B", b"\0xxxxxxxx\0")]])
        self.assertEqual(failures, [])
        self.assertEqual(forwarded, [bind])
        parse = (b"P", b"abc\0SELECT 1\0\0\0")
        for groups, limits, expected_error in (
                ([[parse, parse]], {"record_limit": 1}, "capture record limit"),
                ([[parse, parse]], {"name_bytes_limit": 4}, "capture total name bytes limit"),
                ([[parse], [parse]], {"capacity": 1}, "capture connection lifetime limit")):
            with self.subTest(limit=limits):
                records, failures, forwarded = capture_case(groups, **limits)
                self.assertEqual(records, [[(b"P", b"abc\0")]])
                self.assertEqual(failures, [expected_error])
                self.assertEqual(forwarded, [parse])
        for frame in ((b"P", b"unterminated"), (b"B", b"portal\0unterminated")):
            records, failures, forwarded = capture_case([[frame]])
            self.assertEqual(records, [[]])
            self.assertEqual(failures, ["unterminated captured name"])
            self.assertEqual(forwarded, [])
        process = None
        proxy = None
        with self.assertRaisesRegex(AssertionError, "deliberate held-gate failure"):
            with self.pool_run(writes=1, complete_capture=True) as run:
                process, proxy = run.process, run.proxy
                run.ready(2)
                self.split_hold(run, "tags 1 0", 1, 1)
                self.fail("deliberate held-gate failure")
        self.assertEqual(process.returncode, 0)
        self.assertFalse(proxy.thread.is_alive())
        self.assertTrue(all(not thread.is_alive() for thread in proxy.handlers))
        proxy.assert_healthy()
        with self.pool_run(writes=1, complete_capture=True) as run:
            initial = run.ready(2)
            self.assertEqual(initial["roles"], [1, 2])
            before = run.proxy.snapshot()
            held = self.split_hold(run, "tags 1 0", 1, 1)
            state = run.state()
            after = run.proxy.snapshot()
            expected = (held["connection"], held["slot"], b"\0tags\0")
            self.assertEqual(self.split_mapping(before, after, state,
                initial["generations"], 1, 1), expected)
            with self.assertRaisesRegex(AssertionError, "mapping Bind count"):
                self.split_mapping(before, before, state, initial["generations"], 1, 1)
            duplicate = [list(messages) for messages in after]
            duplicate[held["connection"]].append((b"B", b"\0tags\0"))
            with self.assertRaisesRegex(AssertionError, "mapping Bind count"):
                self.split_mapping(before, duplicate, state, initial["generations"], 1, 1)
            with self.assertRaisesRegex(AssertionError, "mapping role mismatch"):
                self.split_mapping(before, after, state, initial["generations"], 1, 2)
            stale = initial["generations"].copy()
            stale[held["slot"]] += 1
            with self.assertRaisesRegex(AssertionError, "mapping generation mismatch"):
                self.split_mapping(before, after, state, stale, 1, 1)
            held["gate"].release.set()
            run.result(1)
        with self.assertRaisesRegex(AssertionError, "scenario deadline before pool fixture"):
            with self.pool_run(writes=1, deadline=time.monotonic() - 1):
                self.fail("expired fixture was created")
        deadline = time.monotonic() + 120
        self.assertGreater(600_000_000_000 / 1e9, 120)
        with self.pool_run(writes=1, retry_ns=600_000_000_000,
                           deadline=deadline) as run:
            run.ready(2)
            run.send("retire 0")
            run.wait_state(lambda value: value["phases"][0] == 4)
            with self.assertRaisesRegex(AssertionError, "suppressed manual retry timed out"):
                run.wait_state(lambda value: value["phases"][0] == 2, timeout=0.1,
                               event_name="suppressed manual retry")
            run.send("state 999")
            self.assertTrue(run.selector.select(5))
            run.deadline = time.monotonic() - 1
            try:
                with self.assertRaisesRegex(AssertionError, "scenario deadline: late state"):
                    run.receive(lambda value: value.get("request") == 999,
                                timeout=10, event_name="late state")
                with self.assertRaisesRegex(AssertionError, "scenario deadline: send pool command"):
                    run.send("retry 0 1 1")
            finally:
                run.deadline = deadline
            run.receive(lambda value: value.get("event") == "state" and value["request"] == 999)
            run.send("close")
            self.assertEqual(run.state()["phases"], [5, 5])

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
                connection.sock.sendall(request * count)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    after = self.routing_binds(proxy)
                    self.assertEqual(len(after), len(before))
                    changes = {index: names[len(before[index]):]
                               for index, names in enumerate(after)
                               if names != before[index]}
                    if sum(map(len, changes.values())) >= count:
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
        result = subprocess.run([str(executable), "--test-named-rollback",
                                 "--db-write-sessions=95"],
                                env=self.server_env | {
                                    "CONDUIT_TEST_POOL_SIZE": "invalid"},
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
            env["CONDUIT_TEST_POOL_SIZE"] = "invalid"
            executable = _executable()
            process = subprocess.Popen(
                [str(executable), "--ponymaxthreads=1", "--test-dns-progress",
                 "--db-write-sessions=95"],
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
        result = subprocess.run([str(executable), "--test-session-boundary",
                                 "--db-write-sessions=95"],
                                env=self.server_env | {
                                    "CONDUIT_TEST_POOL_SIZE": "invalid"},
                                capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, _failure_output(result.stderr))
        self.assertEqual(result.stdout.strip(), "session boundaries passed")

    def test_session_shutdown_settles_accepted_commands(self):
        executable = _executable()
        result = subprocess.run([str(executable), "--test-session-shutdown",
                                 "--db-write-sessions=95"],
                                env=self.server_env | {
                                    "CONDUIT_TEST_POOL_SIZE": "invalid"},
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
            env["CONDUIT_TEST_POOL_SIZE"] = "invalid"
            executable = _executable()
            process = subprocess.Popen([str(executable),
                                        "--test-startup-shutdown",
                                        "--db-write-sessions=95"], env=env,
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
        result = subprocess.run([str(executable), "--test-connection-nul",
                                 "--db-write-sessions=95"],
                                env=self.server_env | {
                                    "CONDUIT_TEST_POOL_SIZE": "invalid"},
                                capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, _failure_output(result.stderr))
        self.assertEqual(result.stdout.strip(),
                         "connection fields rejected NUL")

    def test_result_shapes_reject_nested_arrays_and_keep_infinities(self):
        executable = _executable()
        result = subprocess.run([str(executable), "--test-result-shapes",
                                 "--db-write-sessions=95"],
                                env=self.server_env | {
                                    "CONDUIT_TEST_POOL_SIZE": "invalid"},
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
            "CONDUIT_QUERY_ROOT_CONTROL": control,
            "CONDUIT_TEST_POOL_SIZE": "invalid"}
        env.pop("LD_PRELOAD", None)
        if library is not None:
            env["LD_PRELOAD"] = str(library)
        result = subprocess.run(
            [str(_executable()), "--test-query-storage", "--ponymaxthreads=1",
             "--db-write-sessions=95"],
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
                "CONDUIT_TEST_DECODE_VALUE": str(value),
                "CONDUIT_TEST_POOL_SIZE": "invalid"}
            flag = "--test-decode-scalar"
            if atomic is not None:
                flag = "--test-decode-atomic"
                env["CONDUIT_TEST_DECODE_ATOMIC_CASE"] = atomic
            result = subprocess.run(
                [str(_executable()), flag, "--ponymaxthreads=2",
                 "--db-write-sessions=95"], env=env,
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
        result = subprocess.run([str(executable), "--test-queue-drain",
                                 "--db-write-sessions=95"],
                                env=self.server_env | {
                                    "CONDUIT_TEST_POOL_SIZE": "invalid"},
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
        for writes in (0, 1):
            with self.subTest(writes=writes):
                self._presend_data_error_keeps_worker_query_order(writes)

    def _presend_data_error_keeps_worker_query_order(self, writes):
        before = len(self.proxy.snapshot())
        executable = _executable()
        result = subprocess.run([str(executable), "--test-worker-data-error",
                                 f"--db-write-sessions={writes}"],
                                env=self.server_env | {
                                    "CONDUIT_TEST_POOL_SIZE": "2" if writes else "1"},
                                capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, _failure_output(result.stderr))
        self.assertEqual(result.stdout.strip(),
                         "worker data errors followed by query passed")
        sessions = self.proxy.snapshot()[before:]
        bound = [[payload.split(b"\0", 2)[1] for kind, payload
                  in session if kind == b"B"] for session in sessions]
        self.assertEqual([names for names in bound if names], [[b"tags"]])
        self.assertIn(len(sessions), (1, 2) if writes else (1,))

    def test_decode_data_error_keeps_worker_query_order(self):
        for writes in (0, 1):
            with self.subTest(writes=writes):
                self._decode_data_error_keeps_worker_query_order(writes)

    def _decode_data_error_keeps_worker_query_order(self, writes):
        self.assertGreater(int(self.db("SELECT count(*) FROM tags")), 0)
        before = len(self.proxy.snapshot())
        self.proxy.corrupt_next_data_row()
        executable = _executable()
        result = subprocess.run([str(executable), "--test-worker-decode-error",
                                 f"--db-write-sessions={writes}"],
                                env=self.server_env | {
                                    "CONDUIT_TEST_POOL_SIZE": "2" if writes else "1"},
                                capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, _failure_output(result.stderr))
        self.assertEqual(result.stdout.strip(),
                         "worker decode error followed by query passed")
        sessions = self.proxy.snapshot()[before:]
        bound = [[payload.split(b"\0", 2)[1] for kind, payload
                  in session if kind == b"B"] for session in sessions]
        self.assertEqual([names for names in bound if names], [[b"tags", b"tags"]])
        self.assertIn(len(sessions), (1, 2) if writes else (1,))

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
        for writes in (0, 1):
            with self.subTest(writes=writes):
                self._shared_worker_cancellation_preserves_other_client(writes)

    def _shared_worker_cancellation_preserves_other_client(self, writes):
        executable = _executable()
        before = len(self.proxy.snapshot())
        self.proxy.hold_command_complete_after(1)
        process = subprocess.Popen(
            [str(executable), "--test-worker-overlap", f"--db-write-sessions={writes}"],
            env=self.server_env | {"CONDUIT_TEST_POOL_SIZE": "2" if writes else "1"},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1)
        try:
            self.probe_line(process, "overlap accepted")
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                sessions = self.proxy.snapshot()[before:]
                if sessions and any(kind == b"B" and
                        payload.split(b"\0", 2)[1] == b"tags"
                        for session in sessions for kind, payload in session):
                    break
                time.sleep(0.01)
            else:
                self.fail("first client's query did not reach PostgreSQL")
            self.proxy.release_command_complete()
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, _failure_output(stderr))
            self.assertEqual(stdout.strip(), "surviving client passed")
            sessions = self.proxy.snapshot()[before:]
            bound = [[payload.split(b"\0", 2)[1] for kind, payload
                      in session if kind == b"B"] for session in sessions]
            self.assertEqual([names for names in bound if names],
                             [[b"current_user", b"tags", b"profile"]])
            self.assertIn(len(sessions), (1, 2) if writes else (1,))
        finally:
            self.proxy.release_command_complete(abort=True)
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)

    def test_explicit_worker_close_fails_each_submitted_job(self):
        for writes in (0, 1):
            with self.subTest(writes=writes):
                self._explicit_worker_close_fails_each_submitted_job(writes)

    def _explicit_worker_close_fails_each_submitted_job(self, writes):
        executable = _executable()
        self.proxy.hold_command_complete_after(1)
        process = subprocess.Popen(
            [str(executable), "--test-worker-close-drain", f"--db-write-sessions={writes}"],
            env=self.server_env | {"CONDUIT_TEST_POOL_SIZE": "2" if writes else "1"},
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
        for writes in (0, 1):
            with self.subTest(writes=writes):
                self._pending_cancellation_keeps_other_client(writes)

    def _pending_cancellation_keeps_other_client(self, writes):
        database = f"pony_pending_{os.getpid()}"
        self.sql(f"CREATE DATABASE {database} TEMPLATE conduit_dev")
        proxy = ProtocolProxy(self.proxy.database_host,
                              self.proxy.database_port)
        try:
            self.sql("ALTER TABLE tags RENAME TO tags_hidden", database)
            env = self.server_env.copy()
            env.update(DATABASE_URL=f"postgres://conduit:conduit@127.0.0.1:"
                       f"{proxy.server_address[1]}/{database}",
                       CONDUIT_TEST_POOL_SIZE="2" if writes else "1")
            executable = _executable()
            process = subprocess.Popen(
                [str(executable), "--test-worker-pending-cancel",
                 f"--db-write-sessions={writes}"], env=env,
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
                self.assertEqual(bound, [b"tags", b"tags"])
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
                        response = connection.getresponse()
                        self.assertEqual(response.status, 200)
                        self.assertIn("tags", json.loads(response.read()))
                        sessions = proxy.snapshot()
                        self.assertEqual(len(sessions), 4)
                        serving = [index for index, session in enumerate(sessions)
                                   if any(kind == b"B" for kind, _ in session)]
                        self.assertEqual(len(serving), 1)
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
                        response = connection.getresponse()
                        self.assertEqual(response.status, 200)
                        self.assertIn("tags", json.loads(response.read()))
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
                                proxy.drop_backend(changed[0])
                                response = connection.getresponse()
                                self.assertEqual(response.status, 500)
                                body = json.loads(response.read())
                                self.assertEqual(body["errors"]["body"],
                                                 ["connection lost"])
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
                    _check_metric_output(metrics if _diagnostic_mode()
                                         else None)
                    if _diagnostic_mode():
                        metrics.seek(0)
                        final = [record for record in
                                 _metric_records(metrics)
                                 if record.get("owner") == 2 and
                                 record.get("request") == 0]
                        self.assertEqual({record["generation"] for record
                                          in final}, {0, 1})
                        worker_ids = {record["worker_id"] for record in final}
                        self.assertEqual(len(worker_ids), 1)
                        worker_id = next(iter(worker_ids))
                        self.assertTrue(all(record["counters"][11] == 1
                                            for record in final))
                        by_generation = {(record["worker_id"],
                                          record["generation"]): record
                                         for record in final}
                        original = by_generation[worker_id, 0]
                        replacement = by_generation[worker_id, 1]
                        self.assertEqual(original["counters"][1], 1)
                        self.assertEqual(original["counters"][3], 1)
                        self.assertEqual(replacement["counters"][1], 2)
                        self.assertEqual(replacement["counters"][3], 2)
                        self.assertEqual(original["histograms"][2][
                            "count"], 31)
                        self.assertEqual(replacement["histograms"][2][
                            "count"], 32)
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
    def test_split_mode_validation_and_precedence(self):
        malformed = [["--db-write-sessions=" + value] for value in
                     ("", "96", "-1", "+1", "1x", " 1", "1 ",
                      "9223372036854775808")]
        malformed += [["--db-write-sessions"],
                      ["--db-write-sessions", "--ponymaxthreads=1"],
                      ["--db-write-sessions=1", "--db-write-sessions=1"],
                      ["--db-write-sessions=1", "--db-write-sessions", "1"],
                      ["--db-write-sessions", "1", "--db-write-sessions", "1"]]
        cases = [(args, "invalid", "--db-write-sessions") for args in malformed]
        no_workers = ["--self-test", "--test-pending-jobs", "--test-query-storage",
                      "--test-diag-arithmetic", "--test-csv-tick", "--test-password-async",
                      "--test-named-rollback", "--test-session-boundary", "--test-dns-progress",
                      "--test-session-shutdown", "--test-session-resume-close",
                      "--test-startup-shutdown", "--test-connection-nul", "--test-queue-drain",
                      "--test-result-shapes", "--test-decode-scalar", "--test-decode-atomic"]
        cases.extend(([mode, "--db-write-sessions=invalid"], "invalid",
                      "--db-write-sessions") for mode in no_workers)
        for mode in ([], ["--test-password-startup"],
                     ["--test-password-startup-failure"]):
            for writes in (7, 88):
                cases.append((mode + ["--db-worker-count=8",
                    f"--db-write-sessions={writes}"], "invalid",
                    "95 sessions across 8 workers permit 0 or 8..87"))
        for mode in ("--test-http", "--test-listener-csv"):
            for writes in (3, 5):
                cases.append(([mode, "--db-worker-count=4",
                    f"--db-write-sessions={writes}"], "2",
                    "8 sessions across 4 workers permit 0 or 4..4"))
        worker_modes = ["--test-pool", "--test-pool-csv", "--test-worker-data-error",
                        "--test-worker-decode-error", "--test-worker-overlap",
                        "--test-worker-close-drain", "--test-worker-pending-cancel"]
        if _diagnostic_mode():
            worker_modes.append("--test-worker-diagnostic")
        for mode in worker_modes:
            cases.append(([mode, "--db-write-sessions=2"], "2",
                          "2 sessions across 1 workers permit 0 or 1..1"))
            cases.append(([mode, "--db-write-sessions=1"], "invalid",
                          "CONDUIT_TEST_POOL_SIZE"))
        for size in ("1", "2", "invalid"):
            cases.append((["--test-password-http", "--db-worker-count=8",
                           "--db-write-sessions=1"], size,
                          "1 sessions across 1 workers permit 0"))
        cases.append((["--test-password-http", "--self-test",
                       "--db-write-sessions=95"], "invalid",
                      "1 sessions across 1 workers permit 0"))
        cases.append((["--test-pool", "--test-listener-csv",
                       "--db-write-sessions=2"], "2",
                      "2 sessions across 1 workers permit 0 or 1..1"))
        cases.append((["--test-listener-csv", "--test-pool",
                       "--db-write-sessions=2"], "2",
                      "8 sessions across 4 workers permit 0 or 4..4"))
        if not _diagnostic_mode():
            cases.append((["--test-worker-diagnostic", "--db-write-sessions=1"],
                          "invalid", "requires a diagnostic build"))
        for args, size, expected in cases:
            with self.subTest(args=args, size=size), socket.socket() as backend:
                backend.bind(("127.0.0.1", 0))
                backend.listen(128)
                env = os.environ.copy()
                env.update(DATABASE_URL="postgres://sentinel:secret_sentinel@127.0.0.1:"
                    f"{backend.getsockname()[1]}/test", JWT_SECRET="jwt_sentinel",
                    BCRYPT_WORKERS="1", CONDUIT_TEST_POOL_SIZE=size)
                result = subprocess.run([str(_executable()), *args,
                    "--ponymaxthreads=1"], env=env, capture_output=True,
                    text=True, timeout=5)
                attempts = []
                backend.setblocking(False)
                try:
                    while True:
                        connection, _ = backend.accept()
                        attempts.append(connection)
                except BlockingIOError:
                    pass
                finally:
                    for connection in attempts:
                        connection.close()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(expected, result.stderr)
                self.assertNotIn("sentinel", result.stderr)
                self.assertEqual(len(attempts), 0)
        for args in ([], ["--db-write-sessions=0"], ["--db-write-sessions", "0"],
                     ["--db-write-sessions=032"], ["--db-write-sessions", "95"],
                     ["--test-password-http", "--db-write-sessions=95"],
                     ["--test-http", "--db-write-sessions=95"],
                     ["--test-password-startup", "--db-write-sessions=95"]):
            with self.subTest(accepted=args):
                env = os.environ.copy()
                env["CONDUIT_TEST_POOL_SIZE"] = "invalid"
                result = subprocess.run([str(_executable()), "--self-test", *args,
                    "--ponymaxthreads=1"], env=env, capture_output=True,
                    text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Self-tests passed", result.stdout)

        for args in (["--test-http", "--self-test"],
                     ["--test-password-startup", "--self-test"],
                     ["--test-pending-jobs"], ["--test-diag-arithmetic"],
                     ["--test-csv-tick"]):
            with self.subTest(no_worker=args):
                result = subprocess.run([str(_executable()), *args,
                    "--db-write-sessions=95", "--ponymaxthreads=1"],
                    env=dict(os.environ, CONDUIT_TEST_POOL_SIZE="invalid"),
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotEqual(result.stdout.strip(), "")

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

    def test_split_eight_worker_sessions(self):
        self.check_topology(["--db-write-sessions=32"], [12] * 7 + [11])

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
