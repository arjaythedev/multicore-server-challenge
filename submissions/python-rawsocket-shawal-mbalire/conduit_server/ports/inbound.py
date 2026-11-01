"""Inbound ports: what a transport (epoll loop, uvloop, ...) needs from the application, and the request it hands
over. Nothing here imports an adapter; transports and the router both depend on these."""

from typing import Any, Protocol, Union


class HttpRequest:
    """One parsed HTTP/1.1 request, as every transport hands it to the application."""

    __slots__ = ("method", "path", "params", "query", "headers", "raw", "body")

    def __init__(self, method, path, params, query, headers, raw, body):
        self.method = method
        self.path = path
        self.params = params  # e.g. {"slug": "how-to-..."} from :slug segments
        self.query = query  # flat dict of first values
        self.headers = headers  # lowercased keys (only "authorization" is kept)
        self.raw = raw
        self.body = body  # bytes after the head


class RequestParser(Protocol):
    """Raw bytes of one complete request (head + body) -> HttpRequest; raises on a malformed request (400)."""

    def __call__(self, raw: bytes) -> HttpRequest: ...


class HttpApplication(Protocol):
    """The application as a transport sees it. `dispatch` returns finished response bytes, or (handler, query) when a
    handler waits on a query (a QueryPort): the transport runs the query however it likes (pipelined, on another
    process, in place) and passes the result, or the error, to `resume`, which answers the same way."""

    offload: set  # b"METHOD /path" of routes that hold the CPU for tens of ms: run them off the loop
    broker_ok: set  # those of them that yield their CPU work to the Postgres broker instead

    def dispatch(self, request: HttpRequest) -> Union[bytes, tuple]: ...

    def resume(self, handler: Any, value: Any, error: Any) -> Union[bytes, tuple]: ...

    def dispatch_sync(self, request: HttpRequest) -> bytes:
        """`dispatch`, running every query in place (`QueryPort.run`)."""


class InboundServer(Protocol):
    """A transport serving one worker: built by the composition root, then `start()` runs it forever."""

    def start(self) -> None: ...
