#!/usr/bin/env python3
"""Compare responses of a non-batching server (ref port) with a batching one hit concurrently (test port)."""
import hmac, hashlib, base64, json, random, sys, threading, http.client, time, urllib.parse
REF, TST = int(sys.argv[1]), int(sys.argv[2])
SECRET = b"multicore-server-challenge"
import os
HOT = os.environ.get('HOT') == '1'
random.seed(7)
def b64(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
def token(uid):
    now = int(time.time())
    h = b64(b'{"alg":"HS256","typ":"JWT"}'); p = b64(json.dumps({"sub": str(uid), "iat": now, "exp": now + 3600}).encode())
    s = b64(hmac.new(SECRET, (h + "." + p).encode(), hashlib.sha256).digest())
    return f"{h}.{p}.{s}"
def get(port, path, tok=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    c.request("GET", path, headers={"Authorization": "Token " + tok} if tok else {})
    r = c.getresponse(); body = r.read(); c.close()
    return r.status, body
st, body = get(REF, "/api/tags"); tags = json.loads(body)["tags"]
st, body = get(REF, "/api/articles?limit=100"); arts = json.loads(body)["articles"]
slugs = [a["slug"] for a in arts]; authors = list({a["author"]["username"] for a in arts})
if HOT: slugs = slugs[:6]; authors = authors[:4]; tags = tags[:3]
reqs = []
for _ in range(1200 if HOT else 600):
    uid = random.choice([None, random.randint(1, 100000), random.randint(1, 2000)])
    tok = token(uid) if uid else None
    k = random.randint(0, 8)
    lim = random.choice([1, 5, 10, 20, 100]); off = random.choice([0, 0, 10, 20, 40, 200, 100000])
    if HOT: lim = 10; off = random.choice([0, 0, 0, 10, 20])
    if k == 0: path = f"/api/articles?limit={lim}&offset={off}"
    elif k == 1: path = f"/api/articles?tag={urllib.parse.quote(random.choice(tags + ['nope']))}&limit={lim}&offset={off}"
    elif k == 2: path = f"/api/articles?author={urllib.parse.quote(random.choice(authors + ['nobody']))}&limit={lim}&offset={off}"
    elif k == 3: path = f"/api/articles?favorited={urllib.parse.quote(random.choice(authors + ['nobody']))}&limit={lim}"
    elif k == 4: path = "/api/articles/feed?limit=%d&offset=%d" % (lim, off); tok = tok or token(1234)
    elif k == 5: path = "/api/articles/" + random.choice(slugs + ["missing-1", "x%ff"])
    elif k == 6: path = "/api/articles/%s/comments" % random.choice(slugs + ["missing-1"])
    elif k == 7: path = "/api/profiles/" + urllib.parse.quote(random.choice(authors + ["nobody", "a b"]))
    else: path = "/api/tags"
    reqs.append((path, tok))
ref = [get(REF, p, t) for p, t in reqs]
res = [None] * len(reqs)
def worker(ids):
    for i in ids:
        res[i] = get(TST, *reqs[i])
for rnd in range(3):
    NT = 200 if HOT else 64
    ts = [threading.Thread(target=worker, args=(list(range(i, len(reqs), NT)),)) for i in range(NT)]
    [t.start() for t in ts]; [t.join() for t in ts]
    bad = [(reqs[i][0], ref[i][0], res[i][0]) for i in range(len(reqs)) if ref[i] != res[i]]
    print("round", rnd, "mismatches:", len(bad), bad[:3])
    if bad: sys.exit(1)
print("OK: %d requests identical" % len(reqs))
