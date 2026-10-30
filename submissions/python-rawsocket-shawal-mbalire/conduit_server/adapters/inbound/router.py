import orjson
from types import GeneratorType
import sys
from typing import Callable, Dict, Tuple, Any, Optional, List
from urllib.parse import parse_qs
import re

from conduit_server.adapters.inbound.errors import ApiError


class HttpRequest:
    __slots__ = ("method", "path", "params", "query", "headers", "raw", "body")

    def __init__(self, method, path, params, query, headers, raw, body):
        self.method = method
        self.path = path
        self.params = params  # e.g. {"slug": "how-to-..."} from :slug segments
        self.query = query  # flat dict of first values
        self.headers = headers  # lowercased keys
        self.raw = raw
        self.body = body

    def json(self) -> Any:
        if not self.body:
            return {}
        try:
            return orjson.loads(self.body)
        except (ValueError, UnicodeDecodeError):
            raise ApiError(422, "Invalid JSON body")

    def json_wrapped(self, outer: str) -> dict:
        """{outer: {...}} — missing/not-a-dict wrapper is 422."""
        body = self.json()
        payload = body.get(outer) if isinstance(body, dict) else None
        if not isinstance(payload, dict):
            raise ApiError(422, f"{outer} is required")
        return payload


class _Route:
    __slots__ = ("method", "pattern", "handler", "n_parts", "literals", "param_slots")

    def __init__(self, method: str, pattern: str, handler: Callable):
        self.method = method
        self.pattern = re.compile(_compile_path(pattern))
        self.handler = handler
        parts = pattern.strip("/").split("/")
        self.n_parts = len(parts)
        self.literals = tuple((i, p) for i, p in enumerate(parts) if not p.startswith(":"))
        self.param_slots = tuple((i, p[1:]) for i, p in enumerate(parts) if p.startswith(":"))

    def match(self, method: str, path: str) -> Optional[Dict[str, str]]:
        if method != self.method:
            return None
        m = self.pattern.fullmatch(path)
        return m.groupdict() if m else None


def _compile_path(pattern: str) -> str:
    """'/api/articles/:slug/favorite' -> '/api/articles/(?P<slug>[^/]+)/favorite'"""
    out: List[str] = []
    for part in pattern.strip("/").split("/"):
        out.append(f"(?P<{part[1:]}>[^/]+)" if part.startswith(":") else re.escape(part))
    return "/" + "/".join(out)


class SocketRouter:
    def __init__(self):
        self.routes: List[_Route] = []
        self._by_method: Dict[str, List[_Route]] = {}  # routes with :params, in registration order
        # routes with :params by shape: (method, segment count) -> the param positions of each shape there, and
        # (method, segments with params blanked) -> route; one dict lookup per shape instead of a scan
        self._shapes: Dict[Tuple[str, int], List[Tuple[int, ...]]] = {}
        self._by_shape: Dict[Tuple[str, Tuple[str, ...]], _Route] = {}
        self._static: Dict[Tuple[str, str], _Route] = {}  # (method, path) -> route without params
        # b"METHOD /path" of routes that hold the CPU for tens of ms (bcrypt): the server runs them off its loop
        self.offload: set = set()
        # those of them that, with the Postgres broker, yield their bcrypt to it instead and run on the loop
        self.broker_ok: set = set()

    def get(self, path: str, offload: bool = False, broker: bool = False):
        return self._register("GET", path, offload, broker)

    def post(self, path: str, offload: bool = False, broker: bool = False):
        return self._register("POST", path, offload, broker)

    def put(self, path: str, offload: bool = False, broker: bool = False):
        return self._register("PUT", path, offload, broker)

    def delete(self, path: str, offload: bool = False, broker: bool = False):
        return self._register("DELETE", path, offload, broker)

    def _register(self, method: str, path: str, offload: bool = False, broker: bool = False):
        if offload:
            assert ":" not in path, "offload is matched on the exact path"
            self.offload.add(f"{method} {path}".encode())
            if broker:
                self.broker_ok.add(f"{method} {path}".encode())

        def decorator(func: Callable):
            route = _Route(method, path, func)
            self.routes.append(route)
            if ":" in path:
                self._by_method.setdefault(method, []).append(route)
                slots = tuple(i for i, _ in route.param_slots)
                shapes = self._shapes.setdefault((method, route.n_parts), [])
                if slots not in shapes:
                    shapes.append(slots)
                key = [""] * route.n_parts
                for i, lit in route.literals:
                    key[i] = lit
                self._by_shape.setdefault((method, tuple(key)), route)  # first registered wins, as before
            else:  # exact paths win over patterns (/api/articles/feed vs /api/articles/:slug)
                self._static[(method, path)] = route
            return func

        return decorator

    def dispatch(self, request: HttpRequest):
        """Response bytes, or (handler, query) when a generator handler waits on a query: run the query, then pass
        its result (or error) to `resume`. Handlers return (status, data), or are generators that `yield` the
        repository's Query objects first."""
        route = self._static.get((request.method, request.path))
        if route is None:
            path = request.path
            if len(path) > 1 and path[0] == "/" and "//" not in path and not path.endswith("/"):
                parts = path[1:].split("/")
                for slots in self._shapes.get((request.method, len(parts)), ()):
                    key = parts.copy()
                    for i in slots:
                        key[i] = ""
                    candidate = self._by_shape.get((request.method, tuple(key)))
                    if candidate is not None:
                        route = candidate
                        request.params = {name: parts[i] for i, name in candidate.param_slots}
                        break
            if route is None:
                return self._build_response(404, _NOT_FOUND_BYTES)
        try:
            out = route.handler(request)
            if out.__class__ is GeneratorType:
                return self.resume(out, None, None)
            return self._build_response(*out)
        except ApiError as e:
            return self._build_response(e.status, {"errors": {"body": [e.message]}})
        except Exception as e:
            return _internal_error(e)

    def resume(self, handler, value, error):
        """Continue a generator handler with its query's result (or raise `error` at its `yield`): response bytes
        when it returns, or (handler, query) for the next query it waits on."""
        try:
            query = handler.throw(error) if error is not None else handler.send(value)
        except StopIteration as done:
            return self._build_response(*done.value)
        except ApiError as e:
            return self._build_response(e.status, {"errors": {"body": [e.message]}})
        except Exception as e:
            return _internal_error(e)
        return handler, query

    def dispatch_sync(self, request: HttpRequest) -> bytes:
        """`dispatch`, running each query a handler waits on synchronously (`Query.run`): for threads and the
        offload helper, which have no pipeline."""
        out = self.dispatch(request)
        while out.__class__ is tuple:
            handler, query = out
            try:
                value, error = query.run(), None
            except Exception as e:
                value, error = None, e
            out = self.resume(handler, value, error)
        return out

    @staticmethod
    def _build_response(status_code: int, data: Any) -> bytes:
        # 204 must carry no body: stray bytes would be read as the next keep-alive response
        # orjson serializes dataclasses natively, straight to UTF-8 bytes: about 4x the stdlib C encoder
        # (list page 19.3 → 4.7 µs, user response 0.7 → 0.2 µs, same JSON)
        # bytes are an already-encoded JSON body (built by Postgres)
        if status_code == 204 or data is None:
            if status_code == 204:
                return _EMPTY_204
            body = b""
        elif data.__class__ is bytes:
            body = data
        else:
            body = orjson.dumps(data)
        n = len(body)
        if status_code == 200 and n < 16384:
            return _OK_HEADERS[n] + body
        return b"".join((_STATUS_LINES.get(status_code) or _status_line(status_code),
                         b"Content-Length: ", str(n).encode(), _HEAD_TAIL, body))


def _internal_error(e: Exception) -> bytes:
    """500 with a generic body: the exception's text (Postgres messages included) goes to the log, not the client."""
    print(f"500: {e.__class__.__name__}: {e}", file=sys.stderr, flush=True)
    return SocketRouter._build_response(500, _INTERNAL_ERROR_BYTES)


def _status_line(status_code: int) -> bytes:
    reason = _REASONS.get(status_code, "Error")
    return f"HTTP/1.1 {status_code} {reason}\r\nContent-Type: application/json\r\n".encode("latin1")


_HEAD_TAIL = b"\r\nConnection: keep-alive\r\n\r\n"
_NOT_FOUND_BYTES = b'{"errors":{"body":["Not found"]}}'
_INTERNAL_ERROR_BYTES = b'{"errors":{"body":["Internal error"]}}'
_EMPTY_204 = b"HTTP/1.1 204 No Content\r\nContent-Type: application/json\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n"
_OK_HEADERS = tuple(
    f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {n}\r\nConnection: keep-alive\r\n\r\n".encode("latin1")
    for n in range(16384)
)


_REASONS = {
    200: "OK",
    201: "Created",
    204: "No Content",
    400: "Bad Request",
    401: "Unauthorized",
    403: "Forbidden",
    404: "Not Found",
    422: "Unprocessable Entity",
    500: "Internal Server Error",
}

_STATUS_LINES = {code: _status_line(code) for code in _REASONS}


def parse_request(raw: bytes) -> HttpRequest:
    """Parse one HTTP/1.1 request from buffered bytes (assumes complete head)."""
    try:
        i = raw.find(b"\r\n")
        if raw[:4] == b"GET " and raw.endswith(b"\r\n\r\n"):
            end = len(raw) - 4
            body = b""
        else:
            end = raw.find(b"\r\n\r\n", i)
            if end == -1:
                end = len(raw)
                body = b""
            else:
                body = raw[end + 4 :]
        line0 = raw[:i].decode("latin1")
        s1 = line0.find(" ")
        s2 = line0.find(" ", s1 + 1)
        if s1 <= 0 or s2 <= s1 + 1:
            raise ValueError
        method = line0[:s1]
        full_path = line0[s1 + 1 : s2]
        if "?" in full_path:
            path, _, qs = full_path.partition("?")
            query = _query(qs)
        else:
            path = full_path
            query = {}
        a = raw.find(b"\r\nAuthorization:", i, end)
        if a != -1:
            ve = raw.find(b"\r\n", a + 16)
            headers = {"authorization": raw[a + 16 : ve if ve != -1 else end].decode("latin1").strip()}
        elif b"uthorization" not in raw and b"UTHORIZATION" not in raw:
            headers = {}
        else:
            headers = {}
            for line in raw[i + 2 : end].decode("latin1").split("\r\n"):
                if ":" in line:
                    k, _, v = line.partition(":")
                    if k.strip().lower() == "authorization":
                        headers["authorization"] = v.strip()
        return HttpRequest(method, path, {}, query, headers, raw, body)
    except Exception:
        raise ApiError(400, "Bad request")


def _query(qs: str) -> dict:
    """First value per key, blanks kept: parse_qs(keep_blank_values=True) semantics. Plain strings (no escapes,
    the usual `limit=10&offset=0`) skip parse_qs, which costs microseconds of regex and unquoting."""
    if not qs:
        return {}
    if "%" in qs or "+" in qs:
        return {k: v[0] for k, v in parse_qs(qs, keep_blank_values=True).items()}
    flat = {}
    for pair in qs.split("&"):
        if pair:
            k, _, v = pair.partition("=")
            if k not in flat:
                flat[k] = v
    return flat


router = SocketRouter()
