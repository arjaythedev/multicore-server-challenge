#!/usr/bin/env python3
"""Terminate the app role's backends in its disposable DB and verify recovery.

Usage: DATABASE_URL=postgres://conduit:conduit@.../test_db python3 tests/reconnect.py PORT
Never run this against a production database: all same-role backends in that DB,
including a reference test server, are deliberately terminated. Requires psql.
"""
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import http.client
import json
import os
import subprocess
import sys
import time
import urllib.parse


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def main():
    port = int(sys.argv[1])
    url = os.environ["DATABASE_URL"]

    def psql(sql):
        result = subprocess.run(["psql", "-w", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "--dbname", url, "-c", sql],
                                capture_output=True, text=True, timeout=10, check=True)
        return result.stdout.strip()

    username = psql("SELECT username FROM users WHERE id=1")
    require(bool(username), "seed user 1 is missing")
    path = "/api/profiles/" + urllib.parse.quote(username, safe="")

    def read():
        client = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        try:
            client.request("GET", path)
            response = client.getresponse()
            data = json.loads(response.read())
            if response.status == 200:
                require(data["profile"]["username"] == username, "reconnected lookup returned another user")
            else:
                require(response.status == 503 and isinstance(data["errors"]["body"], list),
                        "outage returned %d, expected 200 or 503: %r" % (response.status, data))
            return response.status
        finally:
            client.close()

    require(read() == 200, "server was not healthy before backend termination")
    killed = psql("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname=current_database() AND usename=current_user AND pid<>pg_backend_pid()")
    require("t" in killed.splitlines(), "no application backend was terminated")

    def during_outage(_):
        results = Counter()
        for _ in range(60):
            try:
                results[read()] += 1
            except OSError:
                results["transport"] += 1
            time.sleep(.025)
        return results

    with ThreadPoolExecutor(max_workers=8) as pool:
        counts = sum(pool.map(during_outage, range(8)), Counter())
    require(counts["transport"] == 0, "transport failures during backend outage: %r" % dict(counts))
    require(sum(counts.values()) == 480, "not every outage probe completed")
    deadline = time.monotonic() + 30
    while read() != 200:
        require(time.monotonic() < deadline, "server did not recover within 30 seconds")
        time.sleep(.05)
    for _ in range(50):
        require(read() == 200, "server regressed after recovery")
    print("PASS backend termination: %d connections; 480 in-flight/outage probes %s; 50 successful post-recovery lookups" %
          (len(killed.splitlines()), dict(counts)), flush=True)


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt) as exc:
        print("FAIL: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
        sys.exit(1)
