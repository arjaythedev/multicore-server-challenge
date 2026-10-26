#!/usr/bin/env python3
"""Differential test: spec reference SQL vs the statements in src/sql.zig, via psql, on the full seed.
usage: (zig build sqldump) && PGDATABASE=conduit_seed python3 tests/sqldiff.py [seed] [cases]"""
import random, re, subprocess, sys
random.seed(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
N = int(sys.argv[2]) if len(sys.argv) > 2 else 300
if N <= 0: sys.exit("cases must be positive")

def psql(sql):
    try:
        r = subprocess.run(["psql", "-w", "-X", "-qAt", "-F", "\x1f", "-v", "ON_ERROR_STOP=1"],
                           input="SET statement_timeout='30s';\n" + sql, capture_output=True, text=True,
                           timeout=300, check=False)
    except subprocess.TimeoutExpired:
        sys.exit("psql exceeded five minutes; no equivalence result was established")
    if r.returncode != 0:
        print(r.stderr); sys.exit(1)
    return r.stdout

stmts = {}
cur = None
import os
try:
    dump = subprocess.run([os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "zig-out", "bin", "sqldump")], capture_output=True, text=True)
except OSError as exc:
    sys.exit("sqldump failed: %s" % exc)
if dump.returncode != 0:
    sys.exit("sqldump exited %d: %s" % (dump.returncode, dump.stderr.strip()))
for line in dump.stderr.splitlines(True):
    if line.startswith("-- "):
        cur = line[3:].strip()
        if not cur or cur in stmts: sys.exit("SQL dump parse error: empty or duplicate statement header")
        stmts[cur] = ""
    elif cur is None:
        if line.strip(): sys.exit("SQL dump parse error: text before the first statement header")
    else:
        stmts[cur] += line
stmts = {k: v.strip().rstrip(";") for k, v in stmts.items()}
if not stmts or any(not v for v in stmts.values()):
    sys.exit("SQL dump parse error: missing or empty statements")

tags = psql("SELECT name FROM tags ORDER BY id").split("\n")[:-1]
authors = psql("SELECT u.username FROM users u JOIN (SELECT author_id, count(*) c FROM articles GROUP BY 1 ORDER BY c DESC, author_id LIMIT 30) t ON t.author_id=u.id ORDER BY u.username").split("\n")[:-1]
rand_users = psql("SELECT username FROM users WHERE id IN (%s) ORDER BY username" % ",".join(str(random.randint(1,100000)) for _ in range(200))).split("\n")[:-1]
heavy_fav = psql("SELECT u.username FROM users u JOIN (SELECT user_id, count(*) c FROM favorites GROUP BY 1 ORDER BY c DESC, user_id LIMIT 20) t ON t.user_id=u.id ORDER BY u.username").split("\n")[:-1]
heavy_follow = psql("SELECT follower_id FROM follows GROUP BY 1 ORDER BY count(*) DESC, follower_id LIMIT 20").split("\n")[:-1]

ART = """SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a JOIN users u ON u.id = a.author_id """
refs = {
 "list_global": (ART + "ORDER BY a.id DESC LIMIT $2 OFFSET $3", "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s", ["bigint","int","int"], [1,2,3], []),
 "list_tag": (ART + "WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC", "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000) s", ["bigint","int","int","text"], [1,2,3,4], []),
 "list_author": (ART + "WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a.id DESC LIMIT $2 OFFSET $3", "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000) s", ["bigint","int","int","text"], [1,2,3,4], []),
 "list_fav": (ART + "WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC", "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000) s", ["bigint","int","int","text"], [1,2,3,4], []),
 "feed": (ART + "WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC", "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s", ["bigint","int","int"], [1,2,3], []),
}

missing = sorted(set(refs) - set(stmts))
if missing: sys.exit("SQL dump parse error: missing statements %s" % ", ".join(missing))
if not heavy_follow: sys.exit("seed fixtures required: no followers found")

def lit(v): return "'" + str(v).replace("'", "''") + "'"
cases = []
for _ in range(N):
    kind = random.choice(list(refs))
    viewer = random.choice([0, random.randint(1, 100000), int(random.choice(heavy_follow))])
    limit = random.choice([1, 5, 10, 10, 10, 20, 100, random.randint(1, 100)])
    offset = random.choice([0, 0, 0, 10, 20, 30, 40, 5, random.randint(0, 200), 100000, 499995, 600000])
    args: list[int | str] = [viewer, limit, offset]
    if kind == "list_tag": args.append(random.choice(tags + ["no_such_tag"]))
    if kind == "list_author": args.append(random.choice(authors + rand_users + ["no_such_user"]))
    if kind == "list_fav": args.append(random.choice(heavy_fav + rand_users + ["no_such_user"]))
    if kind == "feed": args = [int(random.choice(heavy_follow)) if random.random() < .3 else random.randint(1,100000), limit, offset]
    cases.append((kind, args))

out = ["SET plan_cache_mode = force_generic_plan;", "SET jit = off;"]
for kind, (rsql, csql, types, _, _) in refs.items():
    out.append("PREPARE ref_%s(%s) AS %s;" % (kind, ",".join(types), rsql))

    out.append("PREPARE refc_%s(%s) AS %s;" % (kind, ",".join(types), csql))
    out.append("PREPARE new_%s(%s) AS %s;" % (kind, ",".join(types), stmts[kind]))
prepared = out.copy()
for i, (kind, args) in enumerate(cases):
    types = refs[kind][2]
    al = ",".join(lit(a) if t == "text" else str(a) for a, t in zip(args, types))

    out.append("\\echo @@%d" % i)
    out.append("EXECUTE ref_%s(%s);" % (kind, al))
    out.append("\\echo @@C")
    out.append("EXECUTE refc_%s(%s);" % (kind, al))
    out.append("\\echo @@N")
    out.append("EXECUTE new_%s(%s);" % (kind, al))
commands = out[len(prepared):]
results = []
for first in range(0, len(cases), 100):
    end = min(first + 100, len(cases))
    results.append(psql("\n".join(prepared + commands[first * 6:end * 6])))
    print("SQL differential: executed %d/%d cases" % (end, len(cases)), flush=True)
res = "".join(results)
blocks = re.split(r"^@@(\d+)\n", res, flags=re.M)
if blocks[0].strip() or len(blocks) != 2 * len(cases) + 1:
    sys.exit("SQL result parse error: expected %d case blocks, got %d (or unexpected preamble)" % (len(cases), (len(blocks) - 1) // 2))
bad = 0
for i in range(len(cases)):
    try:
        if int(blocks[2 * i + 1]) != i:
            raise ValueError("missing, duplicate, or out-of-order case marker")
        body = blocks[2 * i + 2]
        ref, rest = body.split("@@C\n")
        cnt, new = rest.split("@@N\n")
        refrows = [l.split("\x1f") for l in ref.split("\n") if l]
        cnt = int(cnt.strip())
        newrows_all = [l.split("\x1f") for l in new.split("\n") if l]
        if any(len(r) != 13 for r in refrows):
            raise ValueError("reference row does not have 13 columns")
        if not newrows_all or any(len(r) != 14 for r in newrows_all):
            raise ValueError("missing result or result row does not have 14 columns")
        ncount = int(newrows_all[0][0])
        if cnt < 0 or ncount < 0 or any(int(r[0]) != ncount for r in newrows_all):
            raise ValueError("negative or inconsistent article count")
        if any(r[1] == "" and (len(newrows_all) != 1 or any(r[2:])) for r in newrows_all):
            raise ValueError("malformed empty-page sentinel")
        newrows = [r[1:] for r in newrows_all if r[1] != ""]
    except ValueError as exc:
        sys.exit("SQL result parse error in case %d: %s" % (i, exc))
    ok = (ncount == cnt) and refrows == newrows
    if not ok:
        bad += 1
        if bad <= 5:
            print("MISMATCH case", i, cases[i], "count", cnt, ncount, "rows", len(refrows), len(newrows))
            for a, b in zip(refrows, newrows):
                if a != b: print(" ref", a); print(" new", b); break
print("cases:", len(cases), "mismatches:", bad)
sys.exit(1 if bad else 0)
