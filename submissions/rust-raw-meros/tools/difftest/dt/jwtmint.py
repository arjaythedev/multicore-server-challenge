"""Mint and check HS256 JWTs, including deliberately broken ones.

Handled: valid tokens, tokens broken in ways every server must reject
(expired, wrong secret, wrong algorithm, malformed) and tokens whose
verdict the SPEC leaves open (see `odd_tokens`).
Not handled: any algorithm other than HS256/HS512/none.
"""
import base64
import hashlib
import hmac
import json
import time

THIRTY_DAYS = 30 * 24 * 3600
CLOCK_SLACK = 120  # seconds of allowed skew when checking iat


def b64u(raw: bytes) -> str:
    """Base64url without padding, as JWT requires."""
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def b64u_decode(text: str) -> bytes:
    """Inverse of `b64u`; raises ValueError on malformed input."""
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _json(obj) -> bytes:
    return json.dumps(obj, separators=(",", ":")).encode()


def sign(claims: dict, secret: str, alg: str = "HS256", header: dict | None = None) -> str:
    """Return a compact JWT; `alg` HS512 and `none` exist to build bad tokens."""
    head = header if header is not None else {"alg": alg, "typ": "JWT"}
    signing = b64u(_json(head)) + "." + b64u(_json(claims))
    if alg == "none":
        return signing + "."
    digest = hashlib.sha512 if alg == "HS512" else hashlib.sha256
    mac = hmac.new(secret.encode(), signing.encode(), digest).digest()
    return signing + "." + b64u(mac)


def mint(user_id, secret: str, now: int | None = None) -> str:
    """A token as the SPEC defines it: sub is the decimal user id."""
    now = int(time.time()) if now is None else now
    return sign({"sub": str(user_id), "iat": now, "exp": now + THIRTY_DAYS}, secret)


def check(token, secret: str, now: int | None = None):
    """Verify a server-issued token. Returns (claims, "") or (None, reason)."""
    now = int(time.time()) if now is None else now
    if not isinstance(token, str) or token.count(".") != 2:
        return None, "not a compact JWT"
    head_b64, claims_b64, sig_b64 = token.split(".")
    try:
        head = json.loads(b64u_decode(head_b64))
        claims = json.loads(b64u_decode(claims_b64))
        sig = b64u_decode(sig_b64)
    except (ValueError, json.JSONDecodeError):
        return None, "undecodable part"
    if not isinstance(head, dict) or head.get("alg") != "HS256":
        return None, "alg is not HS256"
    want = hmac.new(secret.encode(), (head_b64 + "." + claims_b64).encode(), hashlib.sha256).digest()
    if not hmac.compare_digest(want, sig):
        return None, "bad signature"
    return _check_claims(claims, now)


def _check_claims(claims, now: int):
    """Claims must carry a decimal-string sub and a 30-day lifetime."""
    sub = claims.get("sub") if isinstance(claims, dict) else None
    iat, exp = claims.get("iat"), claims.get("exp")
    if not (isinstance(sub, str) and sub.isdigit()):
        return None, "sub is not a decimal string"
    if not (isinstance(iat, int) and isinstance(exp, int)):
        return None, "iat/exp are not integers"
    if abs(iat - now) > CLOCK_SLACK or abs(exp - iat - THIRTY_DAYS) > CLOCK_SLACK:
        return None, f"iat/exp off: iat={iat} exp={exp} now={now}"
    return claims, ""


def rejected_tokens(secret: str, user_id: int, now: int) -> list:
    """(label, token) pairs that every conforming server must answer with 401."""
    good = {"sub": str(user_id), "iat": now, "exp": now + THIRTY_DAYS}
    expired = {"sub": str(user_id), "iat": now - 4000, "exp": now - 1000}
    return [
        ("expired", sign(expired, secret)),
        ("wrong-secret", sign(good, secret + "x")),
        ("alg-none", sign(good, secret, alg="none")),
        ("alg-hs512", sign(good, secret, alg="HS512")),
        ("garbage", "not-a-jwt"),
        ("two-parts", sign(good, secret).rsplit(".", 1)[0]),
        ("empty-signature", sign(good, secret).rsplit(".", 1)[0] + "."),
        ("flipped-signature", _flip_last(sign(good, secret))),
    ]


def _flip_last(token: str) -> str:
    """Change the first signature character, which always alters the MAC bytes."""
    head, sig = token.rsplit(".", 1)
    return head + "." + ("B" if sig[0] != "B" else "C") + sig[1:]


def odd_tokens(secret: str, user_id: int, now: int) -> list:
    """(label, token) pairs whose verdict the SPEC leaves open; differences are informative."""
    uid = str(user_id)
    cases = {
        "no-exp": {"sub": uid, "iat": now},
        "sub-int": {"sub": user_id, "iat": now, "exp": now + THIRTY_DAYS},
        "sub-alpha": {"sub": "abc", "iat": now, "exp": now + THIRTY_DAYS},
        "sub-zero": {"sub": "0", "iat": now, "exp": now + THIRTY_DAYS},
        "sub-huge": {"sub": "99999999999999999999", "iat": now, "exp": now + THIRTY_DAYS},
        "sub-negative": {"sub": "-5", "iat": now, "exp": now + THIRTY_DAYS},
        "no-sub": {"iat": now, "exp": now + THIRTY_DAYS},
        "no-iat": {"sub": uid, "exp": now + THIRTY_DAYS},
        "nbf-future": {"sub": uid, "iat": now, "exp": now + THIRTY_DAYS, "nbf": now + 3600},
        "exp-string": {"sub": uid, "iat": now, "exp": str(now + THIRTY_DAYS)},
        "exp-float": {"sub": uid, "iat": now, "exp": now + THIRTY_DAYS + 0.5},
        "extra-claims": {"sub": uid, "iat": now, "exp": now + THIRTY_DAYS, "admin": True},
    }
    tokens = [(name, sign(claims, secret)) for name, claims in cases.items()]
    tokens.append(("lowercase-alg", sign(cases["extra-claims"], secret, header={"alg": "hs256", "typ": "JWT"})))
    tokens.append(("no-typ", sign(cases["extra-claims"], secret, header={"alg": "HS256"})))
    return tokens
