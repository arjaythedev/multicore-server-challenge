import os
import select
import socket
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from typing import Dict, Optional

from conduit_server.adapters.inbound.router import parse_request

_IN = select.EPOLLIN
# Linux >= 4.5. Some Python builds (uv's standalone CPython) are compiled against older kernel headers and lack the
# constant, though the kernel supports the flag; its value is fixed in the kernel ABI.
_EPOLLEXCLUSIVE = getattr(select, "EPOLLEXCLUSIVE", 1 << 28)
_IN_OUT = select.EPOLLIN | select.EPOLLOUT
_BAD_REQUEST = (
    b"HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n"
    b"Content-Length: 37\r\nConnection: keep-alive\r\n\r\n"
    b'{"errors": {"body": ["Bad request"]}}'
)


def make_listener(host: str, port: int, reuseport: bool = False) -> socket.socket:
    """Bound in the parent before the fork. reuseport: one of several listeners on the same port (one per worker);
    the kernel hashes each new connection to one of them, so connections spread evenly across workers."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if reuseport:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind((host, port))
    sock.listen(65535)
    sock.setblocking(False)
    return sock


class _Conn:
    __slots__ = ("sock", "fd", "inbuf", "outbuf", "busy", "close_after", "last")

    def __init__(self, sock: socket.socket):
        self.sock: Optional[socket.socket] = sock
        self.fd = sock.fileno()
        self.inbuf = bytearray()
        self.outbuf = b""
        self.busy = False  # one request in flight per connection keeps HTTP/1.1 ordering
        self.close_after = False
        self.last = time.monotonic()


class RawSocketHttpServer:
    """epoll(7) HTTP/1.1 keep-alive server: one I/O loop thread, handlers inline or on a thread pool.

    threads=0: the loop runs each complete request's synchronous router call itself, so a worker process is a single
    thread with no GIL handoffs; concurrency comes from running many such workers on the shared listener. Requests
    whose b"METHOD /path" is in `offload` (bcrypt: ~40 ms of CPU) go to one helper thread instead, so the loop keeps
    serving this worker's other connections meanwhile (bcrypt releases the GIL).
    threads>0: the loop only accepts, reads, frames and writes (all non-blocking), and requests run on `executor`;
    psycopg and bcrypt release the GIL, so requests overlap. Results come back through a deque + eventfd.

    pipeline (inline only): handlers that `yield` a query don't block the loop. The query goes out on the pipeline
    connection, whose socket is in the same epoll, and the handler resumes when its result arrives; meanwhile the loop
    serves other connections, and queries in flight together share Postgres round trips. Without a pipeline (threads,
    the offload helper) those queries run synchronously (`router.dispatch_sync`).
    """

    MAX_HEAD = 16 * 1024
    MAX_BUFFER = 1024 * 1024
    IDLE_TIMEOUT = 90.0  # served directly: > the 70 s max think time, so a user's connection survives between pages
    SWEEP_EVERY = 5.0

    def __init__(
        self,
        host: str,
        port: int,
        router,
        threads: int = 16,
        listener: Optional[socket.socket] = None,
        offload: frozenset = frozenset(),
        pipeline=None,
    ):
        self.dispatch = router.dispatch  # HttpRequest -> bytes, or (handler, query) to wait on
        self.dispatch_sync = router.dispatch_sync  # HttpRequest -> bytes
        self.resume = router.resume  # (handler, value, error) -> bytes, or (handler, query)
        if pipeline is None:
            self.pipes = ()
            self.read_pipes = ()
            self.write_pipe = None
        elif isinstance(pipeline, (list, tuple)):
            self.pipes = tuple(pipeline)
            self.read_pipes = self.pipes[:-1] if len(self.pipes) > 1 else self.pipes
            self.write_pipe = self.pipes[-1]
        else:
            self.pipes = (pipeline,)
            self.read_pipes = (pipeline,)
            self.write_pipe = pipeline
        self.pipeline = self.read_pipes[0] if self.read_pipes else None
        self.listener = listener if listener is not None else make_listener(host, port)
        self.threads = threads
        self.offload = offload
        self.conns: Dict[int, _Conn] = {}
        self.done: deque = deque()

    def start(self):
        # threads=0: requests run inline on the loop (no GIL handoffs), except offloaded ones on one helper thread
        self.inline = self.threads == 0
        if self.inline and not self.offload:
            self.executor = None
        else:
            self.executor = ThreadPoolExecutor(max_workers=self.threads or 1)
        self.ep = select.epoll()
        self.efd = os.eventfd(0, os.EFD_NONBLOCK | os.EFD_CLOEXEC)
        lfd = self.listener.fileno()
        # EPOLLEXCLUSIVE: with several workers on one listener, a new connection wakes only one of them
        self.ep.register(lfd, select.EPOLLIN | _EPOLLEXCLUSIVE)
        self.ep.register(self.efd, select.EPOLLIN)
        if not self.inline:
            self.pipes = ()
            self.read_pipes = ()
            self.write_pipe = None
            self.pipeline = None
        self.pfd_map = {}  # fd -> PgPipeline
        self.pipe_state = {}  # id(pipe) -> (fd, mask)
        self.dirty_pipes = set()
        for p in self.pipes:
            self._watch_pipe(p, False)
        print(
            f"Raw socket server (pid {os.getpid()}) running on port {self.listener.getsockname()[1]}...",
            flush=True,
        )

        parent = os.getppid()
        next_sweep = time.monotonic() + self.SWEEP_EVERY
        conns, efd, pfd_map, dirty_pipes = self.conns, self.efd, self.pfd_map, self.dirty_pipes
        while True:
            for fd, mask in self.ep.poll(self.SWEEP_EVERY):
                if fd == lfd:
                    self._accept()
                elif fd == efd:
                    self._completions()
                elif fd in pfd_map:
                    p = pfd_map[fd]
                    if mask & select.EPOLLOUT:
                        dirty_pipes.add(p)
                    if mask & (select.EPOLLIN | select.EPOLLHUP | select.EPOLLERR):
                        self._pipeline_ready(p)
                else:
                    conn = conns.get(fd)
                    if conn is None:
                        continue
                    if mask & select.EPOLLOUT:
                        self._flush(conn)
                    if mask & (select.EPOLLIN | select.EPOLLHUP | select.EPOLLERR) and conn.sock:
                        self._read(conn)
            if dirty_pipes:  # one flush per pass per active pipeline: what this pass submitted goes out together
                for p in tuple(dirty_pipes):
                    dirty_pipes.discard(p)
                    self._watch_pipe(p, p.flush())
            now = time.monotonic()
            if now >= next_sweep:
                next_sweep = now + self.SWEEP_EVERY
                if os.getppid() != parent:
                    os._exit(0)  # supervisor is gone: don't linger as an orphan
                self._sweep(now)

    # ---- loop thread -------------------------------------------------------
    def _accept(self):
        for _ in range(256):
            try:
                sock, _ = self.listener.accept()
            except (BlockingIOError, InterruptedError):
                return
            except OSError:
                return  # e.g. EMFILE: retry on the next wake-up
            sock.setblocking(False)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            conn = _Conn(sock)
            self.conns[conn.fd] = conn
            self.ep.register(conn.fd, _IN)

    def _read(self, conn: _Conn):
        try:
            data = conn.sock.recv(65536)
        except (BlockingIOError, InterruptedError):
            return
        except OSError:
            self._close(conn)
            return
        if not data:
            self._close(conn)
            return
        conn.last = time.monotonic()
        if (
            self.inline
            and not conn.inbuf
            and not conn.busy
            and data[:4] == b"GET "
            and data.endswith(b"\r\n\r\n")
            and data.find(b"\r\n\r\n") == len(data) - 4
            and b"close" not in data
            and b"Close" not in data
            and b"CLOSE" not in data
            and b"ength:" not in data
            and b"ENGTH:" not in data
        ):
            if self.pipeline is None:
                self._send(conn, self._respond(data, False))
                return
            try:
                out = self.dispatch(parse_request(data))
            except Exception:
                out = _BAD_REQUEST
            out = self._await(conn, out, False)
            if out is None:
                conn.busy = True
            else:
                self._send(conn, out)
            return
        conn.inbuf += data
        if len(conn.inbuf) > self.MAX_BUFFER:
            self._close(conn)
            return
        if not conn.busy:
            while self._next_request(conn) and conn.sock is not None and not conn.close_after:
                pass

    def _next_request(self, conn: _Conn):
        """Frame one request from the buffer and hand it to the thread pool."""
        buf = conn.inbuf
        end = buf.find(b"\r\n\r\n")
        if end == -1:
            if len(buf) > self.MAX_HEAD:
                self._close(conn)
            return  # wait for the rest of the headers

        head = bytes(buf[: end + 4])
        content_length = 0
        if head[:4] != b"GET " or b"ength:" in head or b"ENGTH:" in head:
            lower = head.lower()
            i = lower.find(b"\r\ncontent-length:")
            if i != -1:
                j = lower.find(b"\r\n", i + 2)
                try:
                    content_length = max(0, int(lower[i + 17 : j]))
                except ValueError:
                    content_length = 0
        else:
            lower = None
        total = end + 4 + content_length
        if len(buf) < total:
            return  # body not fully received yet

        raw = bytes(buf[:total])
        del buf[:total]
        if b"close" in head or b"Close" in head or b"CLOSE" in head:
            if lower is None:
                lower = head.lower()
            keep_close = b"connection: close" in lower
        else:
            keep_close = False
        if self.inline and not (self.offload and self._route_key(head) in self.offload):
            # inline: this worker's loop thread runs the handler itself
            if keep_close:
                conn.close_after = True
            if self.pipeline is None:
                self._send(conn, self._respond(raw, keep_close))
                return True
            try:
                out = self.dispatch(parse_request(raw))
            except Exception:
                out = _BAD_REQUEST
            out = self._await(conn, out, keep_close)
            if out is None:  # waiting on Postgres; later requests on this connection wait their turn
                conn.busy = True
                return None
            self._send(conn, _closing(out) if keep_close else out)
            return True
        conn.busy = True
        self.executor.submit(self._handle, conn, raw, keep_close)

    @staticmethod
    def _route_key(head: bytes) -> bytes:
        """b"POST /api/users/login" from the request line (query string dropped)."""
        end = head.find(b" ", head.find(b" ") + 1)
        return head[:end].partition(b"?")[0]

    def _completions(self):
        try:
            os.eventfd_read(self.efd)
        except BlockingIOError:
            pass
        done = self.done
        while done:
            self._complete(*done.popleft())

    def _complete(self, conn: _Conn, response: bytes, keep_close: bool):
        if conn.sock is None:
            return  # client went away while its request was running
        conn.busy = False
        conn.last = time.monotonic()
        if keep_close:
            conn.close_after = True
        self._send(conn, response)
        # pipelined requests already buffered
        while conn.sock is not None and not conn.close_after and conn.inbuf and self._next_request(conn):
            pass

    # ---- Postgres pipeline (inline only) -----------------------------------
    def _pick_pipe(self, query):
        if getattr(query, "write", False):
            return self.write_pipe
        pipes = self.read_pipes
        if len(pipes) == 1:
            return pipes[0]
        p0, p1 = pipes[0], pipes[1]
        if len(pipes) == 2:
            return p0 if len(p0.inflight) <= len(p1.inflight) else p1
        return min(pipes, key=lambda p: len(p.inflight))

    def _await(self, conn: _Conn, out, keep_close: bool) -> Optional[bytes]:
        """Response bytes once the handler is done, or None after submitting the query it now waits on."""
        while out.__class__ is tuple:
            handler, query = out
            pipe = self._pick_pipe(query)
            try:
                pipe.submit(query, (conn, handler, keep_close))
                self.dirty_pipes.add(pipe)
                return None
            except Exception as e:  # Postgres unreachable: the handler sees the error at its `yield`
                out = self.resume(handler, None, e)
        return out

    def _pipeline_ready(self, pipe):
        results = pipe.ready()
        if pipe.fileno() == -1:  # connection lost: drop its old fd now, before a new client can be given that number
            self._watch_pipe(pipe, False)
        for (conn, handler, keep_close), value, error in results:
            out = self._await(conn, self.resume(handler, value, error), keep_close)
            if out is not None:
                self._complete(conn, _closing(out) if keep_close else out, keep_close)

    def _watch_pipe(self, pipe, want_write: bool):
        """Keep the pipeline's socket registered (its fd changes on reconnect), for writes too while libpq has
        unsent bytes."""
        fd = pipe.fileno()
        mask = _IN_OUT if want_write else _IN
        pid = id(pipe)
        old = self.pipe_state.get(pid)
        if old is not None:
            old_fd, old_mask = old
            if fd == old_fd and mask == old_mask:
                return
            if fd != old_fd:
                if old_fd >= 0:
                    self.pfd_map.pop(old_fd, None)
                    try:
                        self.ep.unregister(old_fd)
                    except OSError:
                        pass  # closed with the old connection
                if fd >= 0:
                    self.pfd_map[fd] = pipe
                    self.ep.register(fd, mask)
            elif fd >= 0:
                self.ep.modify(fd, mask)
        else:
            if fd >= 0:
                self.pfd_map[fd] = pipe
                self.ep.register(fd, mask)
        self.pipe_state[pid] = (fd, mask)

    def _send(self, conn: _Conn, payload: bytes):
        if conn.outbuf:
            conn.outbuf += payload
            return
        try:
            sent = conn.sock.send(payload)
        except (BlockingIOError, InterruptedError):
            sent = 0
        except OSError:
            self._close(conn)
            return
        if sent < len(payload):
            conn.outbuf = payload[sent:]
            self.ep.modify(conn.fd, _IN_OUT)
        elif conn.close_after:
            self._close(conn)

    def _flush(self, conn: _Conn):
        try:
            sent = conn.sock.send(conn.outbuf)
        except (BlockingIOError, InterruptedError):
            return
        except OSError:
            self._close(conn)
            return
        conn.outbuf = conn.outbuf[sent:]
        if not conn.outbuf:
            if conn.close_after:
                self._close(conn)
            else:
                self.ep.modify(conn.fd, _IN)

    def _sweep(self, now: float):
        cutoff = now - self.IDLE_TIMEOUT
        for conn in [c for c in self.conns.values() if not c.busy and c.last < cutoff]:
            self._close(conn)

    def _close(self, conn: _Conn):
        sock, conn.sock = conn.sock, None
        if sock is None:
            return
        self.conns.pop(conn.fd, None)
        try:
            self.ep.unregister(conn.fd)
        except OSError:
            pass
        try:
            sock.close()
        except OSError:
            pass

    # ---- pool threads ------------------------------------------------------
    def _respond(self, raw: bytes, keep_close: bool) -> bytes:
        try:
            response = self.dispatch_sync(parse_request(raw))
        except Exception:
            response = _BAD_REQUEST
        return _closing(response) if keep_close else response

    def _handle(self, conn: _Conn, raw: bytes, keep_close: bool):
        self.done.append((conn, self._respond(raw, keep_close), keep_close))
        os.eventfd_write(self.efd, 1)


def _closing(response: bytes) -> bytes:
    return response.replace(b"keep-alive", b"close", 1)
