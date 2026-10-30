import binascii
import ctypes
import hashlib
import hmac
import os
import orjson
import re
import threading
import time
from collections import deque
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


# ---- multi-lane bcrypt ------------------------------------------------------------------------------------------
# native/bcrypt_lanes.c (built by build.sh): up to 8 hashes in lockstep, so one hash's S-box loads overlap the others'
# waits. Cost 10 per hash, single thread: 1 lane 37.6 ms (libxcrypt 38.4), 2: 19.8, 4: 11.3, 6: 8.8, 8: 9.3.
LANES = 6
_SETTING = re.compile(rb"\$2[aby]\$(0[4-9]|[12][0-9]|3[01])\$[./A-Za-z0-9]{22}")


def _load_lanes():
    """The native `bcrypt_many`, or None (not built, or its output differs from libxcrypt/pyca on a probe)."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "native", "libbcrypt_lanes.so")
    try:
        fn = ctypes.CDLL(path).bcrypt_many
    except (OSError, AttributeError):
        return None
    fn.restype = ctypes.c_int
    fn.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_char_p), ctypes.c_char_p]
    pws = [b"probe", b"another probe \xc3\xa9", b"x" * 72]
    settings = [bcrypt.gensalt(4, prefix=p) for p in (b"2a", b"2b", b"2b")]
    out = ctypes.create_string_buffer(61 * 3)
    if fn(3, (ctypes.c_char_p * 3)(*pws), (ctypes.c_char_p * 3)(*settings), out) != 0:
        return None
    for i, (pw, s) in enumerate(zip(pws, settings)):
        if out.raw[61 * i : 61 * i + 60] != bcrypt.hashpw(pw, s):
            return None
    return fn


_lanes = _load_lanes()


def _load_jwt_verify():
    """native/jwt_verify.c (built by build.sh): HS256 verification of our own tokens in C, or None if not built
    or JWT_NATIVE=0."""
    if os.environ.get("JWT_NATIVE", "1") == "0":
        return None
    import importlib.machinery
    import importlib.util

    native = os.path.join(os.path.dirname(os.path.abspath(__file__)), "native")
    for suffix in importlib.machinery.EXTENSION_SUFFIXES:
        path = os.path.join(native, "_jwt_verify" + suffix)
        if os.path.exists(path):
            spec = importlib.util.spec_from_file_location("_jwt_verify", path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            break
    else:
        return None
    for key in (b"", b"k", b"x" * 64, b"y" * 100):
        for msg in (b"", b"m" * 55, b"m" * 56, b"m" * 200):
            if mod.hmac_sha256(key, msg) != hmac.digest(key, msg, "sha256"):
                return None
    return mod


_jwt_native = _load_jwt_verify()


def _bcrypt_one(password: bytes, setting: bytes):
    """One hash without the lanes: libxcrypt, else pyca. None if `setting` isn't a bcrypt setting."""
    try:
        return _bcrypt(password, setting) or bcrypt.hashpw(password, setting)
    except ValueError:
        return None


def bcrypt_many(jobs) -> list:
    """bcrypt of each (password, setting) pair (both bytes, password at most 72 bytes): the hash, or None for a
    malformed setting. Valid jobs run together on the lanes; a password with a NUL (C strings end there) or an odd
    setting goes through libxcrypt/pyca on its own. Releases the GIL while hashing."""
    out = [None] * len(jobs)
    lane = []
    for i, (pw, setting) in enumerate(jobs):
        if _lanes is not None and b"\0" not in pw and _SETTING.match(setting):
            lane.append(i)
        else:
            out[i] = _bcrypt_one(pw, setting)
    for start in range(0, len(lane), LANES):
        idx = lane[start : start + LANES]
        n = len(idx)
        buf = ctypes.create_string_buffer(61 * n)
        pws = (ctypes.c_char_p * n)(*[jobs[i][0] for i in idx])
        settings = (ctypes.c_char_p * n)(*[jobs[i][1] for i in idx])
        if _lanes(n, pws, settings, buf) == 0:
            raw = buf.raw
            for k, i in enumerate(idx):
                out[i] = raw[61 * k : 61 * k + 60]
        else:  # can't happen after _SETTING; stay correct anyway
            for i in idx:
                out[i] = _bcrypt_one(*jobs[i])
    return out


def _false(_) -> bool:
    return False


class _BcryptStmt:
    index = -1  # the broker's marker for a bcrypt job (statements are 0..n)


class BcryptJob:
    """A bcrypt a handler waits on (`ok = yield crypto.q_verify_password(...)`), like a repository Query: the broker
    runs it on its bcrypt threads with other workers' logins (BcryptBatcher); `run()` computes it in place."""

    __slots__ = ("args", "finish")
    stmt = _BcryptStmt
    json = True
    write = False

    def __init__(self, password: bytes, setting: bytes, finish):
        self.args, self.finish = (password, setting), finish

    def run(self):
        return self.finish(bcrypt_many([self.args])[0])


class BcryptBatcher:
    """The broker's bcrypt threads. `submit` queues a job; finished (token, hash) pairs collect in `done` and
    `efd` (an eventfd for the broker's epoll) is signalled. The first thread runs up to LANES queued jobs once LANES
    are queued or the oldest has waited `wait` seconds (a lone login waits for company: 6 lanes cost 4.4x less per
    hash than 1). The others take only full batches, for backlogs: an extra thread that took every job split the
    queue into small, costly batches."""

    def __init__(self, threads: int, wait: float):
        self.wait = wait
        self.queue = deque()  # (arrival, token, password, setting)
        self.cv = threading.Condition()
        self.done = deque()
        self.efd = os.eventfd(0, os.EFD_NONBLOCK | os.EFD_CLOEXEC)
        for k in range(max(1, threads)):
            threading.Thread(target=self._run, args=(k == 0,), daemon=True, name=f"bcrypt-{k}").start()

    def submit(self, token, password: bytes, setting: bytes):
        with self.cv:
            self.queue.append((time.monotonic(), token, password, setting))
            if len(self.queue) == 1 or len(self.queue) >= LANES:
                self.cv.notify_all()

    def results(self) -> list:
        try:
            os.eventfd_read(self.efd)
        except BlockingIOError:
            pass
        done, out = self.done, []
        while done:
            out.append(done.popleft())
        return out

    def _run(self, primary: bool):
        q, cv = self.queue, self.cv
        while True:
            with cv:
                while True:
                    n = len(q)
                    if n >= LANES:
                        break
                    if primary and n:
                        left = q[0][0] + self.wait - time.monotonic()
                        if left <= 0:
                            break
                        cv.wait(left)
                    else:
                        cv.wait()
                batch = [q.popleft() for _ in range(min(LANES, len(q)))]
            try:
                hashes = bcrypt_many([(pw, s) for _, _, pw, s in batch])
            except Exception:  # never lose a waiting login: answer None (verify fails)
                hashes = [None] * len(batch)
            self.done.extend((job[1], h) for job, h in zip(batch, hashes))
            os.eventfd_write(self.efd, 1)


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
        if _jwt_native is not None:
            _jwt_native.init(self._key, self._hs256_header_b)  # process-wide: one secret per server

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

    def q_verify_password(self, password: str, password_hash: str) -> BcryptJob:
        """`verify_password` as a job a handler yields: True if the password matches. Over 72 bytes it can't (bcrypt
        would use only the first 72), so that job hashes nothing useful and answers False."""
        pw, stored = password.encode("utf-8"), password_hash.encode("utf-8")
        if len(pw) > _MAX_PASSWORD:
            return BcryptJob(b"", stored, _false)
        return BcryptJob(pw, stored, lambda computed: computed is not None and hmac.compare_digest(computed, stored))

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
        """Verify HS256 signature + exp on every call (no caching). Returns user id. Tokens in our own form are
        checked in C (`_jwt_native.verify`, same result as `_verify_token_py`); anything else in Python."""
        if _jwt_native is not None:
            user_id = _jwt_native.verify(token)
            if user_id is not None:
                return user_id
        return self._verify_token_py(token)

    def _verify_token_py(self, token: str) -> int:
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
