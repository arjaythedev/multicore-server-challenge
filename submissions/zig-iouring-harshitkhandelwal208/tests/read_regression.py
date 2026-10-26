#!/usr/bin/env python3
"""Fixture-backed read regressions against an already running server.

Usage: python3 tests/read_regression.py PORT [--latency-ms MAX_MS]
DATABASE_URL, or normal libpq PG* settings, must select the server's database.
JWT_SECRET defaults to multicore-server-challenge. Requires psql and SELECT,
INSERT, DELETE on users/articles/comments/follows/favorites/tags/article_tags,
plus USAGE on their identity sequences; no superuser/monitoring privileges.

Each burst releases 64 preconnected keep-alive clients together. A fixed-window
server can accumulate >=16 reads; dispatch spread and sends before the first
response are reported as client-side evidence, not server queue instrumentation.
Latency limits are opt-in, exclude connect/warm-up and JSON validation, and apply
to the maximum request latency in two additional synchronized bursts.

Run without competing writers to these fixtures. Only private, uniquely named
rows are inserted; cleanup uses FK cascades and leaves externally referenced
tags intact (reporting cleanup failure). Identity sequences are not reset.
"""

import argparse
import base64
import concurrent.futures
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import http.client
import json
import math
import os
import random
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid


CLIENTS = 64
HTTP_TIMEOUT = 10
MAX_BODY = 2 * 1024 * 1024
BASE_TIME = datetime(2025, 1, 1, tzinfo=timezone.utc)


class Failure(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise Failure(message)


def literal(value):
    return "NULL" if value is None else "'" + value.replace("'", "''") + "'"


def values(rows):
    return ",\n".join("(" + ", ".join(row) + ")" for row in rows)


def timestamp(seconds):
    return (BASE_TIME + timedelta(seconds=seconds, milliseconds=123)).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def psql(sql):
    command = ["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1"]
    if os.environ.get("DATABASE_URL"):
        command += ["--dbname", os.environ["DATABASE_URL"]]
    try:
        result = subprocess.run(
            command,
            input="SET standard_conforming_strings=on; SET statement_timeout='30s';\n" + sql,
            text=True, capture_output=True, timeout=40,
        )
    except OSError as exc:
        raise Failure("cannot run psql: %s" % exc) from exc
    except subprocess.TimeoutExpired as exc:
        raise Failure("psql exceeded 40 seconds; check database connectivity/locks") from exc
    require(result.returncode == 0, "psql failed: " + result.stderr.strip())
    return result.stdout


def identical(actual, expected, path="body"):
    require(type(actual) is type(expected), "%s: type %s, expected %s" % (path, type(actual).__name__, type(expected).__name__))
    if isinstance(expected, dict):
        require(actual.keys() == expected.keys(), "%s: keys %r, expected %r" % (path, sorted(actual), sorted(expected)))
        for key in expected:
            identical(actual[key], expected[key], path + "." + key)
    elif isinstance(expected, list):
        require(len(actual) == len(expected), "%s: %d entries, expected %d" % (path, len(actual), len(expected)))
        for index, (a, b) in enumerate(zip(actual, expected)):
            identical(a, b, "%s[%d]" % (path, index))
    else:
        require(actual == expected, "%s: %r, expected %r" % (path, actual, expected))


def token(uid, secret):
    def b64(data):
        return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")
    now = int(time.time())
    header = b64(b'{"alg":"HS256","typ":"JWT"}')
    payload = b64(json.dumps({"sub": str(uid), "iat": now, "exp": now + 3600}, separators=(",", ":")).encode())
    signed = header + "." + payload
    return signed + "." + b64(hmac.new(secret.encode(), signed.encode(), hashlib.sha256).digest())


@dataclass(frozen=True)
class Case:
    label: str
    path: str
    viewer: object
    expected: object
    status: int = 200


class Fixtures:
    def __init__(self):
        self.prefix = "rr-" + uuid.uuid4().hex + "-"
        self.committed = False
        self.ids: dict[str, dict[str, int]] = {"users": {}, "articles": {}, "comments": {}}

        def keys(kind):
            lengths = [64] * 18 + [127, 128, 129, 48, 80, 160]
            edge = (self.prefix + kind + "-edge-").ljust(127, "x")
            result = []
            for index, length in enumerate(lengths):
                key = edge + ("", "x", "xy")[index - 18] if 18 <= index <= 20 else (self.prefix + kind + "-%02d-" % index).ljust(length, "x")
                require(len(key.encode("ascii")) == length, "incorrect fixture key length")
                result.append(key)
            return result

        self.authors = keys("u")
        self.slugs = keys("a")
        self.viewers = (self.prefix + "viewer-a", self.prefix + "viewer-b")
        self.users = {}
        # Passwords are unusable: these read-only HTTP cases authenticate with minted JWTs.
        self.marker = "!read-regression-" + self.prefix
        for index, name in enumerate(self.authors + list(self.viewers)):
            self.users[name] = {
                "username": name, "email": self.prefix + "%d@example.invalid" % index,
                "bio": 'bio %d: "quoted" \\ \n✓' % index if index % 2 == 0 else None,
                "image": "https://example.invalid/" + self.prefix + str(index) if index % 3 else None,
            }
        edge = (self.prefix + "tag-edge-").ljust(127, "x")
        self.tags = [edge, edge + "x", edge + "xy"]
        self.articles = {}
        self.comments = {}
        self.follows = {(self.viewers[0], name) for i, name in enumerate(self.authors) if i % 2 == 0}
        self.follows |= {(self.viewers[1], name) for i, name in enumerate(self.authors) if i % 3 == 0}
        self.favorites = set()
        for index, slug in enumerate(self.slugs):
            tags = [self.tags[index % 3]]
            if index % 4 == 0:
                tags.append(self.tags[(index + 1) % 3])
            self.articles[slug] = {
                "author": self.authors[index % 2 if index < 6 else index],
                "title": self.prefix + 'title-%d: "quoted" ✓' % index,
                "description": "description-%d" % index,
                "body": "body-%d\nsecond line \\ ✓" % index,
                "tags": sorted(tags), "createdAt": timestamp(index), "updatedAt": timestamp(index + 1),
            }
            self.comments[slug] = []
            if index % 3:
                for number in range(3):
                    self.comments[slug].append({
                        "body": self.prefix + 'comment-%d-%d: "quoted"\n✓' % (index, number),
                        "author": self.authors[(index + number + 1) % len(self.authors)],
                        "createdAt": timestamp(1000 + index * 10 + min(number, 1)),
                        "updatedAt": timestamp(1005 + index * 10 + min(number, 1)),
                    })
            if index % 2 == 0:
                self.favorites.add((self.viewers[0], slug))
            if index % 3 == 1:
                self.favorites.add((self.viewers[1], slug))
            if index % 4 == 0:
                self.favorites.add((self.authors[0], slug))
        self.missing_articles = [self.slugs[i][:-1] + "m" for i in (0, 1, 18, 19, 20, 21, 22, 23)]
        self.missing_users = [self.authors[i][:-1] + "m" for i in (0, 1, 18, 19, 20, 21, 22, 23)]
        self.missing_tags = [name[:-1] + "m" for name in self.tags]

    def create(self):
        uid = lambda name: "(SELECT id FROM users WHERE username=%s)" % literal(name)
        aid = lambda slug: "(SELECT id FROM articles WHERE slug=%s)" % literal(slug)
        tid = lambda tag: "(SELECT id FROM tags WHERE name=%s)" % literal(tag)
        names = ", ".join(map(literal, self.users))
        slugs = ", ".join(map(literal, self.slugs))
        sql = ["BEGIN;"]
        sql.append("INSERT INTO users (username,email,password_hash,bio,image) VALUES " + values(
            (literal(u["username"]), literal(u["email"]), literal(self.marker), literal(u["bio"]), literal(u["image"])) for u in self.users.values()) + ";")
        sql.append("INSERT INTO articles (slug,author_id,title,description,body,created_at,updated_at) VALUES " + values(
            (literal(slug), uid(a["author"]), literal(a["title"]), literal(a["description"]), literal(a["body"]), literal(a["createdAt"]), literal(a["updatedAt"])) for slug, a in self.articles.items()) + ";")
        sql.append("INSERT INTO tags (name) VALUES " + values((literal(tag),) for tag in self.tags) + ";")
        sql.append("INSERT INTO article_tags (article_id,tag_id) VALUES " + values(
            (aid(slug), tid(tag)) for slug, a in self.articles.items() for tag in a["tags"]) + ";")
        sql.append("INSERT INTO comments (article_id,author_id,body,created_at,updated_at) VALUES " + values(
            (aid(slug), uid(c["author"]), literal(c["body"]), literal(c["createdAt"]), literal(c["updatedAt"])) for slug, comments in self.comments.items() for c in comments) + ";")
        sql.append("INSERT INTO follows (follower_id,followee_id) VALUES " + values(
            (uid(a), uid(b)) for a, b in sorted(self.follows)) + ";")
        sql.append("INSERT INTO favorites (user_id,article_id) VALUES " + values(
            (uid(name), aid(slug)) for name, slug in sorted(self.favorites)) + ";")
        sql.append("""SELECT json_build_object(
            'users', (SELECT json_object_agg(username,id) FROM users WHERE username IN (%s)),
            'articles', (SELECT json_object_agg(slug,id) FROM articles WHERE slug IN (%s)),
            'comments', (SELECT json_object_agg(c.body,c.id) FROM comments c JOIN articles a ON a.id=c.article_id WHERE a.slug IN (%s)),
            'missing', (SELECT count(*) FROM users WHERE username IN (%s))
                     + (SELECT count(*) FROM articles WHERE slug IN (%s))
                     + (SELECT count(*) FROM tags WHERE name IN (%s))
        );""" % (names, slugs, slugs, ", ".join(map(literal, self.missing_users)), ", ".join(map(literal, self.missing_articles)), ", ".join(map(literal, self.missing_tags))))
        sql.append("COMMIT;")
        output = psql("\n".join(sql))
        self.committed = True
        self.ids = json.loads(output)
        expected = {
            "users": set(self.users), "articles": set(self.slugs),
            "comments": {c["body"] for comments in self.comments.values() for c in comments},
        }
        for kind, keys in expected.items():
            require(isinstance(self.ids[kind], dict) and set(self.ids[kind]) == keys, "incomplete SQL fixture manifest: " + kind)
            ids = list(self.ids[kind].values())
            require(all(type(i) is int and i > 0 for i in ids) and len(ids) == len(set(ids)), "invalid fixture ids: " + kind)
        require(self.ids["missing"] == 0, "a supposedly missing fixture key exists")

    def cleanup(self):
        names = ", ".join(map(literal, self.users))
        owned = "username IN (%s) AND password_hash=%s AND email IN (%s)" % (names, literal(self.marker), ", ".join(literal(u["email"]) for u in self.users.values()))
        # Probe the marker even after a failed/timeout setup: COMMIT might have reached PG.
        present = int(psql("SELECT count(*) FROM users WHERE " + owned + ";").strip())
        if not present and not self.committed:
            return
        tags = ", ".join(map(literal, self.tags))
        output = psql("""BEGIN;
            DELETE FROM users WHERE %s;
            DELETE FROM tags t WHERE t.name IN (%s)
                AND NOT EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id=t.id);
            SELECT json_build_object(
                'users', (SELECT count(*) FROM users WHERE %s),
                'tags', (SELECT count(*) FROM tags WHERE name IN (%s)));
            COMMIT;""" % (owned, tags, owned, tags))
        remaining = json.loads(output)
        require(remaining == {"users": 0, "tags": 0}, "cleanup incomplete (referenced tags are deliberately preserved): %r" % remaining)
        print("cleanup: private users/articles/comments/relationships/tags removed")

    def profile(self, name, viewer):
        user = self.users[name]
        return {"username": name, "bio": user["bio"], "image": user["image"], "following": (viewer, name) in self.follows}

    def article(self, slug, viewer, full=True):
        article = self.articles[slug]
        result = {key: article[key] for key in ("title", "description", "createdAt", "updatedAt")}
        result.update(slug=slug, tagList=article["tags"], author=self.profile(article["author"], viewer),
                      favorited=(viewer, slug) in self.favorites, favoritesCount=sum(s == slug for _, s in self.favorites))
        if full:
            result["body"] = article["body"]
        return result

    def point(self, kind, key, viewer):
        path = "/api/profiles/" if kind == "profile" else "/api/articles/"
        path += urllib.parse.quote(key, safe="")
        expected = None
        if kind == "profile" and key in self.users:
            expected = {"profile": self.profile(key, viewer)}
        elif kind == "article" and key in self.articles:
            expected = {"article": self.article(key, viewer)}
        elif kind == "comments":
            path += "/comments"
            if key in self.comments:
                comments = sorted(self.comments[key], key=lambda c: (c["createdAt"], self.ids["comments"][c["body"]]), reverse=True)
                expected = {"comments": [dict(id=self.ids["comments"][c["body"]], body=c["body"], createdAt=c["createdAt"], updatedAt=c["updatedAt"], author=self.profile(c["author"], viewer)) for c in comments]}
        return Case("%s key-bytes=%d" % (kind, len(key.encode())), path, viewer, expected, 404 if expected is None else 200)

    def filtered(self, kind, key, viewer, limit=2, offset=0):
        slugs = [slug for slug, a in self.articles.items() if
                 (kind == "author" and a["author"] == key) or
                 (kind == "tag" and key in a["tags"]) or
                 (kind == "favorited" and (key, slug) in self.favorites)]
        slugs.sort(key=lambda slug: self.ids["articles"][slug], reverse=True)
        expected = {"articles": [self.article(slug, viewer, full=False) for slug in slugs[offset:offset + limit]], "articlesCount": len(slugs)}
        path = "/api/articles?" + urllib.parse.urlencode({kind: key, "limit": limit, "offset": offset})
        return Case("list-%s limit=%d offset=%d" % (kind, limit, offset), path, viewer, expected)

    def workload(self):
        phases, mixed = [], []
        observers = (None,) + self.viewers
        for index, viewer in enumerate(observers):
            for kind, keys in (("article", self.slugs + self.missing_articles),
                               ("comments", self.slugs + self.missing_articles),
                               ("profile", list(self.users) + self.missing_users)):
                cases = [self.point(kind, key, viewer) for key in keys]
                phases.append(("distinct-%s-viewer%d" % (kind, index), cases))
                mixed.extend(cases)
            cases = [self.filtered("author", name, viewer) for name in self.authors]
            for tag in self.tags:
                cases.extend(self.filtered("tag", tag, viewer, limit, offset) for limit, offset in ((1, 0), (3, 1), (10, 0), (5, 1000)))
            for name in self.viewers:
                cases.extend(self.filtered("favorited", name, viewer, limit, offset) for limit, offset in ((2, 0), (3, 1), (5, 1000)))
            cases.extend(self.filtered(kind, key, viewer) for kind, key in (("author", self.missing_users[0]), ("tag", self.missing_tags[0]), ("favorited", self.missing_users[1])))
            cases.extend(self.filtered("author", self.authors[0], viewer, 1, offset) for offset in (1, 1000))
            phases.append(("filtered-viewer%d" % index, cases))
            mixed.extend(cases)
        for kind, key, label in (("article", self.slugs[18], "article"), ("comments", self.slugs[18], "empty-comments"),
                                 ("comments", self.slugs[19], "nonempty-comments"), ("profile", self.authors[20], "profile")):
            phases.append(("duplicate-" + label, [self.point(kind, key, observers[i % 3]) for i in range(CLIENTS)]))
        random.Random(45).shuffle(mixed)
        for start in range(0, len(mixed), CLIENTS):
            phases.append(("mixed-%d" % (start // CLIENTS), mixed[start:start + CLIENTS]))
        return phases, mixed


class Runner:
    def __init__(self, port, tokens):
        self.clients = [http.client.HTTPConnection("127.0.0.1", port, timeout=HTTP_TIMEOUT) for _ in range(CLIENTS)]
        self.tokens = tokens
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=CLIENTS)
        self.gate = None
        self.count = 0

    def connect(self):
        for client in self.clients:
            client.connect()
            client.auto_open = 0  # An unexpected close must fail, not silently reconnect.

    def request(self, client, case, gate):
        gate.wait(timeout=HTTP_TIMEOUT)
        require(client.sock is not None, "client is no longer preconnected")
        headers = {"Accept": "application/json", "Connection": "keep-alive"}
        if case.viewer is not None:
            headers["Authorization"] = "Token " + self.tokens[case.viewer]
        start = time.perf_counter_ns()
        client.request("GET", case.path, headers=headers)
        sent = time.perf_counter_ns()
        response = client.getresponse()
        received = time.perf_counter_ns()
        raw = response.read(MAX_BODY + 1)
        finished = time.perf_counter_ns()
        require(len(raw) <= MAX_BODY, "response exceeds fixture body limit")
        length = response.getheader("Content-Length")
        if length is not None:
            require(int(length) == len(raw), "incomplete or invalid Content-Length response")
        require(not response.will_close, "server did not preserve the keep-alive connection")
        require(response.status == case.status, "HTTP %d, expected %d; body=%r" % (response.status, case.status, raw[:300]))
        require(response.getheader("Content-Type", "").split(";", 1)[0].strip().lower() == "application/json", "non-JSON content type")
        body = json.loads(raw)
        if case.status == 404:
            require(isinstance(body, dict) and isinstance(body.get("errors"), dict) and body["errors"], "404 lacks a nonempty errors object")
        else:
            identical(body, case.expected)
        return start, sent, received, finished

    def burst(self, label, cases, latency_ms=None):
        require(1 <= len(cases) <= CLIENTS, "a burst must contain 1..%d cases; larger inputs would be truncated" % CLIENTS)
        cases = [cases[i % len(cases)] for i in range(CLIENTS)]
        self.gate = threading.Barrier(CLIENTS + 1)
        futures = [self.pool.submit(self.request, client, case, self.gate) for client, case in zip(self.clients, cases)]
        try:
            self.gate.wait(timeout=HTTP_TIMEOUT)
        except threading.BrokenBarrierError:
            self.gate.abort()
        results, errors = [], []
        for case, future in zip(cases, futures):
            try:
                results.append(future.result())
            except Exception as exc:
                errors.append("%s %s viewer=%r: %s: %s" % (case.label, case.path, case.viewer, type(exc).__name__, exc))
        self.gate = None
        require(len(results) + len(errors) == CLIENTS, "lost burst completions")
        require(not errors and len(results) == CLIENTS, "%s: %d/%d successful responses\n%s" % (label, len(results), CLIENTS, "\n".join(errors)))
        self.count += len(results)
        latencies = sorted((finished - start) / 1e6 for start, _, _, finished in results)
        dispatch = (max(r[1] for r in results) - min(r[1] for r in results)) / 1e6
        first_response = min(r[2] for r in results)
        before = sum(r[1] <= first_response for r in results)
        verdict = "PASS" if latency_ms is None or latencies[-1] < latency_ms else "FAIL"
        print("%s %s: %d/%d; p95=%.2fms max=%.2fms send-spread=%.2fms sent-before-first-response=%d" %
              (verdict, label, len(results), CLIENTS, latencies[math.ceil(.95 * len(latencies)) - 1], latencies[-1], dispatch, before))
        if latency_ms is not None:
            require(latencies[-1] < latency_ms, "%s: max %.2fms is not below %.2fms" % (label, latencies[-1], latency_ms))

    def close(self):
        if self.gate is not None:
            self.gate.abort()
        for client in self.clients:
            if client.sock is not None:
                try:
                    client.sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            client.close()
        self.pool.shutdown(wait=True, cancel_futures=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("port", type=int)
    parser.add_argument("--latency-ms", type=float, help="opt-in maximum latency for two extra warmed 64-client bursts")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("port must be in 1..65535")
    if args.latency_ms is not None and (not math.isfinite(args.latency_ms) or args.latency_ms <= 0):
        parser.error("--latency-ms must be finite and positive")
    fixtures = Fixtures()
    runner = None
    status = 0
    print("fixture prefix:", fixtures.prefix, flush=True)
    try:
        fixtures.create()
        secret = os.environ.get("JWT_SECRET", "multicore-server-challenge")
        tokens = {name: token(fixtures.ids["users"][name], secret) for name in fixtures.viewers}
        runner = Runner(args.port, tokens)
        runner.connect()
        runner.burst("warmup", [fixtures.point("profile", fixtures.authors[0], None)])
        phases, mixed = fixtures.workload()
        for label, cases in phases:
            runner.burst(label, cases)
        if args.latency_ms is not None:
            runner.burst("latency-mixed", mixed[:CLIENTS], args.latency_ms)
            observers = (None,) + fixtures.viewers
            runner.burst("latency-duplicates", [fixtures.point("article", fixtures.slugs[18], observers[i % 3]) for i in range(CLIENTS)], args.latency_ms)
        print("PASS: %d fixture-backed responses checked" % runner.count)
    except (Exception, KeyboardInterrupt) as exc:
        print("FAIL: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
        status = 1
    finally:
        try:
            if runner is not None:
                runner.close()
        except (Exception, KeyboardInterrupt) as exc:
            print("FAIL client cleanup: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
            status = 1
        try:
            fixtures.cleanup()
        except (Exception, KeyboardInterrupt) as exc:
            print("FAIL cleanup for %s: %s: %s" % (fixtures.prefix, type(exc).__name__, exc), file=sys.stderr)
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
