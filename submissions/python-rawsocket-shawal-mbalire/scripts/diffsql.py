"""Diff the repository list/feed/comments/tags SQL against SPEC reference SQL on conduit_lg, and the Postgres-built
list/feed JSON bodies against the responses the rows make.

    PYTHONPATH=. .venv/bin/python scripts/diffsql.py
"""
import datetime, random, psycopg, orjson
from psycopg_pool import ConnectionPool
from conduit_server.adapters.outbound.pg_repository import PostgresUserRepository, configure_connection
from conduit_server.adapters.inbound.controllers import _articles_response
URL = "postgres://conduit:conduit@127.0.0.1:5432/conduit_lg"
pool = ConnectionPool(URL, min_size=1, max_size=1, configure=configure_connection, open=True)
repo = PostgresUserRepository(pool)
c = psycopg.connect(URL, autocommit=True)
SEL = """SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = %(v)s) AS favorited,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = %(v)s AND fo.followee_id = a.author_id) AS following
 FROM articles a JOIN users u ON u.id = a.author_id"""
OP = "ORDER BY a.id DESC LIMIT %(l)s OFFSET %(o)s"
REF = {
 "none": (f"{SEL} {OP}", "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s"),
 "tag": (f"{SEL} WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = %(x)s) ORDER BY at.article_id DESC LIMIT %(l)s OFFSET %(o)s) ORDER BY a.id DESC",
         "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = %(x)s) LIMIT 1000) s"),
 "author": (f"{SEL} WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = %(x)s) {OP}",
         "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = %(x)s) LIMIT 1000) s"),
 "favorited": (f"{SEL} WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = %(x)s) ORDER BY f.article_id DESC LIMIT %(l)s OFFSET %(o)s) ORDER BY a.id DESC",
         "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = %(x)s) LIMIT 1000) s"),
 "feed": (f"{SEL} WHERE a.id IN (SELECT a.id FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = %(v)s) ORDER BY a.id DESC LIMIT %(l)s OFFSET %(o)s) ORDER BY a.id DESC",
         "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = %(v)s) LIMIT 1000) s"),
}
UTC = datetime.timezone.utc
def ts(dt):  # the controllers' former Python formatting: RFC 3339 UTC, milliseconds truncated
    dt = dt.astimezone(UTC); s = dt.isoformat()
    return s[:23] + "Z" if dt.microsecond else s[:19] + ".000Z"
def ref(kind, v, l, o, x):
    p = dict(v=v, l=l, o=o, x=x)
    rows = [r[:4] + (ts(r[4]), ts(r[5])) + r[6:] for r in c.execute(REF[kind][0], p).fetchall()]  # ARTICLE_ROW
    return c.execute(REF[kind][1], p).fetchone()[0], rows
tags = [r[0] for r in c.execute("SELECT name FROM tags")] + ["no-such-tag"]
users = [r[0] for r in c.execute("SELECT username FROM users ORDER BY random() LIMIT 300")] + ["nobody-xyz"]
favers = [r[0] for r in c.execute("SELECT u.username FROM favorites f JOIN users u ON u.id=f.user_id GROUP BY 1 ORDER BY random() LIMIT 100")]
maxu = c.execute("SELECT max(id) FROM users").fetchone()[0]
random.seed(1); n = bad = 0
for i in range(600):
    kind = random.choice(list(REF)); v = random.choice([0, random.randint(1, maxu)])
    if kind == "feed" and v == 0: v = random.randint(1, maxu)
    l = random.choice([5, 10, 20]); o = random.choice([0, 0, 10, 20, 40, 995])
    x = {"tag": random.choice(tags), "author": random.choice(users), "favorited": random.choice(favers + users[:20])}.get(kind, "")
    got = repo.feed_articles(v, l, o) if kind == "feed" else repo.list_articles(v, l, o, kind, x)
    want = ref(kind, v, l, o, x); n += 1
    if got != want:
        bad += 1; print("MISMATCH", kind, v, l, o, x, got[0], want[0], len(got[1]), len(want[1]))
    # the Postgres-built JSON body must decode to the response the rows made
    body = repo.feed_articles_json(v, l, o) if kind == "feed" else repo.list_articles_json(v, l, o, kind, x)
    want_body = orjson.loads(orjson.dumps(_articles_response(want[1], want[0])))
    n += 1
    if orjson.loads(body) != want_body or list(orjson.loads(body)) != list(want_body):
        bad += 1; print("JSON MISMATCH", kind, v, l, o, x)
# comments + tags
for slug, in c.execute("SELECT slug FROM articles ORDER BY random() LIMIT 50").fetchall() + [("no-such-slug",)]:
    got = repo.list_comments_by_slug(7, slug)
    aid = c.execute("SELECT id FROM articles WHERE slug=%s", (slug,)).fetchone()
    want = None if aid is None else repo.list_comments(7, aid[0]); n += 1
    if got != want: bad += 1; print("COMMENTS MISMATCH", slug)
assert repo.list_tags() == [r[0] for r in c.execute("SELECT name FROM tags ORDER BY name")]
print(f"{n} cases, {bad} mismatches")
