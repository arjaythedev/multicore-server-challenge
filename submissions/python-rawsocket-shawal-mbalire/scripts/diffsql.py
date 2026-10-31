"""Diff every response body Postgres builds (repository `q_*` statements) against the SPEC's reference SQL on
conduit_full: lists, feed, article, comments, profile, tags, and the writes (follow, favorite, create/update/delete
article, create/delete comment). Each write runs inside a transaction that is rolled back, and its response is
compared with the reference SQL read in that same transaction. Nothing is left changed in the database.

    PYTHONPATH=. .venv/bin/python scripts/diffsql.py
    REPO=rows ...   # the same check for DB_DRIVER=libpq-rows (bodies built in the app from rows)
"""
import dataclasses, datetime, os, random, orjson
from psycopg.rows import dict_row
from conduit_server.adapters.outbound.pg_repository import PostgresUserRepository, SingleConnection
from conduit_server.domain import services
from conduit_server.domain.models import (ArticleData, ArticlesResponse, CommentData, CommentsResponse, ProfileData,
                                          ProfileResponse, SingleArticleResponse, SingleCommentResponse, TagsResponse)

URL = os.getenv("DATABASE_URL", "postgres://conduit:conduit@127.0.0.1:5432/conduit_full")
pool = SingleConnection(URL)
if os.getenv("REPO") == "rows":
    from conduit_server.adapters.outbound.json_codec import OrjsonCodec
    from conduit_server.adapters.outbound.pg_rows_repository import PostgresRowsRepository
    repo = PostgresRowsRepository(pool, OrjsonCodec())
else:
    repo = PostgresUserRepository(pool)
conn = pool.get()
c = conn.cursor(row_factory=dict_row)

SEL = """SELECT a.id, a.slug, a.title, a.description, {body} a.created_at, a.updated_at,
 ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = %(v)s) AS favorited,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = %(v)s AND fo.followee_id = a.author_id) AS following
 FROM articles a JOIN users u ON u.id = a.author_id"""
LIST_SEL, FULL_SEL = SEL.format(body=""), SEL.format(body="a.body,")
OP = "ORDER BY a.id DESC LIMIT %(l)s OFFSET %(o)s"
REF = {
 "none": (f"{LIST_SEL} {OP}", "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s"),
 "tag": (f"{LIST_SEL} WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = %(x)s) ORDER BY at.article_id DESC LIMIT %(l)s OFFSET %(o)s) ORDER BY a.id DESC",
         "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = %(x)s) LIMIT 1000) s"),
 "author": (f"{LIST_SEL} WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = %(x)s) {OP}",
         "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = %(x)s) LIMIT 1000) s"),
 "favorited": (f"{LIST_SEL} WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = %(x)s) ORDER BY f.article_id DESC LIMIT %(l)s OFFSET %(o)s) ORDER BY a.id DESC",
         "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = %(x)s) LIMIT 1000) s"),
 "feed": (f"{LIST_SEL} WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT (%(l)s::int + %(o)s::int)) x WHERE fo.follower_id = %(v)s ORDER BY x.id DESC LIMIT %(l)s OFFSET %(o)s) ORDER BY a.id DESC",
         "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = %(v)s) LIMIT 1000) s"),
}
COMMENTS = """SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = %(v)s AND fo.followee_id = c.author_id) AS following
 FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = %(a)s
 ORDER BY c.created_at DESC, c.id DESC LIMIT 100"""
PROFILE = """SELECT u.id, u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = %(v)s AND fo.followee_id = u.id) AS following
 FROM users u WHERE u.username = %(x)s"""

UTC = datetime.timezone.utc
def ts(dt):  # RFC 3339 UTC, milliseconds truncated
    dt = dt.astimezone(UTC); s = dt.isoformat()
    return s[:23] + "Z" if dt.microsecond else s[:19] + ".000Z"
def author(r):
    return ProfileData(username=r["username"], bio=r["bio"], image=r["image"], following=r["following"])
def article(r, body=True):
    a = ArticleData(slug=r["slug"], title=r["title"], description=r["description"], body=r.get("body"),
                    tagList=r["tag_list"], createdAt=ts(r["created_at"]), updatedAt=ts(r["updated_at"]),
                    favorited=r["favorited"], favoritesCount=r["favorites_count"], author=author(r))
    if body:
        return a
    d = dataclasses.asdict(a); del d["body"]  # list entries omit body
    return d
def comment(r):
    return CommentData(id=r["id"], createdAt=ts(r["created_at"]), updatedAt=ts(r["updated_at"]), body=r["body"],
                       author=author(r))
def norm(x):
    return None if x is None else orjson.loads(orjson.dumps(x))

def ref_list(kind, v, l, o, x):
    p = dict(v=v, l=l, o=o, x=x)
    rows = c.execute(REF[kind][0], p).fetchall()
    n = c.execute(REF[kind][1], p).fetchone()["count"]
    return ArticlesResponse(articles=[article(r, body=False) for r in rows], articlesCount=n)
def ref_article(v, slug):
    r = c.execute(f"{FULL_SEL} WHERE a.slug = %(s)s", dict(v=v, s=slug)).fetchone()
    return r and SingleArticleResponse(article=article(r))
def ref_comments(v, slug):
    a = c.execute("SELECT id FROM articles WHERE slug = %s", (slug,)).fetchone()
    return a and CommentsResponse(comments=[comment(r) for r in c.execute(COMMENTS, dict(v=v, a=a["id"]))])
def ref_profile(v, uname):
    r = c.execute(PROFILE, dict(v=v, x=uname)).fetchone()
    return r and ProfileResponse(profile=author(r))

n = bad = 0
def check(label, got, want):
    global n, bad
    n += 1
    if norm(None if got is None else orjson.loads(got)) != norm(want):
        bad += 1; print("MISMATCH", label)

tags = [r["name"] for r in c.execute("SELECT name FROM tags")] + ["no-such-tag"]
users = [r["username"] for r in c.execute("SELECT username FROM users ORDER BY random() LIMIT 300")] + ["nobody-xyz"]
favers = [r["username"] for r in c.execute("SELECT u.username FROM favorites f JOIN users u ON u.id=f.user_id GROUP BY 1 ORDER BY random() LIMIT 100")]
maxu = c.execute("SELECT max(id) AS m FROM users").fetchone()["m"]
random.seed(1)

# ---- reads
for i in range(600):
    kind = random.choice(list(REF)); v = random.choice([0, random.randint(1, maxu)])
    if kind == "feed" and v == 0: v = random.randint(1, maxu)
    l = random.choice([5, 10, 20]); o = random.choice([0, 0, 10, 20, 40, 995])
    x = {"tag": random.choice(tags), "author": random.choice(users), "favorited": random.choice(favers + users[:20])}.get(kind, "")
    q = repo.q_feed_articles_json(v, l, o) if kind == "feed" else repo.q_list_articles_json(v, l, o, kind, x)
    check(("list", kind, v, l, o, x), q.run(), ref_list(kind, v, l, o, x))
slugs = [r["slug"] for r in c.execute("SELECT slug FROM articles ORDER BY random() LIMIT 50")]
for slug in slugs + ["no-such-slug"]:
    v = random.choice([0, 7])
    check(("comments", slug), repo.q_list_comments_by_slug_json(v, slug).run(), ref_comments(v, slug))
    check(("article", slug), repo.q_find_article_json(v, slug).run(), ref_article(v, slug))
for uname in users[:50]:
    v = random.choice([0, 7])
    check(("profile", uname), repo.q_find_profile_json(v, uname).run(), ref_profile(v, uname))
check("tags", repo.q_list_tags_json().run(),
      TagsResponse(tags=[r["name"] for r in c.execute("SELECT name FROM tags ORDER BY name")]))

# ---- writes: each in a transaction that is rolled back, checked against the reference SQL in that transaction
def rolled_back(fn):
    conn.pgconn.exec_(b"BEGIN")
    try:
        fn()
    finally:
        conn.pgconn.exec_(b"ROLLBACK")
def uid(uname):
    return c.execute("SELECT id FROM users WHERE username = %s", (uname,)).fetchone()["id"]

for slug in slugs[:20]:
    v = random.randint(1, maxu)
    rolled_back(lambda: check(("favorite", slug), repo.q_favorite_json(v, slug).run(), ref_article(v, slug)))
    rolled_back(lambda: check(("unfavorite", slug), repo.q_unfavorite_json(v, slug).run(), ref_article(v, slug)))
    fav_v = c.execute("SELECT user_id FROM favorites f JOIN articles a ON a.id = f.article_id WHERE a.slug = %s LIMIT 1",
                      (slug,)).fetchone()
    if fav_v:  # unfavorite by a user who had favorited it
        rolled_back(lambda: check(("unfavorite own", slug), repo.q_unfavorite_json(fav_v["user_id"], slug).run(),
                                  ref_article(fav_v["user_id"], slug)))
for uname in users[:20] + ["nobody-xyz"]:
    v = random.randint(1, maxu)
    rolled_back(lambda: check(("follow", uname), repo.q_follow_json(v, uname).run(), ref_profile(v, uname)))
    rolled_back(lambda: check(("unfollow", uname), repo.q_unfollow_json(v, uname).run(), ref_profile(v, uname)))
check(("favorite", "no-such-slug"), repo.q_favorite_json(7, "no-such-slug").run(), None)

def article_writes(slug):
    a = c.execute("SELECT id, author_id, slug FROM articles WHERE slug = %s", (slug,)).fetchone()
    owner = a["author_id"]
    def create():
        tag_list = sorted(random.sample(tags[:-1], 2)) + ["diffsql-new-tag"]
        got = repo.q_create_article_json(owner, "Diff SQL: Title!", "desc", "body", tag_list).run()
        new_slug = orjson.loads(got)["article"]["slug"]
        check(("create article", slug), got, ref_article(owner, new_slug))
        assert new_slug == services.slugify("Diff SQL: Title!") + "-" + new_slug.rsplit("-", 1)[1]
    def update(fields):
        def run():
            author_id, got = repo.q_update_article_by_slug_json(owner, slug, fields).run()
            new_slug = orjson.loads(got)["article"]["slug"]
            check(("update article", slug, tuple(fields)), got, ref_article(owner, new_slug))
        return run
    def update_not_owner():
        author_id, got = repo.q_update_article_by_slug_json(owner + 1, slug, {"body": "x"}).run()
        check(("update not owner", slug), None if got is None else b"null", None)
        assert author_id == owner and ref_article(owner, slug) is not None
    def delete():
        assert repo.q_delete_article_by_slug(owner + 1, slug).run() == owner  # not the owner: nothing deleted
        assert ref_article(0, slug) is not None
        assert repo.q_delete_article_by_slug(owner, slug).run() == owner
        check(("delete article", slug), None, ref_article(0, slug))
    def comments():
        v = random.randint(1, maxu)
        got = repo.q_create_comment_by_slug_json(v, slug, "a comment").run()
        cid = orjson.loads(got)["comment"]["id"]
        r = c.execute(COMMENTS.replace("WHERE c.article_id = %(a)s", "WHERE c.id = %(a)s"), dict(v=v, a=cid)).fetchone()
        check(("create comment", slug), got, SingleCommentResponse(comment=comment(r)))
        assert repo.q_delete_comment_by_slug(v + 1, slug, cid).run() == v  # not the author: nothing deleted
        assert repo.q_delete_comment_by_slug(v, slug, cid).run() == v
        check(("delete comment", slug), None, c.execute("SELECT 1 FROM comments WHERE id = %s", (cid,)).fetchone())
    for fn in (create, update({"title": "New Title, Again"}), update({"body": "new body"}),
               update({"description": "d2", "body": "b2"}), update_not_owner, delete, comments):
        rolled_back(fn)
for slug in slugs[:10]:
    article_writes(slug)
# the author following themselves: `following` must come out true, as from the reference SQL
a = c.execute("SELECT slug, author_id FROM articles WHERE slug = %s", (slugs[0],)).fetchone()
conn.pgconn.exec_(b"BEGIN")
try:
    c.execute("INSERT INTO follows (follower_id, followee_id) VALUES (%s, %s) ON CONFLICT DO NOTHING",
              (a["author_id"], a["author_id"]))
    _, got = repo.q_update_article_by_slug_json(a["author_id"], a["slug"], {"body": "b"}).run()
    check("update, author follows self", got, ref_article(a["author_id"], a["slug"]))
    got = repo.q_create_article_json(a["author_id"], "Self", "d", "b", []).run()
    check("create, author follows self", got, ref_article(a["author_id"], orjson.loads(got)["article"]["slug"]))
finally:
    conn.pgconn.exec_(b"ROLLBACK")
assert c.execute("SELECT count(*) FROM tags WHERE name = 'diffsql-new-tag'").fetchone()["count"] == 0
print(f"{n} cases, {bad} mismatches")
