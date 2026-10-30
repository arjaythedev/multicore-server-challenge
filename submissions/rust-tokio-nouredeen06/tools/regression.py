#!/usr/bin/env python3
"""Exercise cohort isolation, committed visibility, rollback, and HTTP framing.

Run against a disposable database: users and tags remain after this test.
No third-party Python packages, direct database access, or seeded fixtures needed.
Example: python3 tools/regression.py --base http://127.0.0.1:3111
For deterministic cohort coverage, start the server with DB_CONNS=1,
DB_WRITE_CONNS=1, READ_BATCH_US=3000, WRITE_BATCH_US=3000, and BATCH_TRACE=1.
Repeat against normal production settings as well.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import copy
import http.client
import json
import socket
import threading
import time
from urllib.parse import urlencode, urlsplit
import uuid


class Suite:
    def __init__(self, base, concurrency):
        self.url = urlsplit(base)
        if self.url.scheme != "http" or self.url.path not in ("", "/"):
            raise ValueError("--base must be an http://host:port origin")
        self.host = self.url.hostname
        self.port = self.url.port or 80
        self.concurrency = concurrency
        self.prefix = "reg" + uuid.uuid4().hex[:12]
        self.users = {}
        self.articles = []
        self.follows = set()
        self.favorites = set()
        self.checks = 0

    def request(self, method, path, viewer=None, body=None, status=200):
        headers = {}
        if viewer is not None:
            headers["Authorization"] = "Token " + self.users[viewer]["token"]
        if body is not None:
            headers["Content-Type"] = "application/json"
            body = json.dumps(body, ensure_ascii=False).encode()
        conn = http.client.HTTPConnection(self.host, self.port, timeout=20)
        try:
            conn.request(method, path, body=body, headers=headers)
            response = conn.getresponse()
            raw = response.read()
            assert response.status == status, (method, path, response.status, status, raw[:300])
            if status == 204:
                assert raw == b"", (path, raw)
                return None
            assert response.getheader("Content-Type", "").startswith("application/json")
            result = json.loads(raw)
            if status >= 400:
                assert isinstance(result["errors"]["body"], list) and result["errors"]["body"]
            return result
        finally:
            conn.close()

    def burst(self, jobs):
        """Start each wave together, ensuring independent sockets/viewer identities."""
        results = []
        for start in range(0, len(jobs), self.concurrency):
            wave = jobs[start:start + self.concurrency]
            barrier = threading.Barrier(len(wave))

            def run(job):
                barrier.wait(timeout=20)
                return job()

            with ThreadPoolExecutor(max_workers=len(wave)) as pool:
                results.extend(pool.map(run, wave))
        return results

    def check(self, got, expected, label):
        assert got == expected, (label, got, expected)
        self.checks += 1

    def create_article(self, author, title, tags):
        article = self.request("POST", "/api/articles", author, {"article": {
            "title": title, "description": "Regression description <>&\"", "body": "Body\n雪 é 🦀",
            "tagList": tags,
        }}, 201)["article"]
        self.check(article["tagList"], sorted(set(tags)), "created tags")
        self.check(article["favoritesCount"], 0, "created favorites count")
        self.articles.append(article)
        return article

    def setup(self):
        self.initial_count = self.request("GET", "/api/articles?limit=1")["articlesCount"]
        for role in ("author", "other", "both", "follow", "fav", "plain"):
            name = self.prefix + "_" + role
            self.users[role] = self.request("POST", "/api/users", body={"user": {
                "username": name, "email": name + "@regression.invalid", "password": "real-password-123",
            }}, status=201)["user"]
        self.tags = [self.prefix + "_a", self.prefix + "_b"]
        for i in range(8):
            self.create_article("author" if i < 5 else "other", self.prefix + " article " + str(i),
                                [self.tags[0]] if i % 2 else self.tags)
        self.main = self.articles[-1]
        for viewer, author in (("both", "author"), ("follow", "author"), ("fav", "other"),
                               ("both", "other"), ("both", "plain")):
            self.request("POST", "/api/profiles/" + self.users[author]["username"] + "/follow", viewer)
            self.follows.add((viewer, author))
        for i, article in enumerate(self.articles):
            for viewer in (("both", "fav") if i % 2 else ("follow",)):
                self.request("POST", "/api/articles/" + article["slug"] + "/favorite", viewer)
                self.favorites.add((viewer, article["slug"]))

    def expected_article(self, article, viewer, full=False):
        expected = copy.deepcopy(article)
        slug = article["slug"]
        author = next(role for role, user in self.users.items()
                      if user["username"] == article["author"]["username"])
        expected["author"] = {key: self.users[author][key] for key in ("username", "bio", "image")}
        expected["author"]["following"] = (viewer, author) in self.follows
        expected["favorited"] = (viewer, slug) in self.favorites
        expected["favoritesCount"] = sum(s == slug for _, s in self.favorites)
        if not full:
            del expected["body"]
        return expected

    def list_case(self, viewer, filter_name, filter_role, limit, offset):
        selected = sorted(self.articles, key=lambda a: int(a["slug"].rsplit("-", 1)[1]), reverse=True)
        params = {"limit": limit, "offset": offset}
        path = "/api/articles"
        if filter_name == "tag":
            value = self.tags[filter_role] if isinstance(filter_role, int) else self.prefix + "_missing"
            params["tag"] = value
            selected = [a for a in selected if value in a["tagList"]]
        elif filter_name == "author":
            value = self.users[filter_role]["username"] if filter_role in self.users else self.prefix + "_missing"
            params["author"] = value
            selected = [a for a in selected if a["author"]["username"] == value]
        elif filter_name == "favorited":
            value = self.users[filter_role]["username"] if filter_role in self.users else self.prefix + "_missing"
            params["favorited"] = value
            selected = [a for a in selected if (filter_role, a["slug"]) in self.favorites]
        elif filter_name == "feed":
            path += "/feed"
            followed = {self.users[a]["username"] for v, a in self.follows if v == viewer}
            selected = [a for a in selected if a["author"]["username"] in followed]
        count = len(selected) if filter_name else min(1000, self.initial_count + len(self.articles))
        expected = {"articles": [self.expected_article(a, viewer) for a in selected[offset:offset + limit]],
                    "articlesCount": count}
        target = path + "?" + urlencode(params)

        def job():
            self.check(self.request("GET", target, viewer), expected, (viewer, target))

        return job

    def cohorts(self):
        viewers = (None, "both", "follow", "fav", "plain", "author")
        # Each cohort mixes pagination/filter keys, including repeated keys, anonymous
        # readers, real empty pages, and absent filters. References come from our fixture
        # model rather than another execution of the SQL under test.
        for family, filters in ((None, [None]), ("tag", [0, 1, "missing"]),
                                ("author", ["author", "other", "missing"]),
                                ("favorited", ["both", "follow", "fav", "plain", "missing"]),
                                ("feed", [None])):
            jobs = []
            for page in ((1, 0), (2, 1), (1, 3), (5, 100)):
                if family is None and page[1] == 100:
                    continue  # Older seeded articles are outside our fixture model.
                for value in filters:
                    for viewer in viewers:
                        if family == "feed" and viewer is None:
                            continue
                        jobs.append(self.list_case(viewer, family, value, *page))
            self.burst(jobs * 2)
        jobs = []
        for article in self.articles[:8]:
            for viewer in viewers:
                expected = self.expected_article(article, viewer, full=True)
                jobs.append(lambda a=article, v=viewer, e=expected: self.check(
                    self.request("GET", "/api/articles/" + a["slug"], v)["article"], e, "article viewer"))
        self.burst(jobs * 2)
        print("PASS independent viewers, duplicate/filter/page keys, empty pages and counts", flush=True)

    def freshness(self):
        slug = self.main["slug"]
        self.request("DELETE", "/api/articles/" + slug + "/favorite", "both")
        self.favorites.remove(("both", slug))
        self.request("POST", "/api/articles/" + slug + "/favorite", "plain")
        self.favorites.add(("plain", slug))
        self.request("DELETE", "/api/profiles/" + self.users["other"]["username"] + "/follow", "both")
        self.follows.remove(("both", "other"))
        self.users["other"] = self.request("PUT", "/api/user", "other", {"user": {
            "bio": "Fresh bio \" & 雪", "image": "https://example.invalid/new.png",
        }})["user"]
        self.cohorts()

        # Every successful create must include newly inserted tags, including when
        # competing transactions insert the same previously unknown tag.
        new_tag = self.prefix + "_concurrent"
        jobs = [lambda i=i: self.create_article("author", self.prefix + " concurrent " + str(i),
                                                [new_tag, self.tags[0], new_tag]) for i in range(16)]
        created = self.burst(jobs)
        listed = self.request("GET", "/api/articles?" + urlencode({"tag": new_tag, "limit": 100}))
        self.check(listed["articlesCount"], 16, "committed concurrent tag count")
        self.check({a["slug"] for a in listed["articles"]}, {a["slug"] for a in created}, "committed tag members")
        self.check(new_tag in self.request("GET", "/api/tags")["tags"], True, "fresh tag visible")

        comment_path = "/api/articles/" + slug + "/comments"
        comments = self.burst([lambda i=i: self.request("POST", comment_path, "plain",
            {"comment": {"body": "comment " + str(i) + " 雪 \""}}, 201)["comment"] for i in range(24)])
        expected_ids = {c["id"] for c in comments}
        def check_comments(viewer):
            listed = self.request("GET", comment_path, viewer)["comments"]
            self.check({c["id"] for c in listed}, expected_ids, "fresh committed comments")
            for c in listed:
                self.check(c["author"]["following"], (viewer, "plain") in self.follows, "comment viewer isolation")
        secondary_path = "/api/articles/" + self.articles[0]["slug"] + "/comments"
        secondary = self.request("POST", secondary_path, "author", {"comment": {"body": "other thread"}}, 201)["comment"]
        empty_path = "/api/articles/" + self.articles[1]["slug"] + "/comments"
        missing_path = "/api/articles/" + self.prefix + "-missing/comments"
        def check_secondary(viewer):
            expected = copy.deepcopy(secondary)
            expected["author"]["following"] = (viewer, "author") in self.follows
            self.check(self.request("GET", secondary_path, viewer), {"comments": [expected]}, "separate comment thread")
        jobs = []
        for _ in range(4):
            for viewer in (None, "both", "follow", "plain"):
                jobs.extend([
                    lambda v=viewer: check_comments(v),
                    lambda v=viewer: check_secondary(v),
                    lambda v=viewer: self.check(self.request("GET", empty_path, v), {"comments": []}, "empty thread"),
                    lambda v=viewer: self.request("GET", missing_path, v, status=404),
                ])
        self.burst(jobs)
        for c in comments[:3]:
            self.request("DELETE", comment_path + "/" + str(c["id"]), "plain", status=204)
            expected_ids.remove(c["id"])
        check_comments("both")
        print("PASS committed favorites, follows, profiles, tags and comments become visible immediately", flush=True)

    def rollback(self):
        slug = self.main["slug"]
        comment_path = "/api/articles/" + slug + "/comments"
        for wave in range(4):
            before = self.request("GET", "/api/user", "plain")["user"]
            jobs = []
            valid = set()
            for i in range(24):
                if i % 3 == 0:
                    # A real database UNIQUE failure (not request validation). The
                    # simultaneously changed bio must also roll back.
                    jobs.append(lambda: self.request("PUT", "/api/user", "plain", {"user": {
                        "username": self.users["author"]["username"], "bio": "must roll back",
                    }}, 422))
                else:
                    body = self.prefix + " rollback " + str(wave) + " " + str(i)
                    valid.add(body)
                    jobs.append(lambda b=body: self.request("POST", comment_path, "plain",
                                                           {"comment": {"body": b}}, 201))
            self.burst(jobs)
            self.check(self.request("GET", "/api/user", "plain")["user"], before, "failed mutation rolled back")
            bodies = [c["body"] for c in self.request("GET", comment_path)["comments"]]
            self.check({b for b in bodies if b in valid}, valid, "successful neighbors committed")
            for body in valid:
                self.check(bodies.count(body), 1, "successful neighbor committed once")
        self.check(len(self.request("GET", comment_path)["comments"]), 85, "no phantom comment writes")
        older = self.request("GET", comment_path)["comments"]
        newest = self.burst([lambda i=i: self.request("POST", comment_path, "plain",
            {"comment": {"body": "cap regression " + str(i)}}, 201)["comment"] for i in range(32)])
        capped = self.request("GET", comment_path)["comments"]
        self.check(len(capped), 100, "comment cap")
        self.check({c["id"] for c in capped}, {c["id"] for c in newest + older[:68]}, "newest 100 comments")
        self.check([c["id"] for c in capped[32:]], [c["id"] for c in older[:68]], "comment order preserved")
        def capped_thread(viewer):
            comments = self.request("GET", comment_path, viewer)["comments"]
            self.check([c["id"] for c in comments], [c["id"] for c in capped], "batched newest 100")
            self.check([c["author"]["following"] for c in comments],
                       [(viewer, "plain") in self.follows] * 100, "batched capped viewer flags")
        self.burst([lambda v=v: capped_thread(v)
                    for v in (None, "both", "follow", "plain") for _ in range(12)])
        print("PASS failed grouped mutations roll back; successful neighbors commit exactly once", flush=True)

    def raw(self):
        return socket.create_connection((self.host, self.port), timeout=5)

    def wire(self, method, path, headers=(), body=b""):
        head = [method + " " + path + " HTTP/1.1", "Host: regression.invalid"]
        head.extend(headers)
        return ("\r\n".join(head) + "\r\n\r\n").encode() + body

    @staticmethod
    def response(reader, method="GET"):
        status_line = reader.readline()
        assert status_line.startswith(b"HTTP/1.1 "), status_line
        status = int(status_line.split()[1])
        headers = {}
        while True:
            line = reader.readline()
            if line == b"\r\n":
                break
            assert line, "EOF inside response headers"
            name, value = line.split(b":", 1)
            headers[name.strip().lower()] = value.strip()
        length = int(headers.get(b"content-length", b"0"))
        body = b"" if status in (100, 204, 304) or method == "HEAD" else reader.read(length)
        assert status in (100, 204, 304) or method == "HEAD" or len(body) == length
        return status, headers, body

    def framing(self):
        tag_request = self.wire("GET", "/api/tags")
        with self.raw() as sock, sock.makefile("rb") as reader:
            sock.sendall(tag_request * 3)
            for _ in range(3):
                status, _, raw = self.response(reader)
                self.check(status, 200, "pipeline status")
                assert self.tags[0] in json.loads(raw)["tags"]
            # The same live socket must accept another request after the pipeline.
            sock.sendall(tag_request)
            self.check(self.response(reader)[0], 200, "pipeline reuse")

        path = "/api/articles/" + self.main["slug"] + "/comments"
        auth = "Authorization: Token " + self.users["plain"]["token"]
        data = json.dumps({"comment": {"body": "chunked 雪 " + "x" * 16000}}, ensure_ascii=False).encode()
        chunked = b"".join(b"%x;key=value\r\n" % len(data[i:i + 7]) + data[i:i + 7] + b"\r\n"
                           for i in range(0, len(data), 7)) + b"0\r\nX-Regression: trailer\r\n\r\n"
        wire = self.wire("POST", path, [auth, "Transfer-Encoding: chunked", "Content-Type: application/json"], chunked)
        with self.raw() as sock, sock.makefile("rb") as reader:
            for i in range(0, len(wire), 997):
                sock.sendall(wire[i:i + 997])
            sock.sendall(tag_request)
            status, _, raw = self.response(reader)
            self.check(status, 201, "fragmented chunked request")
            comment = json.loads(raw)["comment"]
            self.check(comment["body"], json.loads(data)["comment"]["body"], "decoded chunk body")
            self.check(self.response(reader)[0], 200, "request after chunk trailers")
            delete = self.wire("DELETE", path + "/" + str(comment["id"]), [auth, "Content-Length: 0"])
            sock.sendall(delete + tag_request)
            self.check(self.response(reader)[0], 204, "empty delete response")
            self.check(self.response(reader)[0], 200, "pipeline after 204")

        data = json.dumps({"user": {"bio": "expect body"}}).encode()
        with self.raw() as sock, sock.makefile("rb") as reader:
            sock.sendall(self.wire("PUT", "/api/user", [auth, "Expect: 100-continue",
                         "Content-Length: " + str(len(data)), "Content-Type: application/json"]))
            self.check(self.response(reader)[0], 100, "continue before body")
            sock.sendall(data + tag_request)
            self.check(self.response(reader)[0], 200, "continued request")
            self.check(self.response(reader)[0], 200, "pipeline after continued request")

        bad_headers = [
            ["Content-Length: 0", "Content-Length: 7"],
            ["Content-Length: 0", "Transfer-Encoding: chunked"],
            ["Transfer-Encoding: gzip, chunked"],
            ["Content-Length: +1"],
            ["Content-Length: 999999999999999999999"],
            [auth, auth],
        ]
        for headers in bad_headers:
            with self.raw() as sock:
                sock.sendall(self.wire("POST", "/api/users", headers) + tag_request)
                try:
                    raw = sock.recv(4096)
                except ConnectionResetError:
                    raw = b""
                # Invalid framing may be rejected by closing or a 4xx response;
                # a pipelined payload must never get interpreted as a valid request.
                assert raw == b"" or raw.startswith(b"HTTP/1.1 4"), (headers, raw)
                self.checks += 1
        with self.raw() as sock, sock.makefile("rb") as reader:
            sock.sendall(self.wire("GET", "/api/tags", ["Connection: close"]))
            self.check(self.response(reader)[0], 200, "explicit close response")
            self.check(reader.read(1), b"", "explicit close honored")
        print("PASS HTTP pipelines, chunking, trailers, fragmentation, 100-continue and ambiguous framing", flush=True)

    def run(self):
        self.setup()
        self.cohorts()
        self.freshness()
        self.rollback()
        self.framing()
        print(f"PASS {self.checks} regression assertions; fixture prefix {self.prefix}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="http://127.0.0.1:3111")
    parser.add_argument("--concurrency", type=int, default=48)
    args = parser.parse_args()
    if not 2 <= args.concurrency <= 128:
        parser.error("--concurrency must be 2–128")
    start = time.monotonic()
    Suite(args.base, args.concurrency).run()
    print(f"Elapsed: {time.monotonic() - start:.2f}s")


if __name__ == "__main__":
    main()
