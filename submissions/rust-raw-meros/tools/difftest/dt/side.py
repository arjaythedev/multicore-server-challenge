"""One server under test plus the ids it handed out during this run.

Rows created by the run (users, articles, comments) get side-independent
keys in the generator; each side remembers what its own server called them,
so a follow-up request always uses the ids of the server it is sent to.
"""
import json
import re
from dataclasses import dataclass
from urllib.parse import quote

from . import jwtmint
from .client import Call, Resp, Server

SLUG_REF = re.compile(r"\{slug:(\w+)\}")
CID_REF = re.compile(r"\{cid:(\w+)\}")
MISSING_ID = 0  # sub used for a created user the server never confirmed


@dataclass(slots=True)
class Sent:
    """A response together with the exact path and token that produced it."""
    resp: Resp
    token: str | None
    path: str


def _encode(body) -> bytes:
    """UTF-8 JSON; lone surrogates (unencodable as UTF-8) fall back to \\u escapes."""
    try:
        return json.dumps(body, ensure_ascii=False).encode()
    except UnicodeEncodeError:
        return json.dumps(body).encode()


class Side:
    """A server, the JWT secret, and per-run key -> server-assigned value maps."""

    def __init__(self, label: str, base: str, secret: str):
        self.label, self.server, self.secret = label, Server(base), secret
        self.uid: dict = {}      # created-user key -> numeric id (from the token sub)
        self.slug: dict = {}     # article key -> slug
        self.cid: dict = {}      # comment key -> comment id

    def user_id(self, ukey) -> int:
        """Numeric id of a seeded (int key) or created (str key) user."""
        return ukey if isinstance(ukey, int) else self.uid.get(ukey, MISSING_ID)

    def token(self, ukey) -> str:
        return jwtmint.mint(self.user_id(ukey), self.secret)

    def _path(self, path: str) -> str:
        path = SLUG_REF.sub(lambda m: quote(self.slug.get(m.group(1), "missing-" + m.group(1)), safe=""), path)
        return CID_REF.sub(lambda m: str(self.cid.get(m.group(1), 0)), path)

    def _headers(self, call: Call, has_body: bool) -> dict:
        headers = {"Accept": "application/json"}
        if has_body:
            headers["Content-Type"] = "application/json"
        if call.auth is not None:
            kind, value = call.auth
            headers["Authorization"] = "Token " + self.token(value) if kind == "user" else value
        return headers

    def run(self, call: Call) -> Sent:
        """Execute `call` against this server."""
        body = call.body
        if body is not None and not isinstance(body, bytes):
            body = _encode(body)
        headers = self._headers(call, body is not None)
        path = self._path(call.path)
        resp = self.server.send(call.method, path, body, headers)
        token = headers.get("Authorization", "")[len("Token "):] or None
        return Sent(resp, token, path)
