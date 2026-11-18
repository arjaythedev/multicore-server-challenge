#!/usr/bin/env python3
"""Compare simultaneous feed batches with the same requests served individually."""
import base64
import concurrent.futures
import hashlib
import hmac
import json
import os
import threading
import time
import urllib.request

BASE = os.environ.get("BASE", "http://127.0.0.1:3000")
SECRET = os.environ.get("JWT_SECRET", "multicore-server-challenge").encode()


def token(viewer):
    def encode(value):
        return base64.urlsafe_b64encode(value).rstrip(b"=")
    now = int(time.time())
    header = encode(b'{"alg":"HS256","typ":"JWT"}')
    payload = encode(json.dumps({"sub": str(viewer), "iat": now, "exp": now + 3600}).encode())
    message = header + b"." + payload
    return (message + b"." + encode(hmac.digest(SECRET, message, hashlib.sha256))).decode()


def get_feed(case):
    viewer, limit, offset = case
    req = urllib.request.Request(
        f"{BASE}/api/articles/feed?limit={limit}&offset={offset}",
        headers={"Authorization": "Token " + token(viewer)},
    )
    with urllib.request.urlopen(req, timeout=60) as response:
        return json.load(response)


def main():
    missing = 9_000_000_000
    cases = [(viewer, limit, offset)
             for viewer in (*range(1, 21), missing)
             for limit, offset in ((10, 0), (5, 10), (100, 1000000))]
    expected = {case: get_feed(case) for case in cases}
    for case, feed in expected.items():
        assert 0 <= feed["articlesCount"] <= 1000
        assert all(article["author"]["following"] for article in feed["articles"])
        if case[0] == missing:
            assert feed["articles"] == [] and feed["articlesCount"] == 0

    # Duplicate viewers and page requests in each simultaneous read round.
    cases *= 2
    for _ in range(2):
        barrier = threading.Barrier(len(cases))
        def check(case):
            barrier.wait(timeout=60)
            assert get_feed(case) == expected[case], (case, "batched feed differs")
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(cases)) as pool:
            list(pool.map(check, cases))
    print("batched feeds match individual reads, including missing viewers and deep offsets")


if __name__ == "__main__":
    main()
