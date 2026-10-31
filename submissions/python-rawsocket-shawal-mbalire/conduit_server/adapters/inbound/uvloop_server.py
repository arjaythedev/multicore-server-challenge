"""HTTP_SERVER=uvloop: the same HTTP/1.1 keep-alive server as socket_server.py on uvloop (libuv, C) through asyncio
Protocols. Same framing rules, limits and responses; handlers run inline on the loop, their queries on the same
pipelines (the pipeline sockets are watched with add_reader/add_writer and flushed once per loop pass). Bcrypt
routes (`offload`) run on one helper thread. Needs ALT_ADAPTERS=1 at build. Inline mode only (THREADS=0)."""

import asyncio
import os
import time
from concurrent.futures import ThreadPoolExecutor

from conduit_server.adapters.inbound.socket_server import (
    RawSocketHttpServer, _BAD_REQUEST, _closing, make_listener,
)
from conduit_server.ports.inbound import HttpApplication, InboundServer, RequestParser

_route_key = RawSocketHttpServer._route_key


class UvloopHttpServer(InboundServer):
    MAX_HEAD = RawSocketHttpServer.MAX_HEAD
    MAX_BUFFER = RawSocketHttpServer.MAX_BUFFER
    IDLE_TIMEOUT = RawSocketHttpServer.IDLE_TIMEOUT
    SWEEP_EVERY = RawSocketHttpServer.SWEEP_EVERY

    make_listener = staticmethod(make_listener)
    asyncio = True  # runs asyncio-native pipelines (DB_DRIVER=asyncpg)

    def __init__(self, host: str, port: int, router: HttpApplication, parse: RequestParser, threads: int = 0,
                 listener=None, offload: frozenset = frozenset(), pipeline=None):
        if threads:
            raise SystemExit("Error: HTTP_SERVER=uvloop runs handlers inline only (THREADS=0)")
        self.parse = parse
        self.dispatch = router.dispatch
        self.dispatch_sync = router.dispatch_sync
        self.resume = router.resume
        self.pipes = tuple(pipeline) if pipeline else ()
        self.read_pipes = self.pipes[:-1] if len(self.pipes) > 1 else self.pipes
        self.write_pipe = self.pipes[-1] if self.pipes else None
        self.listener = listener if listener is not None else make_listener(host, port)
        self.offload = offload
        self.executor = ThreadPoolExecutor(max_workers=1) if offload else None
        self.conns = set()
        self.dirty = set()
        self.flush_scheduled = False
        self.pipe_fd = {}  # id(pipe) -> (fd, watching for writes)

    def start(self):
        import uvloop

        uvloop.run(self._main())

    async def _main(self):
        self.loop = asyncio.get_running_loop()
        for p in self.pipes:
            if hasattr(p, "attach"):  # asyncio-native (asyncpg): results come back by callback
                p.attach(self.loop, self._results)
            else:
                self._watch(p, False)
        server = await self.loop.create_server(lambda: _Http(self), sock=self.listener, backlog=65535)
        print(f"uvloop server (pid {os.getpid()}) running on port {self.listener.getsockname()[1]}...", flush=True)
        self.parent = os.getppid()
        self.loop.call_later(self.SWEEP_EVERY, self._sweep)
        async with server:
            await server.serve_forever()

    def _sweep(self):
        if os.getppid() != self.parent:
            os._exit(0)  # supervisor is gone: don't linger as an orphan
        cutoff = time.monotonic() - self.IDLE_TIMEOUT
        for c in [c for c in self.conns if not c.busy and c.last < cutoff]:
            c.transport.close()
        self.loop.call_later(self.SWEEP_EVERY, self._sweep)

    # ---- requests --------------------------------------------------------------------------------------------
    def handle(self, conn, raw: bytes, keep_close: bool, fast: bool):
        """Run one framed request for `conn`: inline, or on the helper thread for offloaded routes."""
        if not fast and self.offload and _route_key(raw) in self.offload:
            conn.busy = True
            fut = self.loop.run_in_executor(self.executor, self._respond_sync, raw, keep_close)
            fut.add_done_callback(lambda f: conn.complete(f.result(), keep_close))
            return
        if not self.pipes:
            conn.send(self._respond_sync(raw, keep_close))
            return
        try:
            out = self.dispatch(self.parse(raw))
        except Exception:
            out = _BAD_REQUEST
        out = self._await(conn, out, keep_close)
        if out is None:
            conn.busy = True
        else:
            conn.send(_closing(out) if keep_close else out)

    def _respond_sync(self, raw: bytes, keep_close: bool) -> bytes:
        try:
            response = self.dispatch_sync(self.parse(raw))
        except Exception:
            response = _BAD_REQUEST
        return _closing(response) if keep_close else response

    # ---- Postgres pipelines ----------------------------------------------------------------------------------
    def _pick(self, query):
        if getattr(query, "write", False):
            return self.write_pipe
        pipes = self.read_pipes
        return pipes[0] if len(pipes) == 1 else min(pipes, key=lambda p: len(p.inflight))

    def _await(self, conn, out, keep_close: bool):
        while out.__class__ is tuple:
            handler, query = out
            pipe = self._pick(query)
            try:
                pipe.submit(query, (conn, handler, keep_close))
            except Exception as e:  # Postgres unreachable: the handler sees the error at its `yield`
                out = self.resume(handler, None, e)
                continue
            if hasattr(pipe, "attach"):
                return None
            self.dirty.add(pipe)
            if not self.flush_scheduled:  # once per loop pass: this pass's queries go out together
                self.flush_scheduled = True
                self.loop.call_soon(self._flush_pipes)
            return None
        return out

    def _flush_pipes(self):
        self.flush_scheduled = False
        dirty, self.dirty = self.dirty, set()
        for p in dirty:
            self._watch(p, p.flush())

    def _pipe_ready(self, pipe):
        results = pipe.ready()
        self._watch(pipe, self.pipe_fd.get(id(pipe), (-1, False))[1])
        self._results(results)

    def _results(self, results):
        for (conn, handler, keep_close), value, error in results:
            out = self._await(conn, self.resume(handler, value, error), keep_close)
            if out is not None:
                conn.complete(_closing(out) if keep_close else out, keep_close)

    def _pipe_writable(self, pipe):
        self.dirty.add(pipe)
        self._flush_pipes()

    def _watch(self, pipe, want_write: bool):
        """Keep the pipeline's socket watched (its fd changes on reconnect; -1 while broken), for writes too while
        it has unsent bytes."""
        fd = pipe.fileno()
        old_fd, old_write = self.pipe_fd.get(id(pipe), (-1, False))
        if fd != old_fd:
            if old_fd >= 0:
                self.loop.remove_reader(old_fd)
                if old_write:
                    self.loop.remove_writer(old_fd)
                old_write = False
            if fd >= 0:
                self.loop.add_reader(fd, self._pipe_ready, pipe)
        if fd >= 0 and want_write != old_write:
            if want_write:
                self.loop.add_writer(fd, self._pipe_writable, pipe)
            else:
                self.loop.remove_writer(fd)
        self.pipe_fd[id(pipe)] = (fd, want_write and fd >= 0)


class _Http(asyncio.Protocol):
    """One client connection: frames requests from its bytes, one in flight at a time (HTTP/1.1 ordering)."""

    __slots__ = ("server", "transport", "inbuf", "busy", "close_after", "last")

    def __init__(self, server: UvloopHttpServer):
        self.server = server
        self.transport = None
        self.inbuf = bytearray()
        self.busy = False
        self.close_after = False
        self.last = time.monotonic()

    def connection_made(self, transport):
        self.transport = transport
        self.server.conns.add(self)

    def connection_lost(self, exc):
        self.server.conns.discard(self)
        self.transport = None

    def data_received(self, data: bytes):
        self.last = time.monotonic()
        if (
            not self.inbuf
            and not self.busy
            and data[:4] == b"GET "
            and data.endswith(b"\r\n\r\n")
            and data.find(b"\r\n\r\n") == len(data) - 4
            and b"close" not in data
            and b"Close" not in data
            and b"CLOSE" not in data
            and b"ength:" not in data
            and b"ENGTH:" not in data
        ):
            self.server.handle(self, data, False, True)
            return
        self.inbuf += data
        if len(self.inbuf) > self.server.MAX_BUFFER:
            self.transport.close()
            return
        self._drain()

    def _drain(self):
        while not self.busy and self.transport is not None and not self.close_after and self._next():
            pass

    def _next(self) -> bool:
        """Frame and run one buffered request; False when the buffer holds no complete one."""
        buf = self.inbuf
        end = buf.find(b"\r\n\r\n")
        if end == -1:
            if len(buf) > self.server.MAX_HEAD:
                self.transport.close()
            return False
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
            return False
        raw = bytes(buf[:total])
        del buf[:total]
        keep_close = False
        if b"close" in head or b"Close" in head or b"CLOSE" in head:
            keep_close = b"connection: close" in (lower if lower is not None else head.lower())
        if keep_close:
            self.close_after = True
        self.server.handle(self, raw, keep_close, False)
        return True

    def send(self, payload: bytes):
        if self.transport is None:
            return
        self.transport.write(payload)
        if self.close_after:
            self.transport.close()  # after the buffered bytes are written

    def complete(self, payload: bytes, keep_close: bool):
        """A response that waited on Postgres or the helper thread: send it, then any requests buffered meanwhile."""
        if self.transport is None:
            return  # client went away while its request was running
        self.busy = False
        self.last = time.monotonic()
        if keep_close:
            self.close_after = True
        self.send(payload)
        if self.inbuf:
            self._drain()
