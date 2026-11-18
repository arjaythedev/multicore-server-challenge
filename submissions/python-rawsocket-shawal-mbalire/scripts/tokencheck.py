"""Every TOKENS adapter against the default (hs256, C verify): the same user id or the same rejection for valid
tokens, mutations of them, and tokens signed with other headers and payloads. Prints mismatches and timings.

    .venv/bin/python scripts/tokencheck.py
"""
import base64
import hashlib
import hmac
import json
import os
import random
import sys
import time
import timeit

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from conduit_server import registry  # noqa: E402

SECRET = "dev-secret"


def _b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _sign(header: dict, payload, secret=SECRET) -> str:
    hp = _b64(json.dumps(header, separators=(",", ":")).encode()) + "." + _b64(
        payload if isinstance(payload, bytes) else json.dumps(payload, separators=(",", ":")).encode())
    return hp + "." + _b64(hmac.digest(secret.encode(), hp.encode(), "sha256"))


def tokens(issuer, n=4000):
    rnd = random.Random(7)
    now = int(time.time())
    out = [issuer.issue_token(rnd.randrange(1, 10**9)) for _ in range(50)]
    hs = {"alg": "HS256", "typ": "JWT"}
    for _ in range(n):
        uid = rnd.choice([1, 42, 10**12, 0])
        payload = {"sub": rnd.choice([str(uid), uid, " 1", "1a", ""]), "iat": rnd.choice([now - 5, now + 3600, "x"]),
                   "exp": rnd.choice([now + 99, now - 1, 1.5e12, None])}
        for k in list(payload):
            if rnd.random() < 0.1:
                del payload[k]
        if rnd.random() < 0.2:
            payload["nbf"] = rnd.choice([now - 1, now + 999])
        header = rnd.choice([hs, {"alg": "HS256"}, {"typ": "JWT", "alg": "HS256"}, {"alg": "none"},
                             {"alg": "HS512"}, {"alg": "HS256", "kid": "1"}])
        tok = _sign(header, payload, rnd.choice([SECRET, SECRET, "other"]))
        if rnd.random() < 0.3:  # mutate a character, append, truncate, pad
            i = rnd.randrange(len(tok))
            tok = rnd.choice([tok[:i] + rnd.choice("A_-=.+/ é") + tok[i + 1:], tok + "=", tok[:i], tok + ".x"])
        out.append(tok)
    out += ["", ".", "..", "a.b.c", "a.b", out[0] + "  ", " " + out[0]]
    return out


def outcome(svc, tok):
    try:
        return svc.verify_token(tok)
    except Exception:
        return "rejected"


def main():
    names = list(registry.ADAPTERS["TOKENS"])
    svcs = {}
    for name in names:
        os.environ["TOKENS"] = name
        svcs[name] = registry.adapter("TOKENS")(secret_key=SECRET)
    ref = svcs[names[0]]
    toks = tokens(ref)
    want = [outcome(ref, t) for t in toks]
    good = ref.issue_token(123456)
    for name, svc in svcs.items():
        bad = [(t, outcome(svc, t), w) for t, w in zip(toks, want) if outcome(svc, t) != w]
        t_ns = min(timeit.repeat(lambda: svc.verify_token(good), number=20000, repeat=5)) / 20000 * 1e9
        print(f"{name:9} mismatches {len(bad)}/{len(toks)} ({sum(w != 'rejected' for w in want)} valid)"
              f"  | verify {t_ns:.0f} ns")
        for t, got, w in bad[:5]:
            print(f"    {t[:70]}...: {got} vs {w}")


if __name__ == "__main__":
    main()
