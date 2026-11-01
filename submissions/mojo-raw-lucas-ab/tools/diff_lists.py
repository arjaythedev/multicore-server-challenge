"""Differential test of our list statements against SPEC.md's reference SQL, on the same database: random
filters, viewers, limits and offsets; every row, column and count must match.

Our statements' text comes from src/sql.mojo (tools/print_sql.mojo); the reference text is SPEC.md's, below. Run it on an idle database (a concurrent write would differ legitimately).

    python3 tools/diff_lists.py <database> [cases]
"""
import random
import subprocess
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from pgss import our_statements, psql  # noqa: E402

LIST_SELECT = """SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id"""
ORDER_PAGE = "ORDER BY a.id DESC LIMIT $2 OFFSET $3"
FULL_SELECT = LIST_SELECT.replace("a.description,", "a.description, a.body,", 1)
REFERENCE = {  # SPEC.md: list name -> (page, count, count's parameters as indexes into (viewer, limit, offset, filter))
    "global list": (f"{LIST_SELECT} {ORDER_PAGE}", "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s", []),
    "tag list": (f"{LIST_SELECT} WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
                 "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s", [3]),
    "author list": (f"{LIST_SELECT} WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) {ORDER_PAGE}",
                    "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s", [3]),
    "favorited list": (f"{LIST_SELECT} WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
                       "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s", [3]),
    "feed list": (f"{LIST_SELECT} WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
                  "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s", [0]),
}


def lit(v):
    return "'" + str(v).replace("'", "''") + "'"


def run(sql_text, params):
    """Rows of the prepared statement, as lists of column strings (NULL as \\N)."""
    script = f"PREPARE s AS {sql_text};\n\\pset null '\\\\N'\nEXECUTE s({', '.join(lit(p) for p in params)});\n" \
        if params else f"PREPARE s AS {sql_text};\n\\pset null '\\\\N'\nEXECUTE s;\n"
    r = subprocess.run(["psql", "-X", "-q", "-At", "-F", "\x1f", "-R", "\x1e", "-d", db], input=script,
                       capture_output=True, text=True)
    if r.returncode or "ERROR" in r.stderr:
        raise RuntimeError(r.stderr)
    out = r.stdout[:-1] if r.stdout.endswith("\n") else r.stdout  # psql's final newline
    return [row.split("\x1f") for row in out.split("\x1e") if row]


db = sys.argv[1]
cases = int(sys.argv[2]) if len(sys.argv) > 2 else 300
ours = our_statements()  # the exact SQL the server prepares
missing = (set(REFERENCE) | {"article by slug"}) - set(ours)
if missing:
    sys.exit(f"statements not found in src/sql.mojo: {sorted(missing)}")

rnd = random.Random(42)
tags = psql(db, "select name from tags order by id").split()
popular_tags = psql(db, "select t.name from tags t join article_tags at on at.tag_id = t.id group by 1 order by count(*) desc limit 5").split()
authors = psql(db, "(select username from users where id in (select author_id from articles group by 1 order by count(*) desc limit 5))"
               " union all (select username from users where id in (select author_id from articles group by 1 having count(*) <= 3 limit 10))").split()
favoriters = psql(db, "(select username from users where id in (select user_id from favorites group by 1 order by count(*) desc limit 5))"
                  " union all (select username from users order by random() limit 10)").split()
followers = [int(x) for x in psql(db, "select follower_id from follows group by 1 order by count(*) desc limit 5").split()]
users = [int(x) for x in psql(db, "select id from users order by random() limit 20").split()]
filters = {"global list": [None], "tag list": tags + popular_tags * 4 + ["no_such_tag"],
           "author list": authors + ["no_such_user"], "favorited list": favoriters + ["no_such_user"], "feed list": [None]}

bad = 0
for k in range(cases):
    lst = list(REFERENCE)[k % len(REFERENCE)]
    viewer = rnd.choice(followers + users) if lst == "feed list" else rnd.choice([0, 0] + users + followers)
    limit = rnd.choice([1, 5, 10, 10, 20, 37, 100])
    offset = rnd.choice([0, 0, 0, 5, 10, 20, 40, 99, 990, 1500, 100000000 if lst == "global list" else 3000])
    f = rnd.choice(filters[lst])
    params = [viewer, limit, offset] + ([f] if f is not None else [])
    page_sql, count_sql, count_args = REFERENCE[lst]
    ref_rows = run(page_sql, params)
    ref_count = run(count_sql, [params[i] for i in count_args])[0][0]
    got = run(ours[lst], params)
    got_rows = [r[:13] for r in got if r[0] != "\\N"]
    got_count = got[0][13] if got else None
    if ref_rows != got_rows or ref_count != got_count:
        bad += 1
        if bad <= 5:
            print(f"MISMATCH {lst} {params}: reference {len(ref_rows)} rows count {ref_count}, ours {len(got_rows)} rows"
                  f" count {got_count}")
# single articles (ARTICLE_FULL_SELECT WHERE a.slug = $2): random ones, and the ones with the most tags
slugs = psql(db, "(select slug from articles order by random() limit 60) union all (select a.slug from articles a"
                 " join article_tags at on at.article_id = a.id group by a.slug order by count(*) desc limit 20)").split()
for slug in slugs:
    viewer = rnd.choice([0] + users + followers)
    ref = run(f"{FULL_SELECT} WHERE a.slug = $2", [viewer, slug])
    if ref != run(ours["article by slug"], [viewer, slug]):
        bad += 1
        print(f"MISMATCH article by slug {viewer} {slug}")
cases += len(slugs)
print(f"{cases} cases over {len(REFERENCE)} lists and single articles: " + ("all identical" if bad == 0 else f"{bad} mismatches"))
sys.exit(1 if bad else 0)
