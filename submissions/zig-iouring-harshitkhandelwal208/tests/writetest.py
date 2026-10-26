#!/usr/bin/env python3
"""Concurrent writes; verify responses, immediate visibility and independently persisted totals.
Requires psql connected to the server's database via DATABASE_URL or the usual libpq PG* settings.
"""
import hmac, hashlib, base64, json, sys, threading, http.client, time, os, subprocess, uuid, urllib.parse
PORT = int(sys.argv[1]); N = int(sys.argv[2]) if len(sys.argv) > 2 else 200
if N <= 0: sys.exit("thread count must be positive")
SECRET = b"multicore-server-challenge"
def b64(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
def token(uid):
    now = int(time.time()); h = b64(b'{"alg":"HS256","typ":"JWT"}'); p = b64(json.dumps({"sub": str(uid), "iat": now, "exp": now + 3600}).encode())
    return f"{h}.{p}." + b64(hmac.new(SECRET, (h + "." + p).encode(), hashlib.sha256).digest())
def call(method, path, uid=None, body=None):
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=30)
    hdr = {"Content-Type": "application/json"}
    if uid: hdr["Authorization"] = "Token " + token(uid)
    try:
        c.request(method, path, body=json.dumps(body) if body is not None else None, headers=hdr)
        r = c.getresponse(); data = r.read()
        return r.status, (json.loads(data) if data else None)
    finally:
        c.close()

def require(cond, message):
    if not cond: raise RuntimeError(message)

def expect(method, path, status, uid=None, body=None):
    st, data = call(method, path, uid, body)
    require(st == status, "%s %s returned %d, expected %d: %r" % (method, path, st, status, data))
    if not isinstance(data, dict):
        raise RuntimeError("expected a JSON object from %s %s" % (method, path))
    return data

def lit(s): return "'" + s.replace("'", "''") + "'"

def db_json(sql):
    cmd = ["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1"]
    if os.environ.get("DATABASE_URL"): cmd += ["--dbname", os.environ["DATABASE_URL"]]
    r = subprocess.run(cmd, input="SET default_transaction_read_only=on;\n" + sql, capture_output=True, text=True, timeout=30)
    require(r.returncode == 0, "psql failed: " + r.stderr.strip())
    try:
        return json.loads(r.stdout)
    except ValueError as exc:
        raise RuntimeError("expected one JSON result from psql; check the server database settings: %s" % exc) from exc

run_id = uuid.uuid4().hex
run_tag = "writetest-" + run_id
comment_prefix = "concurrent " + run_id + " "
last_uid = 5000 + N - 1
# Avoid self-follow when a previous run's article is now the newest one.
fixture = db_json("SELECT json_build_object('slug', a.slug, 'author', u.username) FROM articles a JOIN users u ON u.id=a.author_id WHERE a.author_id NOT BETWEEN 5000 AND %d ORDER BY a.id DESC LIMIT 1;" % last_uid)
slug, author = fixture["slug"], fixture["author"]
article_path = "/api/articles/" + urllib.parse.quote(slug, safe="")
profile_path = "/api/profiles/" + urllib.parse.quote(author, safe="")

def snapshot():
    return db_json("""SELECT json_build_object(
      'favorites', (SELECT count(*) FROM favorites f WHERE f.article_id=a.id),
      'worker_favorites', (SELECT count(*) FROM favorites f WHERE f.article_id=a.id AND f.user_id BETWEEN 5000 AND %d),
      'worker_users', (SELECT count(*) FROM users WHERE id BETWEEN 5000 AND %d),
      'comments', (SELECT count(*) FROM comments c WHERE c.article_id=a.id),
      'run_comments', (SELECT count(*) FROM comments c WHERE c.article_id=a.id AND c.body LIKE %s),
      'comment_ids', ARRAY(SELECT c.id FROM comments c WHERE c.article_id=a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100),
      'tagged', (SELECT count(*) FROM article_tags at JOIN tags t ON t.id=at.tag_id WHERE t.name=%s)
    ) FROM articles a WHERE a.slug=%s;""" % (last_uid, last_uid, lit(comment_prefix + "%"), lit(run_tag), lit(slug)))

base = snapshot()
require(base["worker_users"] == N, "seed must contain every worker user id from 5000 through %d" % last_uid)
require(base["tagged"] == 0 and base["run_comments"] == 0, "per-run fixtures already exist")
d = expect("GET", article_path, 200)
require(d["article"]["slug"] == slug and d["article"]["author"]["username"] == author, "baseline article identity differs from database")
require(d["article"]["favoritesCount"] == base["favorites"], "baseline favorite count differs from database")
d = expect("GET", article_path + "/comments", 200, 1)
require(len(d["comments"]) == min(100, base["comments"]) and [c["id"] for c in d["comments"]] == base["comment_ids"], "baseline comments differ from database")
d = expect("GET", profile_path, 200)
require(d["profile"]["username"] == author, "baseline profile identity differs from database")

completed = [False] * N
errors: list[str | None] = [None] * N
comment_ids: list[int | None] = [None] * N
created_slugs: list[str | None] = [None] * N
def worker(i):
    try:
        uid = 5000 + i
        comment_body = comment_prefix + str(i)
        d1 = expect("POST", article_path + "/comments", 201, uid, {"comment": {"body": comment_body}})
        require(d1["comment"]["body"] == comment_body, "created comment body differs")
        comment_ids[i] = d1["comment"]["id"]
        require(type(comment_ids[i]) is int and comment_ids[i] > 0, "invalid created comment id")
        d2 = expect("POST", article_path + "/favorite", 200, uid)
        require(d2["article"]["slug"] == slug and d2["article"]["favorited"] is True, "favorite response identity or flag differs")
        d3 = expect("POST", profile_path + "/follow", 200, uid)
        require(d3["profile"]["username"] == author and d3["profile"]["following"] is True, "follow response identity or flag differs")
        profile = expect("GET", profile_path, 200, uid)["profile"]
        require(profile["username"] == author and profile["following"] is True, "follow is not immediately visible on the existing profile")
        title = "T %s %d" % (run_id, i)
        tags = ["gc%d" % (i % 7), run_tag]
        d4 = expect("POST", "/api/articles", 201, uid, {"article": {"title": title, "description": "d", "body": "b", "tagList": tags}})
        created = d4["article"]["slug"]
        require(isinstance(created, str) and created and created != slug, "invalid created article slug")
        created_slugs[i] = created
        created_path = "/api/articles/" + urllib.parse.quote(created, safe="")
        d5 = expect("GET", created_path, 200)
        for data in (d4, d5):
            art = data["article"]
            require(art["slug"] == created and art["title"] == title and art["description"] == "d" and art["body"] == "b" and sorted(art["tagList"]) == sorted(tags), "created article identity or contents differ")
        require(d5["article"]["author"]["username"] == d4["article"]["author"]["username"], "created article author differs on readback")
        d6 = expect("GET", created_path + "/comments", 200)
        require(d6["comments"] == [], "new article must have an initially empty comment thread")
        completed[i] = True
    except Exception as exc:
        errors[i] = "%s: %s" % (type(exc).__name__, exc)

t0 = time.monotonic()
ts = [threading.Thread(target=worker, args=(i,)) for i in range(N)]
[t.start() for t in ts]; [t.join() for t in ts]
bad = [(i, errors[i] or "worker did not complete") for i in range(N) if errors[i] is not None or not completed[i]]
print("completed workers: %d/%d" % (sum(completed), N))
print("bad responses:", len(bad), bad[:3])
final = snapshot()
article = expect("GET", article_path, 200)["article"]
comments = expect("GET", article_path + "/comments", 200, 1)["comments"]
tagged = expect("GET", "/api/articles?tag=%s&limit=100" % urllib.parse.quote(run_tag, safe=""), 200)
expected_favorites = base["favorites"] + N - base["worker_favorites"]
issues = []
def final_check(cond, message):
    if not cond: issues.append(message)
final_check(sum(completed) == N, "not every worker completed")
final_check(article["slug"] == slug and article["favoritesCount"] == final["favorites"] == expected_favorites and final["worker_favorites"] == N, "favorite identity or persisted totals differ")
final_check(final["comments"] == base["comments"] + N and final["run_comments"] == N, "persisted comment totals differ")
final_check(len(comments) == min(100, final["comments"]) and [c["id"] for c in comments] == final["comment_ids"], "visible comments differ from the database's newest 100")
final_check(len({c for c in comment_ids if c is not None}) == N, "created comment ids are not unique and complete")
created = {s for s in created_slugs if s is not None}
listed = [a["slug"] for a in tagged["articles"]]
final_check(len(created) == N and final["tagged"] == N and tagged["articlesCount"] == min(1000, N), "created article or unique-tag totals differ")
final_check(len(listed) == min(100, N) and len(set(listed)) == len(listed) and set(listed) <= created and all(run_tag in a["tagList"] for a in tagged["articles"]), "unique-tag page contains missing, duplicate, or unrelated articles")
print("favorites: %d -> %d (expected %d)" % (base["favorites"], final["favorites"], expected_favorites))
print("persisted comments: %d -> %d (expected +%d); visible %d (cap 100)" % (base["comments"], final["comments"], N, len(comments)))
print("articles tagged %r: %d (expected %d; API count cap 1000)" % (run_tag, final["tagged"], N))
for issue in issues: print("FAIL", issue)
print("elapsed %.2fs" % (time.monotonic() - t0))
sys.exit(1 if bad or issues else 0)
