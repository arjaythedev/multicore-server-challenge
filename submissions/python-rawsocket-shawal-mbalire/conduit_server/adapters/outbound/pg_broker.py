"""One process that owns every Postgres connection, shared by all workers (`BROKER=1`, the default).

Why: Postgres is most of the CPU per request, and much of a read's cost is work other requests repeat at the same
moment (the same list page, the same popular article, the same capped count). A statement over many requests can do
that work once, but only if the requests wait in one place: each worker alone has 0-1 queries in flight.

Workers talk to the broker over a Unix socketpair made before the fork. `BrokerClient` is the worker's end, with the
same interface as `PgPipeline` (the epoll loop and the handlers don't change). Each loop pass's queries go out as one
frame: a 4-byte length, then `marshal` of [(job id, statement index, args, flags), ...]. Replies come back the same
way: [(job id, status, value), ...].

The broker queues reads by statement. When a read connection has nothing in flight, it takes the queue whose oldest
job is oldest and runs all of it as one unit (pipelined statements, one Sync each), so queues fill while every
connection is busy and drain as soon as one frees up. A unit of a kind with a batched statement
(`pg_repository.BATCHED`, from its `min_size`) runs as that one statement; a statement without parameters
(`SHARED`: tags) runs once for the whole unit; anything else runs as pipelined single statements.

Logins send their bcrypt here too (statement index -1, `crypto_adapter.BcryptJob`): the broker's bcrypt threads
(the password hasher's `batcher`, passed in by the composition root) hash up to 6 at once on the multi-lane bcrypt,
4.4x less CPU per hash than one at a time.

Writes queue the same way for the write connections, and a unit of several is one transaction (group commit, allowed
by rule 6): BEGIN, the statements, COMMIT behind one Sync, so they share one WAL flush; each write's reply goes out
only once COMMIT has returned. Committed one by one, writes queued for seconds behind the WAL flushes at 20,000 test
users. If any statement in the group fails, the group is rolled back and each write runs again on its own, so only
the one at fault sees the error.
"""

import marshal
import os
import select
import socket
import struct
import sys
from collections import deque

import psycopg

from conduit_server.adapters.outbound.pg_repository import (
    BATCHED,
    SHARED,
    _COMMAND_OK,
    _STATEMENTS,
    _TUPLES_OK,
    PgPipeline,
    _load,
    _params,
    _raise,
)

_LEN = struct.Struct("<I")
_IN = select.EPOLLIN
_IN_OUT = select.EPOLLIN | select.EPOLLOUT
_WRITE, _JSON = 1, 2  # job flags
_OK_JSON, _OK_ROWS, _ERROR = 0, 1, 2  # reply status
MAX_UNIT = 512  # jobs one read connection takes at a time
MAX_GROUP = 128  # writes in one transaction
# recv size: up to 128 KB stays under glibc's mmap threshold; 1 MB made every recv map and unmap its buffer
_RECV = 65536


def _frame(items) -> bytes:
    payload = marshal.dumps(items)
    return _LEN.pack(len(payload)) + payload


def _frames(buf: bytearray) -> list:
    """The complete frames at the start of `buf`, decoded and removed from it."""
    out, pos, n = [], 0, len(buf)
    while n - pos >= 4:
        size = _LEN.unpack_from(buf, pos)[0]
        end = pos + 4 + size
        if end > n:
            break
        out.append(marshal.loads(buf[pos + 4 : end]))
        pos = end
    if pos:
        del buf[:pos]
    return out


def _error(sqlstate, message: str) -> Exception:
    if sqlstate is None:
        return psycopg.OperationalError(message)
    return psycopg.errors.lookup(sqlstate)(message)


class BrokerClient:
    """A worker's end of the broker socket, in place of its `PgPipeline`s: `submit` queues a query, `flush` sends this
    pass's queries as one frame (True: the socket is full, watch for writes), `ready` returns (token, value, error)
    for every reply that arrived."""

    def __init__(self, sock: socket.socket):
        sock.setblocking(False)
        self.sock, self.fd = sock, sock.fileno()
        self.jobs = []  # this pass's (job id, statement index, args, flags)
        self.inflight = {}  # job id -> (query, token); the server reads its len()
        self.out = b""
        self.inbuf = bytearray()
        self.next_id = 0

    def fileno(self) -> int:
        return self.fd

    def submit(self, query, token) -> None:
        jid = self.next_id = self.next_id + 1
        self.inflight[jid] = (query, token)
        self.jobs.append((jid, query.stmt.index, query.args, (_WRITE if query.write else 0) | (_JSON if query.json else 0)))

    def flush(self) -> bool:
        if self.jobs:
            frame = _frame(self.jobs)
            self.jobs = []
            self.out = self.out + frame if self.out else frame
        if not self.out:
            return False
        try:
            sent = self.sock.send(self.out)
        except (BlockingIOError, InterruptedError):
            sent = 0
        self.out = self.out[sent:]
        return bool(self.out)

    def ready(self) -> list:
        try:
            data = self.sock.recv(_RECV)
        except (BlockingIOError, InterruptedError):
            return []
        if not data:  # the broker is gone; the supervisor stops the whole server (no restarts, rule 9)
            raise SystemExit("Postgres broker exited")
        self.inbuf += data
        out, inflight = [], self.inflight
        for frame in _frames(self.inbuf):
            for jid, status, value in frame:
                query, token = inflight.pop(jid)
                if status == _OK_JSON:  # a body, or a bcrypt hash (its job's `finish` turns it into the answer)
                    out.append((token, value if query.finish is None else query.finish(value), None))
                elif status == _OK_ROWS:
                    cols, rows = value
                    if query.stmt.cols is None:
                        query.stmt.cols = cols
                    try:
                        out.append((token, rows if query.finish is None else query.finish(rows), None))
                    except Exception as e:
                        out.append((token, None, e))
                else:
                    out.append((token, None, _error(*value)))
        return out


class _Job:
    """One job run as its own statement: `PgPipeline` calls `result` with its result; the reply's (status, value)."""

    __slots__ = ("stmt", "args", "json")

    def __init__(self, stmt, args, json: bool):
        self.stmt, self.args, self.json = stmt, args, json

    def result(self, conn, res):
        status = res.status
        if status == _TUPLES_OK:
            if self.json:
                return _OK_JSON, (res.get_value(0, 0) if res.ntuples else None)
            return _OK_ROWS, (self.stmt.cols or _cols(res), _load(conn, self.stmt, res))
        if status == _COMMAND_OK:
            return _OK_ROWS, ([], [])
        _raise(res)


class _BatchJob:
    """A unit run as one batched statement: its bodies, one per request in unit order."""

    __slots__ = ("stmt", "args")

    def __init__(self, stmt, args):
        self.stmt, self.args = stmt, args

    def result(self, conn, res):
        if res.status != _TUPLES_OK:
            _raise(res)
        return [res.get_value(r, 1) for r in range(res.ntuples)]


class _GroupCommit:
    """A unit of writes as one transaction. `result` gets every result before the Sync: BEGIN, one per write, COMMIT;
    the writes' replies if all succeeded, else raises _GroupFailed."""

    __slots__ = ("jobs",)
    multi = True

    def __init__(self, jobs):
        self.jobs = jobs  # (statement index, worker, job id, args, json)

    def send(self, pg):
        pg.send_query_params(b"BEGIN", None)
        for index, _, _, args, _ in self.jobs:
            pg.send_query_prepared(_STATEMENTS[index].name, _params(args), None, 1)
        pg.send_query_params(b"COMMIT", None)

    def result(self, conn, results):
        n = len(self.jobs)
        if len(results) != n + 2 or any(r.status not in _OK_STATUS for r in results):
            raise _GroupFailed
        return [
            _Job(_STATEMENTS[index], args, json).result(conn, res)
            for (index, _, _, args, json), res in zip(self.jobs, results[1:-1])
        ]


class _GroupFailed(Exception):
    pass


class _Rollback:
    """Ends a failed group's transaction (in pipeline mode it stays open, aborted, after the Sync)."""

    multi = True

    @staticmethod
    def send(pg):
        pg.send_query_params(b"ROLLBACK", None)

    @staticmethod
    def result(conn, results):
        return None


_OK_STATUS = (_COMMAND_OK, _TUPLES_OK)
_BATCH, _SHARED, _GROUP = "batch", "shared", "group"  # multi-job tokens: [kind, statement index, jobs]


def _depth(pipe) -> int:
    return len(pipe.inflight)


def _cols(res) -> list:
    return [res.fname(i).decode() for i in range(res.nfields)]


def _error_reply(e: Exception) -> tuple:
    return _ERROR, (getattr(e, "sqlstate", None), str(e) or e.__class__.__name__)


class Broker:
    """The broker process's epoll loop over the workers' sockets and its own Postgres connections."""

    def __init__(self, socks, conninfo: str, readers: int, writers: int, bcrypt=None):
        self.socks = list(socks)
        self.bcrypt = bcrypt  # BcryptBatcher: jobs with statement index -1
        # BROKER_BATCH=0: every unit runs as single statements (no BATCHED/SHARED forms), for A/B runs
        self.batch = os.getenv("BROKER_BATCH", "1") != "0"
        for s in self.socks:
            s.setblocking(False)
        self.read_pipes = [PgPipeline(conninfo) for _ in range(readers)]
        self.write_pipes = [PgPipeline(conninfo) for _ in range(writers)]
        self.queues = {}  # statement index -> deque of (arrival seq, worker, job id, args, json)
        self.writes = deque()  # (statement index, worker, job id, args, json)
        self.seq = 0
        self.inbufs = [bytearray() for _ in self.socks]
        self.outbufs = [b"" for _ in self.socks]
        self.replies = [[] for _ in self.socks]
        self.dirty_pipes = set()

    def run(self):
        ep = self.ep = select.epoll()
        self.wfd = {}
        for i, s in enumerate(self.socks):
            self.wfd[s.fileno()] = i
            ep.register(s.fileno(), _IN)
        self.pfd, self.pipe_state = {}, {}
        for p in self.read_pipes + self.write_pipes:
            self._watch_pipe(p, False)
        bfd = self.bcrypt.efd if self.bcrypt is not None else -1
        if bfd >= 0:
            ep.register(bfd, _IN)
        print(f"Postgres broker (pid {os.getpid()}): {len(self.read_pipes)} read + {len(self.write_pipes)} write"
              " connections", flush=True)
        parent = os.getppid()
        wfd, pfd, dirty, replies = self.wfd, self.pfd, self.dirty_pipes, self.replies
        while True:
            events = ep.poll(5.0)
            if not events and os.getppid() != parent:
                os._exit(0)  # supervisor is gone
            for fd, mask in events:
                if fd == bfd:
                    for (i, jid), value in self.bcrypt.results():
                        replies[i].append((jid, _OK_JSON, value))
                    continue
                i = wfd.get(fd)
                if i is not None:
                    if mask & select.EPOLLOUT:
                        self._send(i)
                    if mask & (select.EPOLLIN | select.EPOLLHUP | select.EPOLLERR):
                        self._read_worker(i)
                    continue
                p = pfd.get(fd)
                if p is None:
                    continue
                if mask & select.EPOLLOUT:
                    dirty.add(p)
                if mask & (select.EPOLLIN | select.EPOLLHUP | select.EPOLLERR):
                    self._results(p)
            self._dispatch()
            if dirty:
                for p in tuple(dirty):
                    dirty.discard(p)
                    self._watch_pipe(p, p.flush())
            for i, r in enumerate(replies):
                if r:
                    frame = _frame(r)
                    replies[i] = []
                    self.outbufs[i] = self.outbufs[i] + frame if self.outbufs[i] else frame
                    self._send(i)

    # ---- workers -----------------------------------------------------------
    def _read_worker(self, i: int):
        try:
            data = self.socks[i].recv(_RECV)
        except (BlockingIOError, InterruptedError):
            return
        if not data:  # a worker died: the supervisor stops everything (rule 9); stop listening to it meanwhile
            self.ep.unregister(self.socks[i].fileno())
            return
        buf = self.inbufs[i]
        buf += data
        queues, writes = self.queues, self.writes
        for frame in _frames(buf):
            for jid, index, args, flags in frame:
                if index < 0:  # bcrypt (BcryptJob): hashed with other workers' logins
                    self.bcrypt.submit((i, jid), *args)
                elif flags & _WRITE:
                    writes.append((index, i, jid, args, bool(flags & _JSON)))
                else:
                    self.seq += 1
                    q = queues.get(index)
                    if q is None:
                        q = queues[index] = deque()
                    q.append((self.seq, i, jid, args, bool(flags & _JSON)))

    def _send(self, i: int):
        out = self.outbufs[i]
        if not out:
            return
        sock = self.socks[i]
        try:
            sent = sock.send(out)
        except (BlockingIOError, InterruptedError):
            sent = 0
        except OSError:  # worker gone
            self.outbufs[i] = b""
            return
        rest = self.outbufs[i] = out[sent:]
        self.ep.modify(sock.fileno(), _IN_OUT if rest else _IN)

    # ---- Postgres ----------------------------------------------------------
    def _dispatch(self):
        """Give every idle write connection the queued writes, and every idle read connection the queue whose oldest
        job is oldest."""
        writes = self.writes
        for pipe in self.write_pipes:
            if not writes:
                break
            if pipe.inflight:
                continue
            if len(writes) == 1:
                index, i, jid, args, json = writes.popleft()
                self._submit(pipe, _Job(_STATEMENTS[index], args, json), (i, jid))
            else:
                jobs = [writes.popleft() for _ in range(min(len(writes), MAX_GROUP))]
                self._submit(pipe, _GroupCommit(jobs), [_GROUP, None, jobs])
        queues = self.queues
        for pipe in self.read_pipes:
            if pipe.inflight:
                continue
            best, best_seq = None, None
            for index, q in queues.items():
                if q and (best_seq is None or q[0][0] < best_seq):
                    best, best_seq = index, q[0][0]
            if best is None:
                return
            q = queues[best]
            stmt = _STATEMENTS[best]
            jobs = [q.popleft() for _ in range(min(len(q), MAX_UNIT))]
            spec = BATCHED.get(best) if self.batch else None
            if self.batch and best in SHARED and len(jobs) > 1:
                self._submit(pipe, _Job(stmt, (), True), [_SHARED, best, jobs])
            elif spec is not None and len(jobs) >= spec.min_size:
                self._submit(pipe, _BatchJob(spec.stmt, spec.params([j[3] for j in jobs])), [_BATCH, best, jobs])
            else:
                for _, i, jid, args, json in jobs:
                    self._submit(pipe, _Job(stmt, args, json), (i, jid))

    def _submit(self, pipe, job, token):
        try:
            if getattr(job, "multi", False):
                pipe.submit_unit(job, token)
            else:
                pipe.submit(job, token)
            self.dirty_pipes.add(pipe)
        except Exception as e:  # Postgres unreachable
            self._fail(token, e)

    def _fail(self, token, error):
        if token is None:  # a ROLLBACK: nobody waits on it
            return
        reply = _error_reply(error)
        if token.__class__ is tuple:
            i, jid = token
            self.replies[i].append((jid,) + reply)
        else:
            for _, i, jid, _, _ in token[2]:
                self.replies[i].append((jid,) + reply)

    def _results(self, pipe):
        replies = self.replies
        results = pipe.ready()
        if pipe.fileno() == -1:  # connection lost: drop its old fd now
            self._watch_pipe(pipe, False)
        for token, value, error in results:
            if token is None:  # ROLLBACK after a failed group
                continue
            if token.__class__ is tuple:  # one job
                i, jid = token
                replies[i].append((jid,) + (value if error is None else _error_reply(error)))
            elif error is not None:
                if token[0] is _BATCH and pipe.fileno() != -1:
                    # e.g. one request's bad parameter: run each on its own, so only that one fails
                    stmt = _STATEMENTS[token[1]]
                    for _, i, jid, args, json in token[2]:
                        self._submit(pipe, _Job(stmt, args, json), (i, jid))
                elif token[0] is _GROUP and pipe.fileno() != -1:
                    # nothing in the group committed: roll back, then each write on its own
                    self._submit(pipe, _Rollback, None)
                    for index, i, jid, args, json in token[2]:
                        self._submit(pipe, _Job(_STATEMENTS[index], args, json), (i, jid))
                else:
                    self._fail(token, error)
            elif token[0] is _SHARED:
                for _, i, jid, _, _ in token[2]:
                    replies[i].append((jid,) + value)
            elif token[0] is _GROUP:
                for (_, i, jid, _, _), reply in zip(token[2], value):
                    replies[i].append((jid,) + reply)
            else:
                for (_, i, jid, _, _), body in zip(token[2], value):
                    replies[i].append((jid, _OK_JSON, body))

    def _watch_pipe(self, pipe, want_write: bool):
        """As RawSocketHttpServer._watch_pipe: keep the connection's socket registered across reconnects."""
        fd = pipe.fileno()
        mask = _IN_OUT if want_write else _IN
        old = self.pipe_state.get(id(pipe))
        if old == (fd, mask):
            return
        if old is not None and old[0] != fd and old[0] >= 0:
            self.pfd.pop(old[0], None)
            try:
                self.ep.unregister(old[0])
            except OSError:
                pass
            old = None
        if fd >= 0:
            self.pfd[fd] = pipe
            if old is None:
                self.ep.register(fd, mask)
            else:
                self.ep.modify(fd, mask)
        self.pipe_state[id(pipe)] = (fd, mask)


def serve_broker(socks, conninfo: str, readers: int, writers: int, make_bcrypt=None):
    """Run the broker in this (forked) process until it dies. make_bcrypt: builds the password hasher's batcher
    here, after the fork, so its threads live in this process."""
    try:
        Broker(socks, conninfo, readers, writers, make_bcrypt() if make_bcrypt is not None else None).run()
    except BaseException:
        import traceback

        traceback.print_exc()
        sys.stderr.flush()
    finally:
        os._exit(1)
