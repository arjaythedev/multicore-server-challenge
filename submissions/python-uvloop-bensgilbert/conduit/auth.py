import binascii
import hmac
import os
import time

import bcrypt
import orjson

SECRET = os.environ["JWT_SECRET"].encode()
TTL_S = 30 * 24 * 3600
BCRYPT_COST = 10
INT64_MAX = 2**63 - 1

_TO_URL = bytes.maketrans(b"+/", b"-_")
_FROM_URL = bytes.maketrans(b"-_", b"+/")
_digest = hmac.digest
_compare = hmac.compare_digest
_b2a = binascii.b2a_base64
_a2b = binascii.a2b_base64
_loads = orjson.loads


def b64url(data: bytes) -> bytes:
    return _b2a(data, newline=False).rstrip(b"=").translate(_TO_URL)


def _b64url_decode(data: bytes) -> bytes:
    return _a2b(data.translate(_FROM_URL) + b"=" * (-len(data) % 4), strict_mode=True)


_HEADER = b64url(b'{"alg":"HS256","typ":"JWT"}')


def new_token(user_id: int) -> str:
    now = int(time.time())
    payload = b64url(b'{"sub":"%d","iat":%d,"exp":%d}' % (user_id, now, now + TTL_S))
    signing_input = _HEADER + b"." + payload
    return (signing_input + b"." + b64url(_digest(SECRET, signing_input, "sha256"))).decode()


def verify(header: bytes) -> int:
    """Authorization header -> user id (> 0), 0 if there is no header, -1 if the token is no good."""
    if not header:
        return 0
    if header[:6] != b"Token ":
        return -1
    token = header[6:]
    try:
        head, payload, signature = token.split(b".")
        if not _compare(b64url(_digest(SECRET, token[: len(head) + len(payload) + 1], "sha256")), signature):
            return -1
        if head != _HEADER:  # spelled differently, but it still has to say HS256
            h = _loads(_b64url_decode(head))
            if h.get("alg") != "HS256":
                return -1
        claims = _loads(_b64url_decode(payload))
        exp = claims.get("exp")
        if exp is None or exp is True or exp is False or not isinstance(exp, (int, float)) or exp <= time.time():
            return -1
        nbf = claims.get("nbf")
        if nbf is not None and (isinstance(nbf, bool) or not isinstance(nbf, (int, float)) or nbf > time.time()):
            return -1
        sub = claims.get("sub")
    except (ValueError, TypeError, AttributeError, binascii.Error, orjson.JSONDecodeError):
        return -1
    if type(sub) is not str or not sub.isascii() or not sub.isdigit() or len(sub) > 19:
        return -1
    uid = int(sub)
    return uid if 0 < uid <= INT64_MAX else -1


def hash_password(password: str) -> str | None:
    """bcrypt at cost 10. None if bcrypt refuses the password (over 72 bytes)."""
    try:
        return bcrypt.hashpw(password.encode(), bcrypt.gensalt(BCRYPT_COST)).decode()
    except ValueError:
        return None


def check_password(password: str, password_hash: str) -> bool:
    try:
        return bcrypt.checkpw(password.encode(), password_hash.encode())
    except ValueError:
        return False
