#!/usr/bin/env python3
"""Compare batched reads (many requests in one read round) with the same requests served one at a time.

A lone request runs the single statement; simultaneous ones of a kind share one batch statement whose rows are
rebuilt per request. Every list kind, the feed and comments are covered, with anonymous, duplicate and missing
viewers, unknown names and slugs, and empty and deep pages.
"""
import base64
import concurrent.futures
import hashlib
import hmac
import json
import os
import random
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("BASE", "http://127.0.0.1:3000")
SECRET = os.environ.get("JWT_SECRET", "multicore-server-challenge").encode()
ROUNDS = int(os.environ.get("ROUNDS", "3"))


def token(viewer):
    def encode(value):
        return base64.urlsafe_b64encode(value).rstrip(b"=")
    now = int(time.time())
    header = encode(b'{"alg":"HS256","typ":"JWT"}')
    payload = encode(json.dumps({"sub": str(viewer), "iat": now, "exp": now + 3600}).encode())
    message = header + b"." + payload
    return (message + b"." + encode(hmac.digest(SECRET, message, hashlib.sha256))).decode()


def get(case):
    viewer, path = case
    headers = {"Authorization": "Token " + token(viewer)} if viewer else {}
    req = urllib.request.Request(BASE + path, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main():
    rnd = random.Random(int(os.environ.get("SEED", "1")))
    status, first = get((0, "/api/articles?limit=100&offset=0"))
    assert status == 200
    articles = first["articles"]
    slugs = [a["slug"] for a in articles[:40]] + ["no-such-slug-" + str(i) for i in range(3)]
    authors = sorted({a["author"]["username"] for a in articles}) + ["no-such-user"]
    _, tags = get((0, "/api/tags"))
    tag_names = tags["tags"][:20] + ["no-such-tag"]
    viewers = [0, 9_000_000_000] + rnd.sample(range(1, 100_001), 40)
    pages = [(10, 0), (10, 10), (5, 40), (20, 0), (1, 999), (100, 1_000_000)]
    paths = []
    for limit, offset in pages:
        paths.append(f"/api/articles?limit={limit}&offset={offset}")
        paths.append(f"/api/articles/feed?limit={limit}&offset={offset}")
    for name in tag_names:
        limit, offset = rnd.choice(pages)
        paths.append(f"/api/articles?tag={urllib.parse.quote(name)}&limit={limit}&offset={offset}")
    for name in authors:
        paths.append(f"/api/articles?author={urllib.parse.quote(name)}&limit=5")
        paths.append(f"/api/articles?favorited={urllib.parse.quote(name)}&limit=5")
    for slug in slugs:
        paths.append(f"/api/articles/{slug}/comments")
    cases = []
    for path in paths:
        for viewer in rnd.sample(viewers, 4):
            if viewer or "/feed" not in path:
                cases.append((viewer, path))
    expected = {case: get(case) for case in cases}
    kinds = {}
    for (viewer, path), (status, _) in expected.items():
        kind = path.split("?")[0].rsplit("/", 1)[-1] + ("?" + path.split("?")[1].split("=")[0] if "?" in path else "")
        kinds[kind] = kinds.get(kind, 0) + 1
    print("cases", len(cases), kinds)

    work = cases * 2
    for r in range(ROUNDS):
        rnd.shuffle(work)
        barrier = threading.Barrier(len(work))
        failures = []

        def check(case):
            barrier.wait(timeout=120)
            got = get(case)
            if got != expected[case]:
                failures.append((case, got, expected[case]))
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(work)) as pool:
            list(pool.map(check, work))
        if failures:
            case, got, want = failures[0]
            raise SystemExit(f"round {r}: {len(failures)} batched responses differ; first {case}:\n got  {json.dumps(got)[:1500]}\n want {json.dumps(want)[:1500]}")
    print(f"{len(work)} simultaneous reads x {ROUNDS} rounds match individual reads")


if __name__ == "__main__":
    main()
