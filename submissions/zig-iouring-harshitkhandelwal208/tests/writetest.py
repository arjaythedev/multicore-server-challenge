#!/usr/bin/env python3
"""Concurrent writes: N threads each add a comment, favorite and follow; verify every response and the final counts."""
import hmac, hashlib, base64, json, sys, threading, http.client, time
PORT = int(sys.argv[1]); N = int(sys.argv[2]) if len(sys.argv) > 2 else 200
SECRET = b"multicore-server-challenge"
def b64(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
def token(uid):
    now = int(time.time()); h = b64(b'{"alg":"HS256","typ":"JWT"}'); p = b64(json.dumps({"sub": str(uid), "iat": now, "exp": now + 3600}).encode())
    return f"{h}.{p}." + b64(hmac.new(SECRET, (h + "." + p).encode(), hashlib.sha256).digest())
def call(method, path, uid=None, body=None):
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=30)
    hdr = {"Content-Type": "application/json"}
    if uid: hdr["Authorization"] = "Token " + token(uid)
    c.request(method, path, body=json.dumps(body) if body is not None else None, headers=hdr)
    r = c.getresponse(); data = r.read(); c.close()
    return r.status, (json.loads(data) if data else None)
st, d = call("GET", "/api/articles?limit=1"); slug = d["articles"][0]["slug"]; author = d["articles"][0]["author"]["username"]
st, d = call("GET", "/api/articles/" + slug); fav0 = d["article"]["favoritesCount"]
st, d = call("GET", "/api/articles/%s/comments" % slug, 1); c0 = len(d["comments"])
bad = []
def worker(i):
    uid = 5000 + i
    s1, _ = call("POST", "/api/articles/%s/comments" % slug, uid, {"comment": {"body": "concurrent %d" % i}})
    s2, d2 = call("POST", "/api/articles/%s/favorite" % slug, uid)
    s3, d3 = call("POST", "/api/profiles/%s/follow" % author, uid)
    s4, d4 = call("POST", "/api/articles", uid, {"article": {"title": "T %d" % i, "description": "d", "body": "b", "tagList": ["gc%d" % (i % 7), "common"]}})
    ok = (s1, s2, s3, s4) == (201, 200, 200, 201) and d2["article"]["favorited"] is True and d3["profile"]["following"] is True \
         and sorted(d4["article"]["tagList"]) == sorted(["gc%d" % (i % 7), "common"])
    if not ok: bad.append((i, s1, s2, s3, s4))
t0 = time.time()
ts = [threading.Thread(target=worker, args=(i,)) for i in range(N)]
[t.start() for t in ts]; [t.join() for t in ts]
st, d = call("GET", "/api/articles/" + slug); fav1 = d["article"]["favoritesCount"]
st, d = call("GET", "/api/articles/%s/comments" % slug, 1)
st5, d5 = call("GET", "/api/articles?tag=common&limit=100")
print("bad responses:", len(bad), bad[:3])
print("favorites: %d -> %d (expected +%d)" % (fav0, fav1, N))
print("comments visible (cap 100): %d -> %d" % (c0, len(d["comments"])))
print("articles tagged 'common':", d5["articlesCount"], "(expected", N, ")")
print("elapsed %.2fs" % (time.time() - t0))
sys.exit(1 if bad or fav1 != fav0 + N or d5["articlesCount"] != N else 0)
