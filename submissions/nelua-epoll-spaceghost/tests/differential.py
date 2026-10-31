#!/usr/bin/env python3
"""Concurrent read parity against an unmodified reference server.

Start both servers against the same immutable seed database, then set BASE_URL,
REFERENCE_URL, DATABASE_URL, and JWT_SECRET. This test never changes database
rows. Each thread retains one HTTP connection to each server so requests can
share a live batch while carrying different independently signed viewers.
"""

import argparse
import base64
import concurrent.futures
from dataclasses import dataclass
import hashlib
import hmac
import http.client
import json
import os
import random
import subprocess
import sys
import threading
import time
from urllib.parse import quote, urlencode, urlsplit


METADATA_SQL = r"""
BEGIN READ ONLY;
SET LOCAL statement_timeout='30s';
SELECT json_build_object(
  'articles',coalesce((SELECT json_agg(x) FROM (
    SELECT slug FROM public.articles ORDER BY id DESC LIMIT 64
  ) x),'[]'::json),
  'users',coalesce((SELECT json_agg(x) FROM (
    SELECT id,username FROM public.users ORDER BY id LIMIT 64
  ) x),'[]'::json),
  'tags',coalesce((SELECT json_agg(x) FROM (
    SELECT name FROM public.tags ORDER BY name LIMIT 64
  ) x),'[]'::json),
  'favorites',coalesce((SELECT json_agg(x) FROM (
    SELECT f.user_id,a.slug,
      (SELECT u.id FROM public.users u
        WHERE NOT EXISTS(SELECT 1 FROM public.favorites f2
          WHERE f2.user_id=u.id AND f2.article_id=f.article_id)
        ORDER BY u.id LIMIT 1) AS other_id
      FROM public.favorites f JOIN public.articles a ON a.id=f.article_id
      ORDER BY f.user_id,f.article_id LIMIT 32
  ) x),'[]'::json),
  'follows',coalesce((SELECT json_agg(x) FROM (
    SELECT f.follower_id,u.username,
      (SELECT other.id FROM public.users other
        WHERE NOT EXISTS(SELECT 1 FROM public.follows f2
          WHERE f2.follower_id=other.id AND f2.followee_id=f.followee_id)
        ORDER BY other.id LIMIT 1) AS other_id
      FROM public.follows f JOIN public.users u ON u.id=f.followee_id
      ORDER BY f.follower_id,f.followee_id LIMIT 32
  ) x),'[]'::json)
);
COMMIT;
"""


@dataclass(frozen=True)
class Case:
    family: str
    path: str
    viewer: int
    # Optional semantic probe from an actual database edge: (object,field,value).
    flag: tuple | None = None


@dataclass(frozen=True)
class Endpoint:
    scheme: str
    host: str
    port: int
    prefix: str


THREAD = threading.local()


def endpoint(value):
    parsed = urlsplit(value)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ValueError("server URLs must have an http(s) scheme and host")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("server URLs must not contain credentials")
    if parsed.query or parsed.fragment:
        raise ValueError("server URLs must not contain a query or fragment")
    return Endpoint(parsed.scheme, parsed.hostname,
                    parsed.port or (443 if parsed.scheme == "https" else 80),
                    parsed.path.rstrip("/"))


def metadata(database_url, psql):
    proc = subprocess.run(
        [psql,"-X","-q","-A","-t","-v","ON_ERROR_STOP=1","-d",database_url],
        input=METADATA_SQL,text=True,encoding="utf-8",capture_output=True,
        env={**os.environ,"PGCLIENTENCODING":"UTF8"},timeout=35,
    )
    if proc.returncode:
        # Do not print argv: DATABASE_URL can contain a password.
        raise RuntimeError("read-only metadata query failed: " + proc.stderr[:1000])
    # PostgreSQL json_agg(record) may insert whitespace/newlines between records.
    value = json.loads(proc.stdout)
    if not value["articles"] or not value["users"] or not value["tags"]:
        raise RuntimeError("metadata needs a populated Conduit seed database")
    if not value["favorites"] or not value["follows"]:
        raise RuntimeError("metadata needs real favorite and follow edges")
    return value


def path_segment(value):
    return quote(value,safe="")


def make_cases(meta, count, seed):
    rng = random.Random(seed)
    slugs = [a["slug"] for a in meta["articles"]]
    names = [u["username"] for u in meta["users"]]
    ids = [int(u["id"]) for u in meta["users"]]
    tags = [t["name"] for t in meta["tags"]]
    followers = [int(f["follower_id"]) for f in meta["follows"]]
    missing = "__nelua_differential_missing_7f865be29c__"
    if missing in names or missing in slugs or missing in tags:
        raise RuntimeError("reserved missing-resource test key exists in seed")

    def random_case(index):
        family = index % 9
        viewer = rng.choice(ids + followers + [0,0])
        slug = rng.choice(slugs)
        name = rng.choice(names)
        # Include long offsets without making a large fraction of concurrent
        # requests force expensive full-index walks on the shared test host.
        offset = 100000000 if index % 83 == 0 else rng.choice([0,0,0,1,10,20,50,80])
        limit = rng.choice([1,5,10,20,50,100])
        params = {"limit":limit,"offset":offset}
        if family == 0:
            return Case("tags","/api/tags",viewer)
        if family == 1:
            return Case("article","/api/articles/" + path_segment(missing if index % 41 == 0 else slug),viewer)
        if family == 2:
            return Case("profile","/api/profiles/" + path_segment(missing if index % 43 == 0 else name),viewer)
        if family == 3:
            return Case("comments","/api/articles/" + path_segment(missing if index % 47 == 0 else slug) + "/comments",viewer)
        if family == 4:
            return Case("global","/api/articles?" + urlencode(params),viewer)
        if family == 5:
            params["tag"] = missing if index % 37 == 0 else rng.choice(tags)
            if index % 11 == 0:
                # Validates tag precedence even when lower-priority filters
                # would select a different or empty article set.
                params.update(author=missing,favorited=missing)
            return Case("tag","/api/articles?" + urlencode(params),viewer)
        if family == 6:
            params["author"] = missing if index % 31 == 0 else name
            if index % 13 == 0:
                params["favorited"] = missing
            return Case("author","/api/articles?" + urlencode(params),viewer)
        if family == 7:
            params["favorited"] = missing if index % 29 == 0 else name
            return Case("favorited","/api/articles?" + urlencode(params),viewer)
        return Case("feed","/api/articles/feed?" + urlencode(params),rng.choice(followers + ids))

    groups = []
    # A true and a known-false viewer ask for the same key next to each other.
    # Batch rows must stay paired to request ordinal instead of leaking flags.
    for edge in meta["favorites"]:
        slug = "/api/articles/" + path_segment(edge["slug"])
        other = int(edge["other_id"] or 0)
        groups.append([
            Case("article-edge",slug,int(edge["user_id"]),("article","favorited",True)),
            Case("article-edge",slug,other,("article","favorited",False)),
        ])
    for edge in meta["follows"]:
        profile = "/api/profiles/" + path_segment(edge["username"])
        other = int(edge["other_id"] or 0)
        groups.append([
            Case("profile-edge",profile,int(edge["follower_id"]),("profile","following",True)),
            Case("profile-edge",profile,other,("profile","following",False)),
        ])
    # At least one ordinary case from each route family even for a short run.
    ordinary = [random_case(i) for i in range(max(9,count - 2*len(groups)))]
    groups.extend([[case] for case in ordinary])
    rng.shuffle(groups)
    cases = [case for group in groups for case in group]
    while len(cases) < count:
        cases.append(random_case(len(cases)))
    return cases[:count]


def b64url(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=")


def token(viewer, secret):
    now = int(time.time())
    header = b64url(b'{"alg":"HS256","typ":"JWT"}')
    payload = b64url(json.dumps({"sub":str(viewer),"iat":now,"exp":now+3600},
                               separators=(",",":")).encode("ascii"))
    body = header + b"." + payload
    return (body + b"." + b64url(hmac.new(secret,body,hashlib.sha256).digest())).decode("ascii")


def connection(which, server, timeout):
    connections = getattr(THREAD,"connections",None)
    if connections is None:
        connections = THREAD.connections = {}
    if which not in connections:
        cls = http.client.HTTPSConnection if server.scheme == "https" else http.client.HTTPConnection
        connections[which] = cls(server.host,server.port,timeout=timeout)
    return connections[which]


def fetch(which, server, case, auth, timeout):
    conn = connection(which,server,timeout)
    headers = {"Accept":"application/json","Connection":"keep-alive"}
    if auth:
        headers["Authorization"] = "Token " + auth
    conn.request("GET",server.prefix+case.path,headers=headers)
    response = conn.getresponse()
    raw = response.read()
    content_type = response.getheader("Content-Type","").split(";",1)[0].strip().lower()
    if content_type != "application/json":
        raise AssertionError(f"{which}: status {response.status}, Content-Type {content_type!r}")
    try:
        payload = json.loads(raw)
    except (ValueError,UnicodeError) as exc:
        raise AssertionError(f"{which}: status {response.status}, invalid JSON: {str(exc)[:150]}") from exc
    if response.status >= 500:
        raise AssertionError(f"{which}: unexpected server error {response.status}")
    if response.status >= 400:
        errors = payload.get("errors") if isinstance(payload,dict) else None
        body = errors.get("body") if isinstance(errors,dict) else None
        if not isinstance(body,list) or not body or not all(isinstance(s,str) for s in body):
            raise AssertionError(f"{which}: invalid errors.body shape")
        payload = {"errors":{"body":["<message>"]}}
    return response.status,payload


def canonical(value):
    # JSON string comparison distinguishes bool from int and int from float;
    # Python's ordinary nested equality would accept True == 1 == 1.0.
    return json.dumps(value,sort_keys=True,ensure_ascii=False,separators=(",",":"))


def compare(index, case, servers, secret, timeout):
    auth = token(case.viewer,secret) if case.viewer else None
    try:
        actual = fetch("candidate",servers[0],case,auth,timeout)
        expected = fetch("reference",servers[1],case,auth,timeout)
        if actual[0] != expected[0] or canonical(actual[1]) != canonical(expected[1]):
            raise AssertionError(
                "candidate=" + canonical(actual)[:2000] +
                "\nreference=" + canonical(expected)[:2000])
        if case.flag:
            obj,field,wanted = case.flag
            found = actual[1].get(obj,{}).get(field) if actual[0] == 200 else None
            if type(found) is not bool or found is not wanted:
                raise AssertionError(f"seed edge expected {obj}.{field}={wanted}, got {found!r}")
        return index,case.family,None
    except (AssertionError,OSError,http.client.HTTPException) as exc:
        # Deliberately exclude Authorization/token values from diagnostics.
        return index,case.family,(f"case {index}, family={case.family}, viewer={case.viewer}, "
                                  f"GET {case.path}\n{type(exc).__name__}: {exc}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--requests",type=int,default=1000)
    parser.add_argument("--workers",type=int,default=64)
    parser.add_argument("--seed",type=int,default=2309)
    parser.add_argument("--timeout",type=float,default=30)
    parser.add_argument("--base",default=os.environ.get("BASE_URL","http://127.0.0.1:3000"))
    parser.add_argument("--reference",default=os.environ.get("REFERENCE_URL","http://127.0.0.1:3001"))
    args = parser.parse_args()
    if args.requests < 1 or args.workers < 1 or args.timeout <= 0:
        parser.error("requests, workers, and timeout must be positive")
    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        parser.error("DATABASE_URL must name the same immutable seed used by both servers")
    servers = (endpoint(args.base),endpoint(args.reference))
    if servers[0] == servers[1]:
        parser.error("candidate and reference must be different server endpoints")
    meta = metadata(database_url,os.environ.get("PSQL","psql"))
    cases = make_cases(meta,args.requests,args.seed)
    secret = os.environ.get("JWT_SECRET","multicore-server-challenge").encode("utf-8")
    families = {}
    failures = []
    started = time.monotonic()
    print(f"Read-only differential: {len(cases)} paired requests, {args.workers} workers, seed={args.seed}",flush=True)
    print(f"Metadata: {len(meta['articles'])} slugs, {len(meta['users'])} users, "
          f"{len(meta['tags'])} tags, {len(meta['favorites'])} favorite edges, "
          f"{len(meta['follows'])} follow edges",flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(compare,i,case,servers,secret,args.timeout)
                   for i,case in enumerate(cases,1)]
        for done,future in enumerate(concurrent.futures.as_completed(futures),1):
            _,family,error = future.result()
            families[family] = families.get(family,0) + 1
            if error:
                failures.append(error)
                if len(failures) <= 10:
                    print("FAIL: " + error,file=sys.stderr,flush=True)
            if done % 100 == 0:
                print(f"Compared {done}/{len(cases)}; mismatches={len(failures)}",flush=True)
    elapsed = time.monotonic() - started
    print("Route counts: " + ", ".join(f"{name}={count}" for name,count in sorted(families.items())),flush=True)
    if failures:
        raise AssertionError(f"{len(failures)}/{len(cases)} paired requests failed in {elapsed:.2f}s")
    print(f"PASS: {len(cases)} concurrent paired reads matched exactly in {elapsed:.2f}s",flush=True)


if __name__ == "__main__":
    try:
        main()
    except (AssertionError,ValueError,RuntimeError,subprocess.SubprocessError) as exc:
        print(f"FAIL: {exc}",file=sys.stderr)
        sys.exit(1)
