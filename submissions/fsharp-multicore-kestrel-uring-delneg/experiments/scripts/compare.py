#!/usr/bin/env python3
"""compare.py <portA> <portB> [db]: the same read requests, fired concurrently (so they batch), to two servers on the
same database; prints any response that differs. Read-only: lists of every kind, feeds, articles, comments, profiles."""
import json, random, subprocess, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor
A, B = int(sys.argv[1]), int(sys.argv[2]); DB = sys.argv[3] if len(sys.argv) > 3 else "conduit_seed"
def q(sql):
    return subprocess.run(["psql", "-X", "-At", "-d", DB, "-c", sql], capture_output=True, text=True, check=True).stdout.split("\n")[:-1]
random.seed(7)
emails = q("SELECT email FROM users WHERE id IN (SELECT follower_id FROM follows GROUP BY 1 ORDER BY count(*) DESC LIMIT 12) OR id IN (SELECT user_id FROM favorites GROUP BY 1 ORDER BY count(*) DESC LIMIT 6)")
def req(port, method, path, body=None, tok=None):
    r = urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method, data=None if body is None else json.dumps(body).encode())
    r.add_header("Content-Type", "application/json")
    if tok: r.add_header("Authorization", "Token " + tok)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp: return resp.status, resp.read()
    except urllib.error.HTTPError as e: return e.code, e.read()
toks = [None]
for e in emails:
    s, b = req(A, "POST", "/api/users/login", {"user": {"email": e, "password": "password123"}})
    if s == 200: toks.append(json.loads(b)["user"]["token"])
tags = q("SELECT name FROM tags ORDER BY id LIMIT 30")
authors = q("SELECT u.username FROM users u JOIN articles a ON a.author_id = u.id GROUP BY 1 ORDER BY count(*) DESC LIMIT 20") + q("SELECT username FROM users ORDER BY id LIMIT 5")
favs = q("SELECT u.username FROM users u JOIN favorites f ON f.user_id = u.id GROUP BY 1 ORDER BY count(*) DESC LIMIT 10")
slugs = q("SELECT slug FROM articles ORDER BY id DESC LIMIT 40")
paths = []
for _ in range(600):
    k = random.random(); off = random.choice([0, 0, 0, 10, 20, 990, 1000, 5000]); lim = random.choice([10, 10, 5, 1, 20, 100])
    if k < .3: p = f"/api/articles?limit={lim}&offset={off}"
    elif k < .45: p = f"/api/articles?tag={random.choice(tags)}&limit={lim}&offset={off}"
    elif k < .55: p = f"/api/articles?author={random.choice(authors)}&limit=5&offset={random.choice([0, 0, 5])}"
    elif k < .62: p = f"/api/articles?favorited={random.choice(favs)}&limit=5"
    elif k < .80: p = f"/api/articles/feed?limit={lim}&offset={random.choice([0, 0, 10, 30])}"
    elif k < .90: p = f"/api/articles/{random.choice(slugs)}"
    else: p = f"/api/articles/{random.choice(slugs)}/comments"
    if "unknown" in p: continue
    paths.append((p, random.choice(toks[1:]) if "/feed" in p else random.choice(toks)))
paths += [("/api/articles?tag=no-such-tag", None), ("/api/articles?author=no-such-user", toks[1]), ("/api/articles?offset=499990&limit=100", toks[1])]
def run(port):
    with ThreadPoolExecutor(64) as ex: return list(ex.map(lambda pt: req(port, "GET", pt[0], tok=pt[1]), paths))
ra, rb = run(A), run(B)
bad = 0
for (p, t), x, y in zip(paths, ra, rb):
    if x != y:
        bad += 1
        if bad <= 5: print("DIFF", p, x[0], y[0], x[1][:300], "\n   vs", y[1][:300])
print(f"{len(paths)} requests, {len(toks) - 1} users, {bad} differ, statuses {sorted(set(s for s, _ in ra))}")
