"""Every batched statement (pg_repository.BATCHED) must return, per request, the same bytes as its single statement.

    PYTHONPATH=. .venv/bin/python scripts/batchcheck.py [DATABASE_URL]

Builds units of random requests (anonymous and logged-in viewers, popular and unknown slugs, repeated keys, every
page offset the workload uses), runs each unit both ways on one connection and prints the mismatches (should be 0).
"""
import os
import random
import sys

import psycopg

from conduit_server.adapters.outbound import pg_repository as r


def main():
    url = sys.argv[1] if len(sys.argv) > 1 else os.getenv("DATABASE_URL", "postgres://conduit:conduit@127.0.0.1:5432/conduit_full")
    conn = psycopg.connect(url)
    r.configure_connection(conn)
    pg = conn.pgconn
    rnd = random.Random(7)
    viewers = [0] + [v for (v,) in conn.execute("SELECT id FROM users ORDER BY random() LIMIT 300")]
    # viewers who follow commenters / favorite listed articles, so the flags are true somewhere
    viewers += [v for (v,) in conn.execute(
        "SELECT DISTINCT fo.follower_id FROM follows fo JOIN (SELECT author_id FROM comments ORDER BY id DESC LIMIT 2000) c"
        " ON c.author_id = fo.followee_id LIMIT 100")]
    viewers += [v for (v,) in conn.execute(
        "SELECT DISTINCT f.user_id FROM favorites f WHERE f.article_id > (SELECT max(id) - 60 FROM articles) LIMIT 100")]
    # feed viewers: anonymous/unknown, users following nobody, users with small and large feeds
    followers = [0, -1] + viewers[1:150] + [v for (v,) in conn.execute(
        "SELECT follower_id FROM follows GROUP BY follower_id ORDER BY count(*) DESC LIMIT 30")]
    # author lists: prolific authors, random users, an unknown name
    names = [n for (n,) in conn.execute("SELECT u.username FROM users u JOIN articles a ON a.author_id = u.id"
                                        " GROUP BY u.username ORDER BY count(*) DESC LIMIT 20")]
    names += [n for (n,) in conn.execute("SELECT username FROM users ORDER BY random() LIMIT 60")] + ["no-such-user"]
    slugs = [s for (s,) in conn.execute("SELECT slug FROM articles ORDER BY id DESC LIMIT 200")]
    slugs += [s for (s,) in conn.execute("SELECT slug FROM articles ORDER BY random() LIMIT 200")]
    slugs += [s for (s,) in conn.execute(
        "SELECT a.slug FROM articles a JOIN comments c ON c.article_id = a.id GROUP BY a.slug HAVING count(*) > 20 LIMIT 50")]
    slugs += ["no-such-slug", 'odd"slug\\x', "ünïcode-slug"]

    def single(stmt, args):
        res = pg.exec_prepared(stmt.name, r._params(args), None, 1)
        assert res.status == r._TUPLES_OK, res.error_message
        return res.get_value(0, 0) if res.ntuples else None

    def batch(spec, argss):
        res = pg.exec_prepared(spec.stmt.name, r._params(spec.params(argss)), None, 1)
        assert res.status == r._TUPLES_OK, res.error_message
        assert res.ntuples == len(argss)
        return [res.get_value(i, 1) for i in range(res.ntuples)]

    gens = {
        r._LIST_NONE_JSON: lambda: (rnd.choice(viewers), rnd.choice([10, 10, 5, 20]),
                                    0 if rnd.random() < 0.5 else 10 * rnd.randint(1, 4)),
        r._LIST_FEED_JSON: lambda: (rnd.choice(followers), rnd.choice([10, 10, 5, 20]),
                                    0 if rnd.random() < 0.5 else 10 * rnd.randint(1, 4)),
        r._LIST_AUTHOR_JSON: lambda: (rnd.choice(viewers), rnd.choice(names), rnd.choice([10, 10, 5, 20]),
                                      0 if rnd.random() < 0.5 else 10 * rnd.randint(1, 4)),
        r._ARTICLE_BY_SLUG_JSON: lambda: (rnd.choice(viewers), rnd.choice(slugs)),
        r._COMMENTS_BY_SLUG_JSON: lambda: (rnd.choice(viewers), rnd.choice(slugs)),
    }
    total = bad = 0
    for stmt, gen in gens.items():
        spec = r.BATCHED[stmt.index]
        for size in (1, 2, 3, 8, 32, 100):
            for _ in range(6):
                argss = [gen() for _ in range(size)]
                if size > 2 and rnd.random() < 0.5:  # repeated keys
                    argss[1] = argss[0]
                got = batch(spec, argss)
                for args, body in zip(argss, got):
                    total += 1
                    want = single(stmt, args)
                    if body != want:
                        bad += 1
                        if bad <= 5:
                            print(f"MISMATCH {spec.stmt.sql[:40]!r} {args}\n  single: {want[:300] if want else want}"
                                  f"\n  batch:  {body[:300] if body else body}")
    print(f"{total} requests compared, {bad} mismatches")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
