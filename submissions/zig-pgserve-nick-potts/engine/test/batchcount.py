"""The batch favorites counter against SQL, on a churned copy of the dev seed.

A scratch database is copied from the seed and churned: favorites inserted, deleted and re-inserted in
small transactions, rows HOT-updated (favorites.created_at, articles.body), one article given thousands
of favorites (posting lists, leaf splits), with VACUUMs between rounds so heap pages are a mix of
all-visible and not. Then, in one REPEATABLE READ transaction, every article's favoritesCount from the
engine (list_all over every page, article by slug, list_favorited, list_tag, list_author) is compared
with SELECT count(*) under the same snapshot, while another connection keeps writing (committed and
not), whose changes the snapshot must not see.

    PGPORT=55418 PGPASSWORD=pg test/batchcount.py [lib ...]

`lib` names the engine builds to test (default: pgengine). A build with a tiny Counter array or slot
limit (build.sh NAME=pgengine_tiny with PEND_CAP / MAX_SLOTS edited) takes the fallback paths; the
same checks apply. Connects as the superuser in PGUSER (default postgres) to make and churn the
database, and as conduit to read through the engine.
"""
import json
import os
import random
import sys
import time

import psycopg2
import psycopg2.extensions

import markers

HOST = os.environ.get("PGHOST", "127.0.0.1")
PORT = int(os.environ.get("PGPORT", "5432"))
SUPER = dict(host=HOST, port=PORT, user=os.environ.get("PGUSER", "postgres"), password=os.environ.get("PGPASSWORD", ""))
SRC = os.environ.get("SRC", "conduit_dev")
DB = os.environ.get("BATCHCOUNT_DB", "pgengine_batchcount")
SEED = int(os.environ.get("SEED", "1"))
BIG = 5000  # favorites on the one big article
HOT = int(os.environ.get("HOT", "300"))  # articles the churn concentrates on


def connect(dbname, lib=None, user=None):
    opts = "-c jit=off"
    if lib:
        opts += f" -c local_preload_libraries={lib} -c plan_cache_mode=force_generic_plan"
    kw = dict(SUPER, dbname=dbname)
    if user:
        kw.update(user=user, password=user)
    c = psycopg2.connect(options=opts, **kw)
    c.autocommit = True
    return c


def fresh_db():
    c = connect("postgres")
    cur = c.cursor()
    cur.execute("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = %s AND pid <> pg_backend_pid()", (DB,))
    cur.execute(f"DROP DATABASE IF EXISTS {DB}")
    cur.execute(f"CREATE DATABASE {DB} TEMPLATE {SRC}")
    c.close()


class Churn:
    """Random writes to favorites and articles in small transactions, each a snapshot of the real churn."""

    def __init__(self, cur, rnd):
        self.cur = cur
        self.rnd = rnd
        cur.execute("SELECT id FROM users ORDER BY id")
        self.users = [r[0] for r in cur.fetchall()]
        cur.execute("SELECT id FROM articles ORDER BY id")
        self.articles = [r[0] for r in cur.fetchall()]
        self.hot = self.rnd.sample(self.articles, min(HOT, len(self.articles)))
        self.big = self.hot[0]
        self.removed = []

    def insert(self, n):
        rows = [(self.rnd.choice(self.users), self.rnd.choice(self.hot)) for _ in range(n)]
        self.cur.executemany("INSERT INTO favorites (user_id, article_id) VALUES (%s, %s) ON CONFLICT DO NOTHING", rows)

    def delete(self, n):
        self.cur.execute("SELECT user_id, article_id FROM favorites WHERE article_id = ANY(%s) ORDER BY random() LIMIT %s", (self.hot, n))
        rows = self.cur.fetchall()
        self.cur.executemany("DELETE FROM favorites WHERE user_id = %s AND article_id = %s", rows)
        self.removed.extend(rows)

    def reinsert(self, n):
        rows, self.removed = self.removed[:n], self.removed[n:]
        self.cur.executemany("INSERT INTO favorites (user_id, article_id) VALUES (%s, %s) ON CONFLICT DO NOTHING", rows)

    def hot_update(self, n):
        # created_at is not indexed: these updates stay on the page (HOT) while it has room
        self.cur.execute("UPDATE favorites SET created_at = created_at + interval '1 second' WHERE (user_id, article_id) IN "
                         "(SELECT user_id, article_id FROM favorites WHERE article_id = ANY(%s) ORDER BY random() LIMIT %s)", (self.hot, n))
        self.cur.execute("UPDATE articles SET body = body || ' ', updated_at = updated_at WHERE id = ANY(%s)", (self.rnd.sample(self.hot, 20),))

    def grow_big(self):
        users = self.rnd.sample(self.users, BIG)
        for i in range(0, BIG, 500):
            self.cur.executemany("INSERT INTO favorites (user_id, article_id) VALUES (%s, %s) ON CONFLICT DO NOTHING",
                                 [(u, self.big) for u in users[i:i + 500]])

    def round(self, k):
        for _ in range(k):
            op = self.rnd.random()
            if op < 0.4:
                self.insert(self.rnd.randint(1, 8))
            elif op < 0.7:
                self.delete(self.rnd.randint(1, 8))
            elif op < 0.9:
                self.reinsert(self.rnd.randint(1, 8))
            else:
                self.hot_update(self.rnd.randint(1, 30))


def age(cur, rnd, rounds=400):
    """Churn with VACUUMs between rounds, so pages are a mix of all-visible and not."""
    ch = Churn(cur, rnd)
    ch.grow_big()
    for i in range(4):
        ch.round(rounds)
        if i % 2 == 0:
            cur.execute("VACUUM favorites")
            cur.execute("VACUUM articles")
    ch.round(rounds)  # the last round leaves dead and not-yet-all-visible tuples behind
    return ch


class Snapshot:
    """The engine's counts, read in one REPEATABLE READ transaction, against SQL's in the same one."""

    def __init__(self, lib):
        self.conn = connect(DB, lib=lib, user="conduit")
        self.conn.autocommit = False
        self.conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_REPEATABLE_READ)
        self.cur = self.conn.cursor()
        markers.prepare(self.cur, ["list_all", "article", "list_favorited", "list_tag", "list_author"])
        self.cur.execute("SELECT a.id, a.slug, count(f.user_id) FROM articles a LEFT JOIN favorites f ON f.article_id = a.id GROUP BY a.id")
        rows = self.cur.fetchall()
        self.by_slug = {slug: n for _, slug, n in rows}
        self.by_id = {i: n for i, _, n in rows}
        self.cur.execute("SELECT count(*) FROM favorites")
        self.total = self.cur.fetchone()[0]
        self.checked = 0
        self.bad = []

    def articles(self, name, reqs):
        markers.execute(self.cur, name, reqs)
        out = []
        for status, body in self.cur.fetchall():
            assert status == 0, (name, status)
            doc = json.loads(bytes(body).decode())
            out.extend(doc["articles"] if "articles" in doc else [doc["article"]])
        return out

    def check(self, arts):
        for a in arts:
            self.checked += 1
            want = self.by_slug[a["slug"]]
            if a["favoritesCount"] != want:
                self.bad.append((a["slug"], a["favoritesCount"], want))

    def everything(self, viewer, rnd):
        n = len(self.by_slug)
        for off in range(0, n, 100):
            self.check(self.articles("list_all", [(viewer, 100, off)]))
        slugs = rnd.sample(list(self.by_slug), 500)
        for i in range(0, 500, 50):
            self.check(self.articles("article", [(viewer, s) for s in slugs[i:i + 50]]))
        self.cur.execute("SELECT username FROM users ORDER BY random() LIMIT 20")
        users = [r[0] for r in self.cur.fetchall()]
        self.check(self.articles("list_favorited", [(viewer, 100, 0, u) for u in users]))
        self.check(self.articles("list_author", [(viewer, 100, 0, u) for u in users]))
        self.cur.execute("SELECT name FROM tags ORDER BY random() LIMIT 20")
        tags = [r[0] for r in self.cur.fetchall()]
        self.check(self.articles("list_tag", [(viewer, 100, 0, t) for t in tags]))

    def close(self):
        self.conn.rollback()
        self.conn.close()


def compare(lib, rnd, ch, label):
    snap = Snapshot(lib)
    # another connection writes meanwhile: some committed, some left open; the snapshot sees none of it
    other = connect(DB)
    other.autocommit = False
    ocur = other.cursor()
    och = Churn(ocur, random.Random(rnd.random()))
    och.hot = ch.hot
    och.round(30)
    other.commit()
    och.round(30)  # left uncommitted while the engine reads
    snap.everything(0, rnd)
    snap.everything(rnd.choice(ch.users), rnd)
    other.rollback()
    other.close()
    print(f"  {label}: {snap.checked} counts checked against SQL under one snapshot ({snap.total} favorites), {len(snap.bad)} wrong")
    for b in snap.bad[:10]:
        print("   ", b)
    snap.close()
    return not snap.bad


def main():
    libs = sys.argv[1:] or ["pgengine"]
    rnd = random.Random(SEED)
    t0 = time.time()
    fresh_db()
    c = connect(DB)
    cur = c.cursor()
    ch = age(cur, rnd)
    cur.execute("SELECT count(*) FROM favorites WHERE article_id = %s", (ch.big,))
    print(f"aged {DB} in {time.time() - t0:.0f}s: big article has {cur.fetchone()[0]} favorites")
    ok = True
    for lib in libs:
        print(lib)
        ok &= compare(lib, rnd, ch, "after churn and VACUUM")
        ch.round(200)
        ok &= compare(lib, rnd, ch, "after more churn, no VACUUM")
        cur.execute("VACUUM favorites")
        ok &= compare(lib, rnd, ch, "after VACUUM")
    print("OK" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
