#!/usr/bin/env python3
"""Finite black-box feed/comments batching check; standard library + psql only.

Run two servers against one disposable DB (or equivalent disposable clones).
The candidate should use WORKERS=1 PG_READERS=3 READ_BATCH=32 READ_HOLD=1.
Default workload: 384 baseline singletons + 1,280 contended candidate requests.
This writes/cleans private fixtures. It is correctness evidence, not a benchmark.
"""
import argparse
import base64
import concurrent.futures
import contextlib
import hashlib
import hmac
import json
import os
from pathlib import Path
import select
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


T0 = "2026-10-23T00:00:00.000Z"
T1 = "2026-10-23T00:00:01.000Z"
T2 = "2026-10-23T00:00:02.000Z"
PUBLIC_HASH = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"
PROTECTED_DATABASES = {"postgres", "template0", "template1", "conduit_seed", "conduit_dev"}


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def digest(value):
    raw = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(raw).hexdigest()


class Database:
    def __init__(self, url, psql):
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in {"postgres", "postgresql"}:
            raise ValueError("database URL must use postgres:// or postgresql://")
        self.name = urllib.parse.unquote(parsed.path.lstrip("/"))
        if not self.name or self.name in PROTECTED_DATABASES:
            raise ValueError("requires disposable clones, never a seed or system database")
        self.env = os.environ.copy()
        for key in ["PGDATABASE", "PGHOST", "PGPORT", "PGUSER", "PGPASSWORD", "PGSERVICE"]:
            self.env.pop(key, None)
        self.env.update(PGDATABASE=self.name, PGPORT=str(parsed.port or 5432), PGCONNECT_TIMEOUT="5")
        if parsed.hostname:
            self.env["PGHOST"] = parsed.hostname
        if parsed.username:
            self.env["PGUSER"] = urllib.parse.unquote(parsed.username)
        if parsed.password is not None:
            self.env["PGPASSWORD"] = urllib.parse.unquote(parsed.password)
        options = dict(urllib.parse.parse_qsl(parsed.query))
        for key, env in [("sslmode", "PGSSLMODE"), ("sslrootcert", "PGSSLROOTCERT")]:
            if key in options:
                self.env[env] = options[key]
        unsupported = set(options) - {"sslmode", "sslrootcert"}
        if unsupported:
            raise ValueError("unsupported database URL options: " + ",".join(sorted(unsupported)))
        self.argv = [psql, "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1"]
        self.identity = json.loads(self.sql(
            "SELECT json_build_object('database',current_database(),'database_oid',"
            "(SELECT oid FROM pg_database WHERE datname=current_database()),"
            "'server_address',inet_server_addr(),'server_port',inet_server_port(),"
            "'postmaster_start',pg_postmaster_start_time())"))

    def sql(self, text, timeout=20):
        run = subprocess.run(self.argv, input=text, env=self.env, text=True,
                             capture_output=True, timeout=timeout)
        if run.returncode:
            raise RuntimeError("psql failed: " + run.stderr.strip())
        return run.stdout.strip()

    def batch_witness(self, family):
        pattern = ("%WITH ORDINALITY AS r(p1,p2,p3,p4,ord)%" if family == "feed" else
                   "%viewers AS MATERIALIZED%" if family == "comments" else
                   "%queries AS MATERIALIZED%")
        value = self.sql("SELECT COALESCE(json_agg(json_build_object('pid',pid,"
                         "'wait_event_type',wait_event_type,'query',query)), '[]'::json) "
                         "FROM pg_stat_activity WHERE datname=current_database() "
                         "AND pid<>pg_backend_pid() AND wait_event_type='Lock' "
                         "AND query LIKE " + quote(pattern))
        return json.loads(value)

    @contextlib.contextmanager
    def block_reads(self):
        proc = subprocess.Popen(self.argv, env=self.env, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, bufsize=1)
        try:
            proc.stdin.write("BEGIN; LOCK TABLE articles IN ACCESS EXCLUSIVE MODE; "
                             "SELECT 'READ_BATCH_LOCKED';\n")
            proc.stdin.flush()
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    raise RuntimeError("read-lock transaction exited: " + proc.stderr.read())
                if select.select([proc.stdout], [], [], .1)[0]:
                    if proc.stdout.readline().strip() == "READ_BATCH_LOCKED":
                        break
            else:
                raise TimeoutError("fixture read lock did not become ready")
            yield
        finally:
            with contextlib.suppress(Exception):
                proc.stdin.write("ROLLBACK;\n\\q\n")
                proc.stdin.flush()
                proc.stdin.close()
                proc.wait(timeout=5)
            if proc.poll() is None:
                proc.terminate()
                with contextlib.suppress(subprocess.TimeoutExpired):
                    proc.wait(timeout=3)
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=3)
            proc.stdout.close()
            proc.stderr.close()


class Fixture:
    def __init__(self):
        nonce = uuid.uuid4().hex
        self.nonce = "read_batch_" + nonce
        self.base = 5_000_000_000 + int(nonce[:10], 16) * 100_000
        self.users = [self.base + n + 1 for n in range(7)]
        self.usernames = {uid: self.nonce + "_" + chr(97 + n) for n, uid in enumerate(self.users)}
        self.article_ids = [self.base + 1000 + n for n in range(1100)]
        self.slugs = [self.nonce + ("-grün-🌱" if n == 0 else "-article-" + str(n)) for n in range(1100)]
        self.missing = [self.nonce + "-missing-first", self.nonce + "-不存在-missing-last"]
        self.tag_ids = [1_500_000_000 + int(nonce[10:17], 16) % 100_000_000 + n for n in range(3)]
        self.tags = [self.nonce + '-a "\\\n', self.nonce + "-é", self.nonce + "-空"]

    def follows(self, changed):
        a, b, c, d, e, _, g = self.users
        out = {(a, b), (b, a), (c, a), (c, b), (e, c), (g, a)}
        if changed:
            out.remove((c, b))
            out.add((d, a))
        return out

    def favorites(self, changed):
        a, b, c, d, *_ = self.users
        out = {(b, self.article_ids[1098]), (c, self.article_ids[0]), (a, self.article_ids[1099])}
        if changed:
            out.remove((b, self.article_ids[1098]))
            out.update({(c, self.article_ids[1098]), (d, self.article_ids[1098])})
        return out

    def comments(self, changed):
        out = []
        for n in range(108):
            out.append({"id": self.base + 10_000 + n, "article": 0,
                        "author": self.users[n % 7], "stamp": T0,
                        "body": 'Comment %d: Grüße 🌱 空 "quote" \\slash\nline\ttab' % n})
        for n, article in enumerate([1, 1, 1, 3, 3, 4]):
            out.append({"id": self.base + 10_200 + n, "article": article,
                        "author": self.users[(n + 2) % 7], "stamp": T0,
                        "body": 'Small comment %d: 世界 🌱\n"quoted"' % n})
        if changed:
            out = [comment for comment in out if comment["id"] != self.base + 10_107]
            out[0] = {**out[0], "body": 'COMMITTED oldest comment: 世界 🌱 "fresh"\n', "stamp": T1}
            out.append({"id": self.base + 11_000, "article": 2, "author": self.users[1],
                        "stamp": T2, "body": 'COMMITTED formerly-empty comment: 空 🌱\t'})
        return out

    def profile(self, uid, viewer, changed):
        n = self.users.index(uid)
        return {"username": self.usernames[uid],
                "bio": "COMMITTED bio 世界\n" if changed and n == 0 else (None if n % 2 else "Bio Grüße " + str(n)),
                "image": "https://example.test/updated-🌱.png" if changed and n == 0 else (None if n % 2 else "https://example.test/" + str(n)),
                "following": (viewer, uid) in self.follows(changed)}

    def install(self, db):
        previous_max = int(db.sql("SELECT COALESCE(max(id),0) FROM articles"))
        if previous_max >= self.article_ids[0]:
            raise ValueError("fixture IDs must sort above all existing articles")
        users = []
        for n, uid in enumerate(self.users):
            profile = self.profile(uid, 0, False)
            values = [str(uid), quote(self.usernames[uid]), quote(self.usernames[uid] + "@example.test"),
                      quote(PUBLIC_HASH), "NULL" if profile["bio"] is None else quote(profile["bio"]),
                      "NULL" if profile["image"] is None else quote(profile["image"]), quote(T0)]
            users.append("(" + ",".join(values) + ")")
        a, b, *_ = self.users
        text = ("BEGIN; INSERT INTO users(id,username,email,password_hash,bio,image,created_at) VALUES "
                + ",".join(users) + "; INSERT INTO articles(id,slug,author_id,title,description,body,created_at,updated_at) "
                + "SELECT " + str(self.base + 1000) + "+g, CASE WHEN g=0 THEN " + quote(self.slugs[0])
                + " ELSE " + quote(self.nonce + "-article-") + "||g END, CASE WHEN g%2=0 THEN " + str(a)
                + " ELSE " + str(b) + " END, " + quote("Article Grüße 🌱 ") + "||g, "
                + quote('Description 空 "quoted"') + "," + quote("Fixture body 🌱\nline\t")
                + "," + quote(T0) + "," + quote(T0) + " FROM generate_series(0,1099) g; ")
        text += "INSERT INTO tags(id,name) VALUES " + ",".join(
            "(" + str(uid) + "," + quote(name) + ")" for uid, name in zip(self.tag_ids, self.tags)) + "; "
        text += "INSERT INTO article_tags(article_id,tag_id) VALUES " + ",".join(
            "(" + str(self.article_ids[n]) + "," + str(tag) + ")" for n in [0, 1098, 1099] for tag in self.tag_ids) + "; "
        text += "INSERT INTO follows(follower_id,followee_id) VALUES " + ",".join(
            "(%d,%d)" % pair for pair in sorted(self.follows(False))) + "; "
        text += "INSERT INTO favorites(user_id,article_id) VALUES " + ",".join(
            "(%d,%d)" % pair for pair in sorted(self.favorites(False))) + "; "
        text += "INSERT INTO comments(id,article_id,author_id,body,created_at,updated_at) VALUES " + ",".join(
            "(" + ",".join([str(c["id"]), str(self.article_ids[c["article"]]), str(c["author"]),
                             quote(c["body"]), quote(c["stamp"]), quote(c["stamp"])]) + ")" for c in self.comments(False))
        db.sql(text + "; COMMIT;")

    def mutate(self, db):
        a, b, c, d, *_ = self.users
        aid = self.article_ids[1098]
        db.sql("BEGIN; DELETE FROM follows WHERE follower_id=%d AND followee_id=%d; " % (c, b)
               + "INSERT INTO follows(follower_id,followee_id) VALUES (%d,%d); " % (d, a)
               + "DELETE FROM favorites WHERE user_id=%d AND article_id=%d; " % (b, aid)
               + "INSERT INTO favorites(user_id,article_id) VALUES (%d,%d),(%d,%d); " % (c, aid, d, aid)
               + "UPDATE users SET bio=" + quote("COMMITTED bio 世界\n") + ",image="
               + quote("https://example.test/updated-🌱.png") + " WHERE id=%d; " % a
               + "UPDATE articles SET title=" + quote('COMMITTED title 世界 🌱 "fresh"') + ",updated_at="
               + quote(T1) + " WHERE id=%d; " % aid
               + "UPDATE comments SET body=" + quote('COMMITTED oldest comment: 世界 🌱 "fresh"\n')
               + ",created_at=" + quote(T1) + ",updated_at=" + quote(T1) + " WHERE id=%d; " % (self.base + 10_000)
               + "DELETE FROM comments WHERE id=%d; " % (self.base + 10_107)
               + "INSERT INTO comments(id,article_id,author_id,body,created_at,updated_at) VALUES ("
               + ",".join([str(self.base + 11_000), str(self.article_ids[2]), str(b),
                            quote('COMMITTED formerly-empty comment: 空 🌱\t'), quote(T2), quote(T2)]) + "); COMMIT;")

    def cleanup(self, db):
        db.sql("BEGIN; DELETE FROM users WHERE id IN (" + ",".join(map(str, self.users))
               + ") AND username LIKE " + quote(self.nonce + "%")
               + "; DELETE FROM tags WHERE id IN (" + ",".join(map(str, self.tag_ids))
               + ") AND name LIKE " + quote(self.nonce + "%") + "; COMMIT;")
        users = ",".join(map(str, self.users))
        remaining = json.loads(db.sql("SELECT json_build_object('users',(SELECT count(*) FROM users WHERE id IN ("
                                     + users + ")),'articles',(SELECT count(*) FROM articles WHERE author_id IN ("
                                     + users + ")),'comments',(SELECT count(*) FROM comments WHERE author_id IN ("
                                     + users + ")),'tags',(SELECT count(*) FROM tags WHERE id IN ("
                                     + ",".join(map(str, self.tag_ids))
                                     + ")),'follows',(SELECT count(*) FROM follows WHERE follower_id IN ("
                                     + users + ") OR followee_id IN (" + users
                                     + ")),'favorites',(SELECT count(*) FROM favorites WHERE user_id IN ("
                                     + users + ")),'article_tags',(SELECT count(*) FROM article_tags WHERE article_id BETWEEN "
                                     + str(self.article_ids[0]) + " AND " + str(self.article_ids[-1]) + "))"))
        assert all(value == 0 for value in remaining.values()), ("fixture cleanup incomplete", remaining)
        return remaining

    def cases(self):
        feed = []
        for limit in [1, 10, 100]:
            for offset in [0, 1, 10, 40, 2000]:
                for viewer in self.users[:4]:
                    feed.append({"viewer": viewer, "limit": limit, "offset": offset,
                                 "path": "/api/articles/feed?limit=%d&offset=%d" % (limit, offset)})
        for offset in [0, 1, 10, 40]:
            feed.append({"viewer": 0, "limit": 10, "offset": offset,
                         "path": "/api/articles/feed?limit=10&offset=" + str(offset)})
        comments = []
        slugs = [self.missing[0], self.slugs[0], self.slugs[2], self.slugs[1],
                 self.slugs[3], self.slugs[4], self.slugs[5], self.missing[1]]
        for slug in slugs:
            for viewer in [0, *self.users]:
                comments.append({"viewer": viewer, "slug": slug,
                                 "path": "/api/articles/" + urllib.parse.quote(slug, safe="") + "/comments"})
        families = {"feed": feed, "comments": comments}
        for family in ["global", "tag", "author", "favorited"]:
            rows = []
            first = {"tag": self.tags[1], "author": self.usernames[self.users[0]],
                     "favorited": self.usernames[self.users[1]]}.get(family)
            second = {"tag": self.tags[0], "author": self.usernames[self.users[1]],
                      "favorited": self.usernames[self.users[2]]}.get(family)
            for viewer in [0, *self.users]:
                rows.append({"viewer": viewer, "limit": 10, "offset": 0, "filter": first})
            for viewer in [0, *self.users[:3]]:
                rows.append({"viewer": viewer, "limit": 1, "offset": 1, "filter": second})
            rows += [{"viewer": self.users[0], "limit": 10, "offset": 10_000_000, "filter": first},
                     {"viewer": 0, "limit": 10, "offset": 0, "filter": self.nonce + "-missing-filter" if first else None},
                     {"viewer": self.users[1], "limit": 100, "offset": 40, "filter": first},
                     {"viewer": self.users[2], "limit": 5, "offset": 10, "filter": first}]
            for case in rows:
                query = {"limit": case["limit"], "offset": case["offset"]}
                if family != "global":
                    query[family] = case["filter"]
                case["path"] = "/api/articles?" + urllib.parse.urlencode(query)
            families[family] = rows
        for family, rows in families.items():
            assert len(rows) == (64 if family in {"feed", "comments"} else 16)
            for n, row in enumerate(rows):
                row.update(family=family, id=family + "-" + str(n))
        return families

    def oracle(self, case, response, changed):
        viewer, family = case["viewer"], case["family"]
        status = 401 if family == "feed" and viewer == 0 else 404 if case.get("slug") in self.missing else 200
        assert response["status"] == status, (case["id"], "status", response["status"], status)
        if status != 200:
            return
        if family == "comments":
            article = self.slugs.index(case["slug"])
            expected = sorted((c for c in self.comments(changed) if c["article"] == article),
                              key=lambda c: (c["stamp"], c["id"]), reverse=True)[:100]
            expected = [{"id": c["id"], "createdAt": c["stamp"], "updatedAt": c["stamp"],
                         "body": c["body"], "author": self.profile(c["author"], viewer, changed)} for c in expected]
            assert response["body"] == {"comments": expected}, (case["id"], "comment oracle")
        else:
            if family == "feed":
                eligible = [n for n in reversed(range(1100)) if (viewer, self.users[n % 2]) in self.follows(changed)]
            elif family == "global":
                # Fixture IDs are above the original seed, so all nonempty test
                # pages come from these1,100 articles; huge offsets are empty.
                eligible = list(reversed(range(1100)))
            elif family == "tag":
                eligible = [1099, 1098, 0] if case["filter"] in self.tags else []
            elif family == "author":
                eligible = [n for n in reversed(range(1100))
                            if self.usernames[self.users[n % 2]] == case["filter"]]
            else:
                eligible = [n for n in reversed(range(1100)) if any(
                    aid == self.article_ids[n] and self.usernames[uid] == case["filter"]
                    for uid, aid in self.favorites(changed))]
            obj = response["body"]
            assert obj["articlesCount"] == min(1000, len(eligible)), (case["id"], "list count")
            selected = eligible[case["offset"]:case["offset"] + case["limit"]]
            assert [row["slug"] for row in obj["articles"]] == [self.slugs[n] for n in selected], (case["id"], "list order")
            favorites = self.favorites(changed)
            for n, row in zip(selected, obj["articles"]):
                aid = self.article_ids[n]
                assert row["author"] == self.profile(self.users[n % 2], viewer, changed), (case["id"], "list author")
                assert row["favorited"] is ((viewer, aid) in favorites), (case["id"], "favorited")
                assert row["favoritesCount"] == sum(article == aid for _, article in favorites), (case["id"], "favorites count")
                assert row["title"] == ('COMMITTED title 世界 🌱 "fresh"' if changed and n == 1098 else "Article Grüße 🌱 " + str(n)), (case["id"], "title")
                assert set(row["tagList"]) == (set(self.tags) if n in {0, 1098, 1099} else set()), (case["id"], "tags")


def token(secret, uid):
    encode = lambda b: base64.urlsafe_b64encode(b).decode().rstrip("=")
    now = int(time.time())
    text = ".".join(encode(json.dumps(obj, separators=(",", ":")).encode()) for obj in
                    [{"alg": "HS256", "typ": "JWT"}, {"sub": str(uid), "iat": now, "exp": now + 3600}])
    return text + "." + encode(hmac.digest(secret.encode(), text.encode(), "sha256"))


def api(base, secret, case, timeout):
    headers = {"Connection": "close"}
    if case["viewer"]:
        headers["Authorization"] = "Token " + token(secret, case["viewer"])
    request = urllib.request.Request(base.rstrip("/") + case["path"], headers=headers)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=timeout) as reply:
            status, body = reply.status, reply.read()
    except urllib.error.HTTPError as reply:
        status, body = reply.code, reply.read()
    obj = json.loads(body)
    if status in {401, 404}:
        assert isinstance(obj.get("errors", {}).get("body"), list) and obj["errors"]["body"], "error shape"
        obj = {"errors": {"body_is_nonempty_list": True}}
    return {"status": status, "body": obj}


def concurrent_wave(args, db, fixture, cases, reference, changed, gated):
    barrier = threading.Barrier(len(cases) + 1)
    results, failures, witness = [], [], []
    family = cases[0]["family"]
    def request(case):
        barrier.wait(timeout=10)
        return api(args.candidate, args.secret, case, args.http_timeout)
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency)
    futures = []
    try:
        with db.block_reads() if gated else contextlib.nullcontext():
            futures = [(case, executor.submit(request, case)) for case in cases]
            barrier.wait(timeout=10)
            if gated:
                deadline = time.monotonic() + 6
                while time.monotonic() < deadline:
                    witness = db.batch_witness(family)
                    if witness:
                        break
                    time.sleep(.04)
        deadline = time.monotonic() + args.http_timeout + 5
        for case, future in futures:
            actual = None
            try:
                actual = future.result(timeout=max(.1, deadline - time.monotonic()))
                fixture.oracle(case, actual, changed)
                if actual != reference[case["id"]]:
                    raise AssertionError("candidate differs from baseline singleton")
                results.append({"case": case["id"], "response_sha256": digest(actual), "pass": True})
            except Exception as error:
                failure = {"case": case["id"], "error": type(error).__name__ + ": " + str(error),
                           "expected_response_sha256": digest(reference[case["id"]])}
                if actual is not None:
                    failure["actual_response_sha256"] = digest(actual)
                    if len(failures) < 4:
                        failure["actual_response"] = actual
                failures.append(failure)
        if gated and not witness:
            failures.append({"error": "actual " + family + " batch SQL was not witnessed while blocked"})
    finally:
        executor.shutdown(wait=True, cancel_futures=True)
    return {"requests": len(futures), "gated": gated, "batch_sql_witness": witness,
            "responses": results, "failures": failures, "pass": not failures and len(results) == len(cases)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, help="baseline server URL")
    parser.add_argument("--candidate", required=True, help="candidate server URL")
    parser.add_argument("--secret", default=os.environ.get("JWT_SECRET"))
    parser.add_argument("--database-url", default=os.environ.get("DATABASE_URL"), help="disposable baseline DB")
    parser.add_argument("--candidate-database-url", default=os.environ.get("CANDIDATE_DATABASE_URL"))
    parser.add_argument("--psql", default="psql")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--concurrency", type=int, default=64)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--http-timeout", type=float, default=25)
    parser.add_argument("--keep-fixture", action="store_true")
    args = parser.parse_args()
    if not args.secret or not args.database_url:
        parser.error("JWT_SECRET and disposable DATABASE_URL (or corresponding arguments) are required")
    if args.baseline.rstrip("/") == args.candidate.rstrip("/"):
        parser.error("baseline and candidate must be distinct server URLs")
    for url in [args.baseline, args.candidate]:
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password:
            parser.error("server URLs must be HTTP(S) URLs without credentials")
    if not 64 <= args.concurrency <= 256 or not 1 <= args.rounds <= 6 or not 10 <= args.http_timeout <= 60:
        parser.error("concurrency64..256, rounds1..6 and http-timeout10..60 are required")
    report = {"scope": "Finite black-box read-batch correctness; no capacity/performance claim",
              "test_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "baseline": args.baseline, "candidate": args.candidate, "pass": False,
              "rounds": args.rounds, "concurrency": args.concurrency, "phases": [], "failures": []}
    report["expected_http_requests_on_complete_pass"] = 896 + 256 * args.rounds
    fixture, installed = Fixture(), []
    try:
        baseline_db = Database(args.database_url, args.psql)
        candidate_db = Database(args.candidate_database_url or args.database_url, args.psql)
        databases = [baseline_db]
        if candidate_db.identity != baseline_db.identity:
            databases.append(candidate_db)
        report.update(databases=[db.identity for db in databases], same_database=len(databases) == 1,
                      fixture={"nonce": fixture.nonce, "users": fixture.users,
                               "base_id": fixture.base, "usernames": fixture.usernames,
                               "tag_ids": fixture.tag_ids, "tags": fixture.tags,
                               "article_count": 1100, "tied_comment_count": 108,
                               "slugs": fixture.slugs[:6], "missing": fixture.missing},
                      expected_candidate_config={"WORKERS": 1, "PG_READERS": 3, "READ_HOLD": 1, "READ_BATCH": 32})
        for db in databases:
            fixture.install(db)
            installed.append(db)
        cases = fixture.cases()
        report["cases"] = cases
        previous = None
        for changed in [False, True]:
            if changed:
                for db in databases:
                    fixture.mutate(db)
            reference = {}
            phase = {"state": "after_committed_mutations" if changed else "initial",
                     "baseline_requests": 0, "reference_responses": reference, "waves": []}
            report["phases"].append(phase)
            for case in [case for family in cases.values() for case in family]:
                actual = api(args.baseline, args.secret, case, args.http_timeout)
                reference[case["id"]] = actual
                phase["baseline_requests"] += 1
                fixture.oracle(case, actual, changed)
            if previous is not None:
                deltas = {family: sum(reference[case["id"]] != previous[case["id"]] for case in cases[family])
                          for family in cases}
                assert all(deltas.values()), "committed mutations must change every endpoint family"
                phase["baseline_responses_changed_since_commit"] = deltas
            for family in cases:
                rounds = args.rounds if family in {"feed", "comments"} else 1
                for round_number in range(rounds):
                    repeated = cases[family] * (64 // len(cases[family]))
                    offset = (round_number * 13) % len(repeated)
                    batch = repeated[offset:] + repeated[:offset]
                    wave = concurrent_wave(args, candidate_db, fixture, batch, reference, changed, round_number == 0)
                    wave.update(family=family, round=round_number + 1)
                    phase["waves"].append(wave)
                    if not wave["pass"]:
                        report["failures"].append({"state": phase["state"], "family": family,
                                                   "round": round_number + 1, "failures": wave["failures"]})
                        raise AssertionError("stopping after first failing candidate wave")
            previous = reference
        report["pass"] = not report["failures"]
    except Exception as error:
        report["failures"].append({"error": type(error).__name__ + ": " + str(error)})
    finally:
        cleanup_errors, cleanup_witnesses = [], []
        if not args.keep_fixture:
            for db in reversed(installed):
                try:
                    cleanup_witnesses.append({"database": db.name, "remaining_fixture_rows": fixture.cleanup(db)})
                except Exception as error:
                    cleanup_errors.append({"database": db.name, "error": type(error).__name__ + ": " + str(error)})
        report["fixture_cleanup"] = {"requested": not args.keep_fixture,
                                     "databases_installed": len(installed), "witnesses": cleanup_witnesses,
                                     "errors": cleanup_errors}
        if cleanup_errors:
            report["pass"] = False
        report["baseline_requests"] = sum(p["baseline_requests"] for p in report["phases"])
        report["candidate_requests"] = sum(w["requests"] for p in report["phases"] for w in p["waves"])
        report["http_requests"] = report["baseline_requests"] + report["candidate_requests"]
        report["verified_batch_waves"] = sum(bool(w["batch_sql_witness"])
                                              for p in report["phases"] for w in p["waves"])
        if report["pass"] and (report["http_requests"] != report["expected_http_requests_on_complete_pass"]
                               or report["verified_batch_waves"] != 12):
            report["pass"] = False
            report["failures"].append({"error": "incomplete request coverage or missing batch witnesses"})
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, indent=2, ensure_ascii=False, allow_nan=False) + "\n")
    print(json.dumps({"out": str(args.out), "pass": report["pass"],
                      "http_requests": report["http_requests"], "verified_batch_waves": report["verified_batch_waves"],
                      "failures": len(report["failures"]) + len(report["fixture_cleanup"]["errors"])}))
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
