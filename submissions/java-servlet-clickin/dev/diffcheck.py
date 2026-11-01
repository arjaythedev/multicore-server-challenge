# Differential check: the same read requests, fired concurrently, against a coalescing server (A) and one with
# COALESCE=0 (B) on the same database. Every response must be byte-identical. Usage: python3 diffcheck.py A_PORT B_PORT
import base64, hashlib, hmac, http.client, json, random, sys, threading, time
A, B = int(sys.argv[1]), int(sys.argv[2])
SECRET = b"dev"
def b64(b): return base64.urlsafe_b64encode(b).rstrip(b"=")
def token(uid):
    h = b64(b'{"alg":"HS256","typ":"JWT"}'); now = int(time.time())
    p = b64(json.dumps({"sub": str(uid), "iat": now, "exp": now + 86400}).encode())
    return (h + b"." + p + b"." + b64(hmac.new(SECRET, h + b"." + p, hashlib.sha256).digest())).decode()
def get(port, path, tok):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    c.request("GET", path, headers={"Authorization": "Token " + tok} if tok else {})
    r = c.getresponse(); body = r.read(); c.close(); return r.status, body
random.seed(7)
c = http.client.HTTPConnection("127.0.0.1", B); c.request("GET", "/api/articles?limit=100"); arts = json.loads(c.getresponse().read())["articles"]
slugs = [a["slug"] for a in arts]; authors = list({a["author"]["username"] for a in arts}); tags = list({t for a in arts for t in a["tagList"]})
def req():
    v = random.choice([0, random.randint(1, 100000)]); k = random.randrange(10)
    lim, off = random.randint(1, 20), random.choice([0, 0, random.randint(0, 60)])
    p = [f"/api/articles?limit={lim}&offset={off}", f"/api/articles/feed?limit={lim}&offset={off}",
         f"/api/articles/{random.choice(slugs + ['nope-1'])}", f"/api/articles/{random.choice(slugs)}/comments",
         f"/api/profiles/{random.choice(authors + ['nobody_x'])}", f"/api/articles?author={random.choice(authors + ['nobody_x'])}&limit={lim}&offset={off}",
         f"/api/articles?tag={random.choice(tags + ['notag'])}&limit={lim}&offset={off}",
         f"/api/articles?favorited={random.choice(authors)}&limit={lim}", "/api/user", "/api/tags"][k]
    if k in (1, 8) and v == 0: v = random.randint(1, 100000)
    return p, (token(v) if v else None)
reqs = [req() for _ in range(3000)]
out = {A: [None] * len(reqs), B: [None] * len(reqs)}
def run(port, idx):
    for i in idx: out[port][i] = get(port, *reqs[i])
for port in (A, B):
    ts = [threading.Thread(target=run, args=(port, range(j, len(reqs), 64))) for j in range(64)]
    [t.start() for t in ts]; [t.join() for t in ts]
bad = [(reqs[i][0], out[A][i][0], out[B][i][0]) for i in range(len(reqs)) if out[A][i] != out[B][i]]
print(f"{len(reqs)} requests, {len(bad)} differ"); [print(" ", *b) for b in bad[:10]]
sys.exit(1 if bad else 0)
