"""Every JSON codec adapter against orjson (the default): dumps byte-identical on the response dataclasses, loads
the same values (or both rejecting) on valid and invalid request bodies. Prints mismatches and per-call timings.

    .venv/bin/python scripts/codeccheck.py        # needs ALT_ADAPTERS=1 bash build.sh for msgspec
"""
import os
import random
import sys
import timeit

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from conduit_server import registry  # noqa: E402
from conduit_server.domain.models import (  # noqa: E402
    ArticleData, ArticlesResponse, CommentData, CommentsResponse, ProfileData, ProfileResponse, TagsResponse,
    UserData, UserResponse,
)

TEXTS = ["", "plain", "quote \" backslash \\ slash /", "tab\tnewline\ncr\r", "\x00\x01\x1f\x7f", "é ü 中文 😀",
         "  ", "<script>&amp;</script>", "x" * 3000]


def _text(rnd):
    return rnd.choice(TEXTS) + rnd.choice(TEXTS)


def _profile(rnd):
    return ProfileData(_text(rnd), rnd.choice([None, _text(rnd)]), rnd.choice([None, _text(rnd)]), rnd.random() < .5)


def _article(rnd):
    return ArticleData(_text(rnd), _text(rnd), _text(rnd), rnd.choice([None, _text(rnd)]),
                       [_text(rnd) for _ in range(rnd.randrange(4))], "2026-10-31T12:00:00.000Z",
                       "2026-10-31T12:00:00.123Z", rnd.random() < .5, rnd.randrange(2**31), _profile(rnd))


def values(n=2000):
    rnd = random.Random(1)
    out = [{"errors": {"body": ["Invalid token"]}}, TagsResponse(), TagsResponse(["a", "é"])]
    for _ in range(n):
        out.append(rnd.choice([
            lambda: UserResponse(UserData(_text(rnd), "a.b.c", _text(rnd), rnd.choice([None, _text(rnd)]), None)),
            lambda: ProfileResponse(_profile(rnd)),
            lambda: ArticlesResponse([_article(rnd) for _ in range(rnd.randrange(21))], rnd.randrange(10**6)),
            lambda: CommentsResponse([CommentData(rnd.randrange(2**62), "t", "u", _text(rnd), _profile(rnd))
                                      for _ in range(rnd.randrange(5))]),
        ])())
    return out


BODIES = [b'{"user":{"email":"a@b.c","password":"x"}}', b'{"article":{"title":"\\u00e9\\ud83d\\ude00","tagList":[]}}',
          b'{}', b'[]', b'null', b'1', b'"s"', b' {"a" : 1 } ', b'{"a":1.5e3,"b":-0,"c":true,"d":null}',
          b'{"a":1,"a":2}', b'{', b'', b'{"a":}', b"{'a':1}", b'{"a":1,}', b'\xff\xfe', b'{"a":"\xff"}',
          b'NaN', b'{"a":NaN}', b'{"a":Infinity}', b'\xef\xbb\xbf{}', b'{"a":"\x01"}', b'{"a":1e400}',
          b'{"a":12345678901234567890123}', b'{"a":"\\ud800"}', b'[' * 2000 + b']' * 2000]


def _load(codec, body):
    try:
        return "ok", codec.loads(body)
    except (ValueError, UnicodeDecodeError, RecursionError):
        return "rejected", None


def main():
    names = list(registry.ADAPTERS["JSON_CODEC"])
    ref_name = names[0]
    codecs = {}
    for name in names:
        os.environ["JSON_CODEC"] = name
        try:
            codecs[name] = registry.adapter("JSON_CODEC")()
        except ImportError as e:
            print(f"{name}: not installed ({e})")
    ref = codecs[ref_name]
    vals = values()
    want = [ref.dumps(v) for v in vals]
    for name, codec in codecs.items():
        got = [codec.dumps(v) for v in vals]
        dumps_bad = sum(g != w for g, w in zip(got, want))
        value_bad = sum(ref.loads(g) != ref.loads(w) for g, w in zip(got, want))  # different JSON, not just bytes
        loads_bad = [b for b in BODIES if repr(_load(codec, b)) != repr(_load(ref, b))]
        page = ArticlesResponse([_article(random.Random(i)) for i in range(20)], 500000)
        t_dump = min(timeit.repeat(lambda: codec.dumps(page), number=2000, repeat=5)) / 2000 * 1e6
        t_load = min(timeit.repeat(lambda: codec.loads(BODIES[0]), number=20000, repeat=5)) / 20000 * 1e6
        print(f"{name:9} dumps bytes differ {dumps_bad}/{len(vals)}, values differ {value_bad}"
              f"  loads mismatches {len(loads_bad)}/{len(BODIES)}"
              f"  | 20-article page dumps {t_dump:.2f} us, login body loads {t_load:.3f} us")
        for b in loads_bad:
            print(f"    loads {b[:40]!r}: {repr(_load(codec, b))[:60]} vs {ref_name} {repr(_load(ref, b))[:60]}")


if __name__ == "__main__":
    main()
