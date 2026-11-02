import asyncio
import email.utils
import sys
import time
import traceback

import httptools

MAX_BODY = 1 << 20  # 1 MiB
MAX_PIPELINED = 32  # stop reading from a client that is this many requests ahead of our answers
IDLE_TIMEOUT_S = 300  # real users think for 70 s at most
SWEEP_EVERY_S = 30

_REASONS = {
    200: b"OK", 201: b"Created", 204: b"No Content", 400: b"Bad Request", 401: b"Unauthorized", 403: b"Forbidden",
    404: b"Not Found", 405: b"Method Not Allowed", 413: b"Payload Too Large", 422: b"Unprocessable Entity",
    500: b"Internal Server Error", 503: b"Service Unavailable",
}
_STATUS_LINE = {code: b"HTTP/1.1 %d %b\r\n" % (code, reason) for code, reason in _REASONS.items()}
_JSON_HEAD = b"Content-Type: application/json\r\nContent-Length: "

_date_header = b""


def _tick_date(loop: asyncio.AbstractEventLoop) -> None:
    global _date_header
    _date_header = b"Date: %b\r\n" % email.utils.formatdate(time.time(), usegmt=True).encode()
    loop.call_later(1.0, _tick_date, loop)


def response_bytes(status: int, body: bytes, keep_alive: bool) -> bytes:
    close = b"" if keep_alive else b"Connection: close\r\n"
    if status == 204:
        return b"%b%b%b\r\n" % (_STATUS_LINE[204], _date_header, close)
    return b"%b%b%d\r\n%b%b\r\n%b" % (_STATUS_LINE[status], _JSON_HEAD, len(body), _date_header, close, body)


class HttpProtocol(asyncio.Protocol):
    __slots__ = (
        "handler", "server", "loop", "transport", "parser", "url", "authorization", "body", "queue", "busy", "paused",
        "closing", "last_active",
    )

    def __init__(self, server: "Server"):
        self.server = server
        self.handler = server.handler
        self.loop = server.loop
        self.transport = None
        self.parser = httptools.HttpRequestParser(self)
        self.url = b""
        self.authorization = b""
        self.body = b""
        self.queue: list = []
        self.busy = False
        self.paused = False
        self.closing = False
        self.last_active = 0.0

    def connection_made(self, transport):
        self.transport = transport
        self.last_active = self.loop.time()
        self.server.connections.add(self)

    def connection_lost(self, exc):
        self.transport = None
        self.server.connections.discard(self)

    def data_received(self, data):
        if self.closing:
            return
        self.last_active = self.loop.time()
        try:
            self.parser.feed_data(data)
        except httptools.HttpParserUpgrade:
            self._fatal(400)
        except httptools.HttpParserError:
            self._fatal(400)

    def _fatal(self, status: int, message: bytes = b"bad request") -> None:
        """Send an error and close the connection (bad or oversized request)."""
        if self.closing:
            return
        self.closing = True
        t = self.transport
        if t is not None:
            t.write(response_bytes(status, b'{"errors":{"body":["%b"]}}' % message, False))
            t.close()

    # httptools callbacks

    def on_message_begin(self):
        self.url = b""
        self.authorization = b""
        self.body = b""

    def on_url(self, url: bytes):
        self.url += url

    def on_header(self, name: bytes, value: bytes):
        n = len(name)
        if n == 13 and (name == b"Authorization" or name.lower() == b"authorization"):
            self.authorization = value
        elif n == 6 and name.lower() == b"expect" and value.lower() == b"100-continue":
            t = self.transport
            if t is not None:
                t.write(b"HTTP/1.1 100 Continue\r\n\r\n")
        elif n == 14 and name.lower() == b"content-length" and value.isdigit() and int(value) > MAX_BODY:
            self._fatal(413, b"request body too large")

    def on_body(self, body: bytes):
        if self.closing:
            return
        if len(self.body) + len(body) > MAX_BODY:
            self._fatal(413, b"request body too large")
        else:
            self.body += body

    def on_message_complete(self):
        if self.closing:
            return
        parser = self.parser
        keep_alive = parser.should_keep_alive() and parser.get_http_version() == "1.1"  # no HTTP/1.0 keep-alive
        self.queue.append((parser.get_method(), self.url, self.authorization, self.body, keep_alive))
        if not self.busy:
            self._next()
        elif len(self.queue) >= MAX_PIPELINED and not self.paused and self.transport is not None:
            self.paused = True
            self.transport.pause_reading()

    def _next(self) -> None:
        self.busy = True
        # eager_start runs the handler straight away, up to its first await on the database
        asyncio.Task(self._run(*self.queue.pop(0)), loop=self.loop, eager_start=True)

    async def _run(self, method, url, authorization, body, keep_alive):
        try:
            path, _, query = url.partition(b"?")
            status, payload = await self.handler(method, path, query, authorization, body)
        except Exception:
            traceback.print_exc(file=sys.stderr)
            status, payload = 500, b'{"errors":{"body":["internal server error"]}}'
        t = self.transport
        if t is not None and not self.closing:
            t.write(response_bytes(status, payload, keep_alive))
            if not keep_alive:
                t.close()
                self.closing = True
        self.busy = False
        if self.queue and not self.closing:
            self._next()
        elif self.paused and t is not None:
            self.paused = False
            t.resume_reading()


class Server:
    def __init__(self, handler, loop: asyncio.AbstractEventLoop):
        self.handler = handler
        self.loop = loop
        self.connections: set[HttpProtocol] = set()
        self._server = None

    async def start(self, host: str, port: int) -> None:
        _tick_date(self.loop)
        self._server = await self.loop.create_server(
            lambda: HttpProtocol(self), host, port, reuse_port=True, backlog=65535,
        )
        self.loop.call_later(SWEEP_EVERY_S, self._sweep)

    def _sweep(self) -> None:
        """Close keep-alive connections nobody has used for a long time."""
        cutoff = self.loop.time() - IDLE_TIMEOUT_S
        for c in tuple(self.connections):
            if c.last_active < cutoff and not c.busy and c.transport is not None:
                c.transport.close()
        self.loop.call_later(SWEEP_EVERY_S, self._sweep)

    async def close(self) -> None:
        if self._server is not None:
            self._server.close()
        for c in tuple(self.connections):
            if c.transport is not None:
                c.transport.close()
