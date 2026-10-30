import binascii
import ctypes
import hashlib
import hmac
import orjson
import threading
import time
import warnings

import bcrypt
import jwt

from conduit_server.ports.outbound import CryptoPort

_HS256 = "HS256"
_EXP_30_DAYS_SECONDS = 30 * 24 * 3600
# bcrypt releases the GIL but holds a thread ~50 ms: cap concurrent hashes so a login burst
# can't occupy every request thread in the worker.
_BCRYPT_SLOTS = threading.BoundedSemaphore(2)
_MAX_PASSWORD = 72  # bcrypt's key limit; longer passwords are rejected (pyca/bcrypt raises ValueError)
_CRYPT_DATA = 65536  # >= sizeof(struct crypt_data) (~32 KiB); one zeroed buffer per call keeps crypt_rn reentrant
_B64_DECODE_TR = bytes.maketrans(b"-_", b"+/")
_B64_ENCODE_TR = bytes.maketrans(b"+/", b"-_")
_B64_PAD = (b"", b"===", b"==", b"=")
_NUM_TYPES = (int, float)


def _load_crypt_rn():
    """The OS's libxcrypt `crypt_rn` (C bcrypt, ~14% less CPU than pyca/bcrypt at cost 10), or None.
    Same algorithm and hash format ($2a$/$2b$), so either implementation verifies the other's hashes."""
    for name in ("libcrypt.so.1", "libcrypt.so.2"):  # Ubuntu 24.04 ships libxcrypt as libcrypt.so.1
        try:
            fn = ctypes.CDLL(name).crypt_rn
        except (OSError, AttributeError):
            continue
        fn.restype = ctypes.c_char_p
        fn.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_int]
        probe = bcrypt.hashpw(b"probe", bcrypt.gensalt(4))
        if fn(b"probe", probe, ctypes.create_string_buffer(_CRYPT_DATA), _CRYPT_DATA) == probe:
            return fn
    return None


_crypt_rn = _load_crypt_rn()


def _bcrypt(password: bytes, setting: bytes):
    """bcrypt via libxcrypt (ctypes releases the GIL), or None to fall back to pyca/bcrypt. C strings end at NUL,
    so passwords containing one always use pyca, for hashing and verifying alike."""
    if _crypt_rn is None or b"\0" in password:
        return None
    out = _crypt_rn(password, setting, ctypes.create_string_buffer(_CRYPT_DATA), _CRYPT_DATA)
    return out if out and out.startswith(b"$2") else None


class JoseBcryptCryptoAdapter(CryptoPort):
    def __init__(self, secret_key: str):
        self._secret = secret_key
        self._key = secret_key.encode("utf-8")
        base = hmac.new(self._key, digestmod=hashlib.sha256)
        # the C HMAC object inside the stdlib wrapper (same copy/update/digest): the wrapper's Python copy() cost
        # ~0.4 µs per token
        self._base_hmac = getattr(base, "_hmac", None) or base
        # PyJWT's header for every HS256 token we issue: a token carrying exactly this segment needs no decoding
        with warnings.catch_warnings():  # PyJWT warns about short keys; the secret is given by the spec
            warnings.simplefilter("ignore")
            hdr = jwt.encode({}, secret_key, algorithm=_HS256).partition(".")[0]
        self._hs256_header = hdr
        self._hs256_header_b = hdr.encode("ascii")
        self._hs256_prefix_b = self._hs256_header_b + b"."

    def hash_password(self, password: str) -> str:
        pw = password.encode("utf-8")
        if len(pw) > _MAX_PASSWORD:
            raise ValueError("password cannot be longer than 72 bytes")
        salt = bcrypt.gensalt(rounds=10)
        with _BCRYPT_SLOTS:
            hashed = _bcrypt(pw, salt) or bcrypt.hashpw(pw, salt)
        return hashed.decode("utf-8")

    def verify_password(self, password: str, password_hash: str) -> bool:
        pw, stored = password.encode("utf-8"), password_hash.encode("utf-8")
        if len(pw) > _MAX_PASSWORD:
            return False
        try:
            with _BCRYPT_SLOTS:
                computed = _bcrypt(pw, stored)
                if computed is None:
                    return bcrypt.checkpw(pw, stored)
            return hmac.compare_digest(computed, stored)
        except ValueError:
            return False

    def issue_token(self, user_id: int) -> str:
        now = int(time.time())
        payload_b64 = (
            binascii.b2a_base64(
                orjson.dumps({"sub": str(user_id), "iat": now, "exp": now + _EXP_30_DAYS_SECONDS}),
                newline=False,
            )
            .rstrip(b"=")
            .translate(_B64_ENCODE_TR)
        )
        signing_input = self._hs256_prefix_b + payload_b64
        h = self._base_hmac.copy()
        h.update(signing_input)
        sig_b64 = binascii.b2a_base64(h.digest(), newline=False).rstrip(b"=").translate(_B64_ENCODE_TR)
        return (signing_input + b"." + sig_b64).decode("ascii")

    def verify_token(self, token: str) -> int:
        """Verify HS256 signature + exp on every call (no caching). Returns user id.

        Same checks PyJWT.decode(algorithms=["HS256"], require exp/iat/sub) makes, with stdlib hmac:
        PyJWT validates base64 one character at a time in Python, which dominated request CPU."""
        raw = token.encode("ascii")
        signing_input, _, sig_b64 = raw.rpartition(b".")
        header_b64, _, payload_b64 = signing_input.partition(b".")
        if not header_b64 or b"." in payload_b64:
            raise ValueError("a JWT has exactly three segments")
        h = self._base_hmac.copy()
        h.update(signing_input)
        if not hmac.compare_digest(h.digest(), _b64decode_b(sig_b64)):
            raise ValueError("bad signature")
        if header_b64 != self._hs256_header_b:
            hdr = orjson.loads(_b64decode_b(header_b64))
            if not isinstance(hdr, dict) or hdr.get("alg") != _HS256:
                raise ValueError("only HS256 is accepted")
        payload = orjson.loads(_b64decode_b(payload_b64))
        now = time.time()
        exp, iat = payload["exp"], payload["iat"]
        if exp.__class__ not in _NUM_TYPES or exp <= now:
            raise ValueError("expired")
        if iat.__class__ not in _NUM_TYPES or iat > now:
            raise ValueError("issued in the future")
        nbf = payload.get("nbf")
        if nbf is not None and (nbf.__class__ not in _NUM_TYPES or nbf > now):
            raise ValueError("not yet valid")
        sub = payload["sub"]
        if sub.__class__ is not str:
            raise ValueError("sub must be a string")
        return int(sub)


def _b64decode_b(segment: bytes) -> bytes:
    """base64url without padding. strict_mode: any character outside the alphabet is an error (the default mode
    skips them, so a signature with junk mixed in would still decode)."""
    return binascii.a2b_base64(segment.translate(_B64_DECODE_TR) + _B64_PAD[len(segment) & 3], strict_mode=True)
