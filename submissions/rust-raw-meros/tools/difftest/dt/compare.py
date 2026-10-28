"""Normalise two responses and find their first structural difference.

Normalised away (legitimately differs between two correct servers):
  * error message text (SPEC: free text, shape checked);
  * `token`: must be a valid HS256 JWT; on GET/PUT /api/user it must be the
    token the request presented, otherwise only its `sub` is compared;
  * `createdAt`/`updatedAt` of rows touched during the run (timestamp at or
    after the run start): only the RFC 3339 3-digit format is compared.
Everything else is compared literally and type-strictly (1 != 1.0 != true).
Not handled: JSON key order (irrelevant per SPEC), whitespace.
"""
import calendar
import json
import re

from . import jwtmint

TS_FORMAT = re.compile(r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)\.\d{3}Z$")
FRESH_SLACK = 5  # seconds before the run start still counted as "created by the run"
TRUNCATE = 600
DETAIL_CLIP = 160


def parse_utc(text: str):
    """Epoch seconds of a SPEC-format timestamp, or None if the format is wrong."""
    m = TS_FORMAT.match(text)
    if not m:
        return None
    y, mo, d, h, mi, s = map(int, m.groups())
    return calendar.timegm((y, mo, d, h, mi, s))


class Normaliser:
    """Rewrites one response body into its comparable form."""

    def __init__(self, secret: str, run_start: float, sent_token: str | None, expect_token: bool):
        self.secret, self.run_start = secret, run_start
        self.sent_token, self.expect_token = sent_token, expect_token

    def body(self, node, key=None):
        if isinstance(node, dict):
            if set(node) == {"errors"}:
                return self._errors(node)
            return {k: self.body(v, k) for k, v in node.items()}
        if isinstance(node, list):
            return [self.body(v) for v in node]
        if isinstance(node, str):
            if key == "token":
                return self._token(node)
            if key in ("createdAt", "updatedAt"):
                return self._timestamp(node)
        return node

    @staticmethod
    def _errors(node):
        inner = node["errors"]
        ok = (isinstance(inner, dict) and set(inner) == {"body"} and isinstance(inner["body"], list)
              and inner["body"] and all(isinstance(m, str) and m for m in inner["body"]))
        return {"errors": {"body": ["<msg>"]}} if ok else node

    def _token(self, token: str):
        if self.expect_token:
            return "<echo>" if token == self.sent_token else "<NOT THE PRESENTED TOKEN> " + token
        claims, why = jwtmint.check(token, self.secret)
        return f"<jwt sub={claims['sub']}>" if claims else f"<INVALID JWT: {why}> {token}"

    def _timestamp(self, text: str):
        epoch = parse_utc(text)
        if epoch is None:
            return "<BAD TIMESTAMP FORMAT> " + text
        return "<fresh ts>" if epoch >= self.run_start - FRESH_SLACK else text


def summarise(resp, call, sent_token, secret, run_start):
    """(status, content-type ok, normalised body or raw text) for one response."""
    if resp.status == 0:
        return (0, False, "<NO RESPONSE> " + resp.error)
    ctype_ok = resp.ctype.lower().startswith("application/json")
    if not resp.body:
        return (resp.status, ctype_ok or resp.status == 204, None)
    try:
        parsed = json.loads(resp.body)
    except ValueError:
        return (resp.status, ctype_ok, "<RAW> " + resp.body[:TRUNCATE].decode("utf-8", "replace"))
    norm = Normaliser(secret, run_start, sent_token, call.expect_token is not None)
    return (resp.status, ctype_ok, norm.body(parsed))


def first_diff(a, b, path="$"):
    """First (path, a_value, b_value) where the two JSON values differ, or None."""
    if type(a) is not type(b):
        return (path, a, b)
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                return (f"{path}.{k}", a.get(k, "<absent>"), b.get(k, "<absent>"))
            hit = first_diff(a[k], b[k], f"{path}.{k}")
            if hit:
                return hit
        return None
    if isinstance(a, list):
        for i, (x, y) in enumerate(zip(a, b)):
            hit = first_diff(x, y, f"{path}[{i}]")
            if hit:
                return hit
        return None if len(a) == len(b) else (f"{path}.length", len(a), len(b))
    return None if a == b else (path, a, b)


def compare(sa, sb):
    """(reason, detail) describing how two summaries differ, or None when equal."""
    if sa[0] != sb[0]:
        return "status", f"{sa[0]} != {sb[0]}"
    if sa[1] != sb[1]:
        return "content-type", f"json content type: {sa[1]} != {sb[1]}"
    hit = first_diff(sa[2], sb[2])
    return (f"body {hit[0]}", f"A={_clip(hit[1], DETAIL_CLIP)} B={_clip(hit[2], DETAIL_CLIP)}") if hit else None


def clip(value) -> str:
    """Compact JSON text of a normalised body, truncated for reports."""
    return _clip(value, TRUNCATE)


def _clip(value, limit: int) -> str:
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    return text if len(text) <= limit else text[:limit] + f"... (+{len(text) - limit} chars)"
