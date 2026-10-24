"""Where Postgres spends its time, per statement of src/sql.mojo, from pg_stat_statements.

PROFILING ONLY, on a scratch copy of the seed: the extension must never exist on the benchmark database (rule 3).
    shared_preload_libraries = 'pg_stat_statements' in a conf.d file, restart, CREATE EXTENSION in the copy.

    python3 tools/pgss.py <database>          # the table
    python3 tools/pgss.py <database> --reset  # zero the counters before a run
"""
import subprocess
import sys

NAMES = [  # distinctive text -> statement (first match wins, so the specific ones come first)
    ("FROM tags ORDER BY name", "tags"),
    ("INSERT INTO users", "user insert"),
    ("WHERE email = $1", "user by email"),
    ("FROM users WHERE id = $1", "user by id"),
    ("UPDATE users SET", "user update"),
    ("FROM users u WHERE u.username = $2", "profile"),
    ("SELECT id, username, bio, image FROM users WHERE username", "user by username"),
    ("INSERT INTO follows", "follow"),
    ("DELETE FROM follows", "unfollow"),
    # combined page + count statements (sql.list_statement)
    ("FROM follows fo2 CROSS JOIN LATERAL", "feed list"),
    ("at2.tag_id = (SELECT t2.id", "tag list"),
    ("a2.author_id = (SELECT au.id", "author list"),
    ("f2.user_id = (SELECT fu.id", "favorited list"),
    ("SELECT a2.id FROM articles a2 ORDER BY a2.id DESC", "global list"),
    # the reference SQL's separate page and count statements
    ("FROM follows fo CROSS JOIN LATERAL", "feed page"),
    ("IN (SELECT fo.followee_id", "feed count"),
    ("WHERE t.name = $4", "tag page"),
    ("SELECT 1 FROM article_tags at WHERE at.tag_id", "tag count"),
    ("au.username = $4", "author page"),
    ("SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id", "author count"),
    ("fu.username = $4", "favorited page"),
    ("SELECT 1 FROM favorites f WHERE f.user_id", "favorited count"),
    ("ORDER BY a.id DESC LIMIT $2 OFFSET $3", "global page"),
    ("SELECT 1 FROM articles a LIMIT 1000", "global count"),
    ("WHERE a.slug = $2", "article by slug"),
    ("WHERE a.id = $2", "article by id"),
    ("INSERT INTO articles", "article insert"),
    ("INSERT INTO tags", "tags insert"),
    ("INSERT INTO article_tags", "article_tags insert"),
    ("SELECT id, author_id FROM articles", "article owner"),
    ("UPDATE articles", "article update"),
    ("DELETE FROM articles", "article delete"),
    ("SELECT id FROM articles WHERE slug", "article id"),
    ("INSERT INTO favorites", "favorite"),
    ("DELETE FROM favorites", "unfavorite"),
    ("FROM comments c JOIN users u ON u.id = c.author_id WHERE", "comments list"),
    ("WITH c AS (INSERT INTO comments", "comment insert"),
    ("SELECT c.author_id FROM comments", "comment owner"),
    ("DELETE FROM comments", "comment delete"),
]


def name(q):
    for key, n in NAMES:
        if key in q:
            return n
    return "? " + " ".join(q.split())[:40]


def psql(db, sql):
    return subprocess.run(["psql", "-X", "-At", "-F", "\t", "-d", db, "-c", sql], capture_output=True, text=True,
                          check=True).stdout


def main():
    db = sys.argv[1]
    if "--reset" in sys.argv:
        psql(db, "select pg_stat_statements_reset()")
        sys.exit(0)

    out = psql(db, "select calls, total_exec_time, total_plan_time, rows, shared_blks_hit, shared_blks_read, query"
                   " from pg_stat_statements where dbid = (select oid from pg_database where datname = current_database())"
                   " and query not like '%pg_stat_statements%' and calls > 0 and query !~* '^\\s*(prepare|explain) '")
    rows = []
    for line in out.splitlines():
        c, ex, pl, r, hit, rd, q = line.split("\t", 6)
        rows.append((name(q), int(c), float(ex), float(pl), int(r), int(hit), int(rd)))
    total = sum(x[2] + x[3] for x in rows) or 1
    print(f"{'statement':20s} {'calls':>8s} {'exec ms':>9s} {'plan ms':>8s} {'share':>6s} {'us/call':>8s}"
          f" {'blocks/call':>11s} {'rows/call':>9s}")
    for n, c, ex, pl, r, hit, rd in sorted(rows, key=lambda x: -(x[2] + x[3])):
        print(f"{n:20s} {c:8d} {ex:9.0f} {pl:8.0f} {100 * (ex + pl) / total:5.1f}% {1000 * (ex + pl) / c:8.0f}"
              f" {(hit + rd) / c:11.0f} {r / c:9.1f}")
    print(f"total {total:.0f} ms in statements; blocks read from outside shared_buffers: {sum(x[6] for x in rows)}")


if __name__ == "__main__":
    main()
