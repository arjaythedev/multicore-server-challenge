"""Keep-alive HTTP client for one server, one connection per thread.

Handled: reconnect when the server closed an idle connection, timeouts.
Not handled: redirects, chunked request bodies, TLS.
"""
import http.client
import threading
from dataclasses import dataclass
from urllib.parse import urlsplit

TIMEOUT_SECONDS = 60
RECONNECT_ERRORS = (http.client.RemoteDisconnected, ConnectionResetError, BrokenPipeError,
                    http.client.CannotSendRequest, http.client.BadStatusLine)


@dataclass(slots=True)
class Resp:
    """What a server answered: status 0 means no answer, see `error`."""
    status: int
    ctype: str
    body: bytes
    error: str = ""


@dataclass(slots=True)
class Call:
    """One request in side-independent form, resolved by `Side.resolve`."""
    method: str
    path: str
    body: object = None          # None, dict/list (sent as JSON) or bytes (sent as is)
    auth: object = None          # None, ("user", ukey), ("raw", header value)
    expect_token: object = None  # ukey whose token the response must echo, if any


class Server:
    """Address of a server plus a per-thread persistent connection."""

    def __init__(self, base: str):
        parts = urlsplit(base)
        self.host, self.port = parts.hostname, parts.port or 80
        self._local = threading.local()

    def _conn(self, fresh: bool = False) -> http.client.HTTPConnection:
        conn = getattr(self._local, "conn", None)
        if conn is None or fresh:
            if conn is not None:
                conn.close()
            conn = http.client.HTTPConnection(self.host, self.port, timeout=TIMEOUT_SECONDS)
            self._local.conn = conn
            self._local.used = False
        return conn

    def send(self, method: str, path: str, body: bytes | None, headers: dict) -> Resp:
        """Send once, retrying a single time if a reused connection was closed."""
        for attempt in (0, 1):
            conn = self._conn(fresh=attempt == 1)
            reused = getattr(self._local, "used", False)
            try:
                conn.request(method, path, body=body, headers=headers)
                raw = conn.getresponse()
                data = raw.read()
                self._local.used = True
                return Resp(raw.status, raw.getheader("Content-Type") or "", data)
            except RECONNECT_ERRORS as exc:
                if attempt == 0 and reused:
                    continue
                return Resp(0, "", b"", f"{type(exc).__name__}: {exc}")
            except (OSError, ValueError, http.client.HTTPException) as exc:
                self._conn(fresh=True)
                return Resp(0, "", b"", f"{type(exc).__name__}: {exc}")
        return Resp(0, "", b"", "unreachable")
