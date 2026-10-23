import json
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
            return json.loads(self.body)
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

    def get(self, path: str):
        return self._register("GET", path)

    def post(self, path: str):
        return self._register("POST", path)

    def put(self, path: str):
        return self._register("PUT", path)

    def delete(self, path: str):
        return self._register("DELETE", path)

    def _register(self, method: str, path: str):
        def decorator(func: Callable):
            self.routes.append(_Route(method, path, func))
            return func

        return decorator

    def dispatch(self, request: HttpRequest) -> bytes:
        for route in self.routes:
            params = route.match(request.method, request.path)
            if params is None:
                continue
            request.params = params
            try:
                return self._build_response(*route.handler(request))
            except ApiError as e:
                return self._build_response(e.status, {"errors": {"body": [e.message]}})
            except Exception as e:
                return self._build_response(
                    500, {"errors": {"body": [f"Internal error: {e}"]}}
                )

        return self._build_response(404, {"errors": {"body": ["Not found"]}})

    @staticmethod
    def _build_response(status_code: int, data: Any) -> bytes:
        if data is None:
            body = b""
        else:
            payload = data
            import dataclasses

            if dataclasses.is_dataclass(data):
                payload = dataclasses.asdict(data)
            body = json.dumps(payload).encode("utf-8")

        reason = _REASONS.get(status_code, "Error")
        head = (
            f"HTTP/1.1 {status_code} {reason}\r\n"
            f"Content-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\n"
            "Connection: keep-alive\r\n\r\n"
        ).encode("latin1")
        return head + body


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


def parse_request(raw: bytes) -> HttpRequest:
    """Parse one HTTP/1.1 request from buffered bytes (assumes complete head)."""
    try:
        text = raw.decode("latin1")
        head, _, body = text.partition("\r\n\r\n")
        lines = head.split("\r\n")
        parts = lines[0].split(" ")
        method, full_path = parts[0], parts[1]
        path, _, qs = full_path.partition("?")
        flat = {k: v[0] for k, v in parse_qs(qs, keep_blank_values=True).items()}
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                k, _, v = line.partition(":")
                headers[k.strip().lower()] = v.strip()
        return HttpRequest(method, path, {}, flat, headers, raw, body.encode("latin1"))
    except Exception:
        raise ApiError(400, "Bad request")


router = SocketRouter()
