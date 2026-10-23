import orjson
from types import GeneratorType
from typing import Callable, Dict, Tuple, Any, Optional, List, Pattern
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
    __slots__ = ("method", "pattern", "handler")

    def __init__(self, method: str, pattern: str, handler: Callable):
        self.method = method
        self.pattern = re.compile(_compile_path(pattern))
        self.handler = handler

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
        self._by_method: Dict[str, List[_Route]] = {}  # routes with :params, regex-matched in order
        self._static: Dict[Tuple[str, str], _Route] = {}  # (method, path) -> route without params
        # b"METHOD /path" of routes that hold the CPU for tens of ms (bcrypt): the server runs them off its loop
        self.offload: set = set()

    def get(self, path: str, offload: bool = False):
        return self._register("GET", path, offload)

    def post(self, path: str, offload: bool = False):
        return self._register("POST", path, offload)

    def put(self, path: str, offload: bool = False):
        return self._register("PUT", path, offload)

    def delete(self, path: str, offload: bool = False):
        return self._register("DELETE", path, offload)

    def _register(self, method: str, path: str, offload: bool = False):
        if offload:
            assert ":" not in path, "offload is matched on the exact path"
            self.offload.add(f"{method} {path}".encode())

        def decorator(func: Callable):
            route = _Route(method, path, func)
            self.routes.append(route)
            if ":" in path:
                self._by_method.setdefault(method, []).append(route)
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
            for candidate in self._by_method.get(request.method, ()):
                m = candidate.pattern.fullmatch(request.path)
                if m is not None:
                    route, request.params = candidate, m.groupdict()
                    break
            else:
                return self._build_response(404, {"errors": {"body": ["Not found"]}})
        try:
            out = route.handler(request)
            if out.__class__ is GeneratorType:
                return self.resume(out, None, None)
            return self._build_response(*out)
        except ApiError as e:
            return self._build_response(e.status, {"errors": {"body": [e.message]}})
        except Exception as e:
            return self._build_response(
                500, {"errors": {"body": [f"Internal error: {e}"]}}
            )

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
            return self._build_response(500, {"errors": {"body": [f"Internal error: {e}"]}})
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
        # bytes are an already-encoded JSON body (article lists, built by Postgres)
        if data is None or status_code == 204:
            body = b""
        elif data.__class__ is bytes:
            body = data
        else:
            body = orjson.dumps(data)
        return b"".join((_STATUS_LINES.get(status_code) or _status_line(status_code),
                         b"Content-Length: ", str(len(body)).encode(), _HEAD_TAIL, body))


def _status_line(status_code: int) -> bytes:
    reason = _REASONS.get(status_code, "Error")
    return f"HTTP/1.1 {status_code} {reason}\r\nContent-Type: application/json\r\n".encode("latin1")


_HEAD_TAIL = b"\r\nConnection: keep-alive\r\n\r\n"


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
        end = raw.find(b"\r\n\r\n")
        if end == -1:
            head, body = raw.decode("latin1"), b""
        else:
            head, body = raw[:end].decode("latin1"), raw[end + 4 :]
        lines = head.split("\r\n")
        parts = lines[0].split(" ")
        method, full_path = parts[0], parts[1]
        path, _, qs = full_path.partition("?")
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                k, _, v = line.partition(":")
                headers[k.strip().lower()] = v.strip()
        return HttpRequest(method, path, {}, _query(qs), headers, raw, body)
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
