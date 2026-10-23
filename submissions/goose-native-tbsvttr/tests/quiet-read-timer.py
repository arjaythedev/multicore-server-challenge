#!/usr/bin/env python3
"""Real HTTP timer/liveness probe; no server, compiler or Docker is started.

Use a dedicated disposable DB/server with no other HTTP traffic, WORKERS=1,
READ_BATCH=32, READ_HOLD=1, WRITE_BATCH_US=1000 and READ_BATCH_US=500000.
BASE, DATABASE_URL (or PROBE_DATABASE_URL), JWT_SECRET configure the probe.
--expected-us 0 also checks the disabled mode; stress writer/read independence
is asserted for windows >=200ms. Private users/follow are cleaned afterwards.
"""
import argparse
import base64
import concurrent.futures
import hashlib
import hmac
import http.client
import json
import os
from pathlib import Path
import subprocess
import threading
import time
import urllib.parse
import uuid


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def token(secret, uid):
    encode = lambda raw: base64.urlsafe_b64encode(raw).decode().rstrip("=")
    now = int(time.time())
    text = ".".join(encode(json.dumps(obj, separators=(",", ":")).encode()) for obj in
                    [{"alg": "HS256", "typ": "JWT"}, {"sub": str(uid), "iat": now, "exp": now + 600}])
    return text + "." + encode(hmac.digest(secret.encode(), text.encode(), "sha256"))


class Probe:
    def __init__(self, args):
        self.args = args
        self.base = urllib.parse.urlsplit(args.base)
        parsed = urllib.parse.urlsplit(args.database_url)
        if parsed.scheme not in {"postgres", "postgresql"}:
            raise ValueError("requires a postgres:// or postgresql:// disposable DB URL")
        self.database = urllib.parse.unquote(parsed.path.lstrip("/"))
        if not self.database or self.database in {"postgres", "template0", "template1", "conduit_seed", "conduit_dev"}:
            raise ValueError("requires a disposable clone, never a seed/system database")
        self.pg_env = os.environ.copy()
        for key in ["PGDATABASE", "PGHOST", "PGPORT", "PGUSER", "PGPASSWORD", "PGSERVICE"]:
            self.pg_env.pop(key, None)
        self.pg_env.update(PGDATABASE=self.database, PGPORT=str(parsed.port or 5432), PGCONNECT_TIMEOUT="5")
        for key, value in [("PGHOST", parsed.hostname),
                           ("PGUSER", urllib.parse.unquote(parsed.username or "")),
                           ("PGPASSWORD", urllib.parse.unquote(parsed.password or ""))]:
            if value:
                self.pg_env[key] = value
        options = dict(urllib.parse.parse_qsl(parsed.query))
        if set(options) - {"sslmode", "sslrootcert"}:
            raise ValueError("only sslmode/sslrootcert database URL options are supported")
        for key, env in [("sslmode", "PGSSLMODE"), ("sslrootcert", "PGSSLROOTCERT")]:
            if key in options:
                self.pg_env[env] = options[key]

    def sql(self, text):
        run = subprocess.run([self.args.psql, "-X", "-qAt", "-v", "ON_ERROR_STOP=1"],
                             input=text, env=self.pg_env, text=True, capture_output=True, timeout=15)
        if run.returncode:
            raise RuntimeError("fixture SQL failed: " + run.stderr.strip())
        return run.stdout.strip()

    def api(self, method, path, auth=None, sent=None):
        connection_type = http.client.HTTPSConnection if self.base.scheme == "https" else http.client.HTTPConnection
        connection = connection_type(self.base.hostname, self.base.port, timeout=4)
        headers = {"Connection": "close"}
        if auth:
            headers["Authorization"] = "Token " + auth
        try:
            connection.request(method, self.base.path.rstrip("/") + path, headers=headers)
            sent_at = time.monotonic()
            if sent is not None:
                sent["sent_s"] = sent_at
                sent["event"].set()
            response = connection.getresponse()
            headers_at = time.monotonic()
            body = response.read()
            return {"status": response.status, "body": json.loads(body), "sent_s": sent_at,
                    "headers_s": headers_at, "completed_s": time.monotonic()}
        finally:
            if sent is not None:
                sent["event"].set()
            connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default=os.environ.get("BASE") or os.environ.get("BASE_URL"))
    parser.add_argument("--database-url", default=os.environ.get("PROBE_DATABASE_URL") or os.environ.get("DATABASE_URL"))
    parser.add_argument("--secret", default=os.environ.get("JWT_SECRET"))
    parser.add_argument("--psql", default="psql")
    parser.add_argument("--expected-us", type=int, default=500000)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if not args.base or not args.database_url or not args.secret:
        parser.error("BASE, disposable DATABASE_URL and JWT_SECRET (or corresponding arguments) are required")
    if not 0 <= args.expected_us <= 1000000:
        parser.error("expected-us must be0..1000000")
    parsed = urllib.parse.urlsplit(args.base)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password or parsed.query:
        parser.error("base must be a credential-free HTTP(S) URL without a query")
    seconds = args.expected_us / 1e6
    lower, upper = max(0, seconds - .1), max(2, seconds * 4)
    nonce = "quiet_read_" + uuid.uuid4().hex
    names = [nonce + "_actor", nonce + "_target"]
    record = {"scope": "Correctness only: quiet read wake, reset and independent writer deadline",
              "test_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "base": args.base, "expected_read_batch_us": args.expected_us,
              "expected_writer_batch_us": 1000, "latency_bounds_s": [lower, upper],
              "stress_independence_applicable": seconds >= .2, "nonce": nonce,
              "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "pass": False, "failures": [], "cleanup": {}}
    probe, fixture = None, None
    try:
        probe = Probe(args)
        record["database"] = probe.database
        public_hash = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"
        fixture = json.loads(probe.sql("WITH u AS (INSERT INTO users(username,email,password_hash) VALUES "
                                      + ",".join("(" + ",".join([quote(n), quote(n + "@example.test"), quote(public_hash)]) + ")"
                                                 for n in names)
                                      + " RETURNING id,username) SELECT json_object_agg(username,id) FROM u;"))
        actor, target = fixture[names[0]], fixture[names[1]]
        record["fixture"] = {"actor_id": actor, "target_id": target, "actor_username": names[0], "target_username": names[1]}

        # No second HTTP request, DB query or polling occurs while this request
        # waits. Completion therefore requires the server's quiet timer wake.
        quiet = probe.api("GET", "/api/tags")
        record["quiet_read"] = quiet
        elapsed = quiet["headers_s"] - quiet["sent_s"]
        assert quiet["status"] == 200 and isinstance(quiet["body"].get("tags"), list), "quiet tags response"
        assert lower <= elapsed <= upper, ("quiet read timer bounds", elapsed, lower, upper)

        # A new otherwise-idle pool must start a fresh deadline, not inherit the
        # prior pool timestamp. The only additional HTTP traffic is the writer.
        sent = {"event": threading.Event()}
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(probe.api, "GET", "/api/tags", None, sent)
            assert sent["event"].wait(timeout=5) and "sent_s" in sent, "second read was not sent"
            pause = min(.1, seconds * .2) if seconds else .05
            time.sleep(pause)
            if seconds >= .2:
                assert not future.done(), "read completed before its declared stress window"
            write = probe.api("POST", "/api/profiles/" + urllib.parse.quote(names[1], safe="") + "/follow",
                              token(args.secret, actor))
            pending_at_write_response = not future.done()
            record["writer"] = {**write, "read_pending_at_writer_response": pending_at_write_response,
                                "started_after_read_sent_s": write["sent_s"] - sent["sent_s"],
                                "completed_after_read_sent_s": write["completed_s"] - sent["sent_s"]}
            assert write["status"] == 200 and write["body"]["profile"]["username"] == names[1], "follow response"
            assert write["body"]["profile"]["following"] is True, "follow flag"
            committed = probe.sql("SELECT EXISTS(SELECT 1 FROM follows WHERE follower_id=%d AND followee_id=%d);"
                                  % (actor, target)) == "t"
            record["writer"]["follow_visible_immediately_after_response"] = committed
            assert committed, "follow was not visible immediately after the response"
            if seconds >= .2:
                deadline = sent["sent_s"] + seconds * .8
                record["writer"]["latest_allowed_completion_s"] = deadline
                assert pending_at_write_response and write["completed_s"] < deadline, "writer waited for read deadline"
            second = future.result(timeout=5)
        record["second_read"] = second
        elapsed = second["headers_s"] - second["sent_s"]
        assert second["status"] == 200 and second["body"] == quiet["body"], "second tags response"
        assert lower <= elapsed <= upper, ("fresh read deadline bounds", elapsed, lower, upper)
        if seconds >= .2:
            assert write["completed_s"] < second["headers_s"], "writer did not complete before pending read"
        record["pass"] = True
    except Exception as error:
        record["failures"].append({"error": type(error).__name__ + ": " + str(error)})
    finally:
        if probe is not None and fixture is not None:
            try:
                probe.sql("DELETE FROM users WHERE username IN (" + ",".join(map(quote, names)) + ");")
                remaining = json.loads(probe.sql("SELECT json_build_object('users',(SELECT count(*) FROM users WHERE username IN ("
                                                + ",".join(map(quote, names)) + ")),'follows',(SELECT count(*) FROM follows WHERE "
                                                + "follower_id=%d OR followee_id=%d));" % (fixture[names[0]], fixture[names[1]])))
                record["cleanup"] = {"remaining_private_rows": remaining}
                assert all(n == 0 for n in remaining.values()), "fixture cleanup incomplete"
            except Exception as error:
                record["cleanup"]["error"] = type(error).__name__ + ": " + str(error)
                record["pass"] = False
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(record, indent=2, ensure_ascii=False, allow_nan=False) + "\n")
    print(json.dumps({"out": str(args.out), "pass": record["pass"],
                      "stress_independence_applicable": record["stress_independence_applicable"],
                      "failures": len(record["failures"]) + int("error" in record["cleanup"])}))
    return 0 if record["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
