#!/usr/bin/env python3
"""Check emitted batch SQL against independent per-request SQL oracles.

Build the application first. DATABASE_URL must select a disposable nc_batch_*
database owned by the test user: this command replaces its Conduit rows. The
fixed challenge schema is loaded only when absent. Requires Python 3 + psql;
there are no Python package dependencies or PostgreSQL extension requirements.

Example (with libpq PG* environment already selecting a test server):
  createdb nc_batch_validation
  DATABASE_URL='dbname=nc_batch_validation' python3 tests/batch_sql.py
  dropdb nc_batch_validation
"""

import argparse
import ast
from collections import defaultdict
import json
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = ROOT.parents[1]
MAX_OFFSET = 9223372036854775807
CHECKS = 0


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def vector(values, *, text=False):
    values = [literal(value) if text else str(value) for value in values]
    return "ARRAY[" + ",".join(values) + "]::" + ("text[]" if text else "bigint[]")


def equal(label, actual, expected):
    global CHECKS
    if actual != expected:
        raise AssertionError(
            f"{label}\nExpected: {repr(expected)[:2400]}\nActual: {repr(actual)[:2400]}")
    CHECKS += 1


def emitted_queries(path):
    """Read the actual fixed SQL literals after Nelua compile-time expansion.

    The query-shape selectors identify families, not expected query results.
    Refuse missing/ambiguous families instead of silently running another SQL
    implementation or treating a changed compiler output format as a pass.
    """
    if not path.is_file():
        raise RuntimeError(f"Generated C not found at {path}; run bash build.sh first")
    pattern = r'static(?: const)? char \w+\[\d+\]\s*=\s*("(?:[^"\\]|\\.)*");'
    found = {}
    for match in re.finditer(pattern, path.read_text()):
        sql = ast.literal_eval(match.group(1))
        if "page_keys AS MATERIALIZED" in sql:
            if "WHERE fo.follower_id=k.owner" in sql or "hub_floors AS MATERIALIZED" in sql:
                family = "feed"
            elif "FROM public.article_tags x WHERE x.tag_id=f.id" in sql:
                family = "tag"
            elif "FROM public.articles a WHERE a.author_id=f.id" in sql:
                family = "author"
            elif "FROM public.favorites x WHERE x.user_id=f.id" in sql:
                family = "favorited"
            else:
                family = "global"
        elif "profiles AS MATERIALIZED" in sql:
            family = "profile"
        elif "targets AS MATERIALIZED" in sql and "comments AS MATERIALIZED" in sql:
            family = "comments"
        elif "incoming AS MATERIALIZED" in sql and "articles AS MATERIALIZED" in sql:
            family = "article"
        else:
            continue
        if family in found and found[family] != sql:
            raise RuntimeError(f"Ambiguous emitted SQL family: {family}")
        found[family] = sql
    expected = {"profile", "article", "comments", "global", "tag", "author", "favorited", "feed"}
    if set(found) != expected:
        raise RuntimeError(f"Expected eight emitted batch query families; found {sorted(found)}")
    return found


class Database:
    def __init__(self, executable, url):
        self.executable = executable
        self.url = url

    def execute(self, sql):
        proc = subprocess.run(
            [self.executable, "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-d", self.url],
            input="SET standard_conforming_strings=on; SET TimeZone='UTC'; SET jit=off;\n" + sql,
            text=True, encoding="utf-8", capture_output=True,
            env={**os.environ, "PGCLIENTENCODING": "UTF8"},
        )
        if proc.returncode:
            # Never print the command line: DATABASE_URL may contain credentials.
            raise RuntimeError(f"psql failed ({proc.returncode}): {proc.stderr.strip()}")
        return proc.stdout.strip()

    def rows(self, sql):
        return json.loads(self.execute(
            "SELECT coalesce(json_agg(row_to_json(r)),'[]'::json) FROM (" + sql + ") r;"))

    def prepared(self, sql, parameters):
        # Run the actual dollar-parameter SQL under the driver's generic-plan
        # contract. The outer JSON aggregate is only a lossless test transport.
        # PostgreSQL itself serializes native arrays, booleans and timestamps.
        wrapped = "SELECT coalesce(json_agg(row_to_json(r)),'[]'::json) FROM (" + sql + ") r"
        return json.loads(self.execute(
            "SET plan_cache_mode=force_generic_plan; PREPARE nc_batch_query AS " + wrapped +
            "; EXECUTE nc_batch_query(" + ",".join(parameters) + ");"))

    def reset_fixture(self):
        info = json.loads(self.execute("SELECT json_build_object('database',current_database(),"
                                       "'users',to_regclass('public.users')::text);"))
        if not info["database"].startswith("nc_batch_"):
            raise RuntimeError("Fixture reset refused: database name must start with nc_batch_")
        if info["users"] is None:
            self.execute((REPOSITORY / "schema.sql").read_text())
        self.execute((ROOT / "tests/batch_fixture.sql").read_text())


def profile_fields(alias, viewer):
    return (f"{alias}.username,{alias}.bio,{alias}.image,"
            f"EXISTS(SELECT 1 FROM public.follows f WHERE f.follower_id={viewer} "
            f"AND f.followee_id={alias}.id) AS following")


def article_fields(viewer, *, full=False):
    body = "a.body," if full else ""
    return f"""a.slug,a.title,a.description,{body}a.created_at,a.updated_at,
      ARRAY(SELECT t.name FROM public.article_tags x JOIN public.tags t ON t.id=x.tag_id
             WHERE x.article_id=a.id ORDER BY t.name) AS tag_list,
      (SELECT count(*) FROM public.favorites f WHERE f.article_id=a.id) AS favorites_count,
      EXISTS(SELECT 1 FROM public.favorites f WHERE f.article_id=a.id
              AND f.user_id={viewer}) AS favorited,
      {profile_fields('u',viewer)}"""


def article_oracle(db, slug, viewer):
    rows = db.rows(f"SELECT {article_fields(viewer,full=True)} FROM public.articles a "
                   f"JOIN public.users u ON u.id=a.author_id WHERE a.slug={literal(slug)}")
    return rows[0] if rows else None


def comments_oracle(db, slug, viewer):
    target = db.rows("SELECT id FROM public.articles WHERE slug=" + literal(slug))
    if not target:
        return None
    return db.rows(f"""SELECT c.id,c.body,c.created_at,c.updated_at,{profile_fields('u',viewer)}
      FROM public.comments c JOIN public.users u ON u.id=c.author_id
     WHERE c.article_id={target[0]['id']}
     ORDER BY c.created_at DESC,c.id DESC LIMIT 100""")


def page_oracle(db, family, key, viewer, limit, offset):
    # Independent direct-WHERE reference: no batch page/count-key CTEs, shared
    # enrichment, request ordinals, or lateral feed merge from the implementation.
    where = "true"
    if family == "tag":
        where = ("a.id IN (SELECT x.article_id FROM public.article_tags x "
                 "JOIN public.tags t ON t.id=x.tag_id WHERE t.name=" + literal(key) + ")")
    elif family == "author":
        where = "u.username=" + literal(key)
    elif family == "favorited":
        where = ("a.id IN (SELECT x.article_id FROM public.favorites x "
                 "JOIN public.users fu ON fu.id=x.user_id WHERE fu.username=" + literal(key) + ")")
    elif family == "feed":
        where = ("a.author_id IN (SELECT followee_id FROM public.follows "
                 "WHERE follower_id=" + str(viewer) + ")")
    source = " FROM public.articles a JOIN public.users u ON u.id=a.author_id WHERE " + where
    rows = db.rows("SELECT " + article_fields(viewer) + source +
                   f" ORDER BY a.id DESC LIMIT {limit} OFFSET {offset}")
    count = int(db.execute("SELECT count(*) FROM (SELECT 1" + source + " LIMIT 1000) capped;"))
    return {"articles": rows, "count": count}


def indexed_rows(rows, count):
    groups = defaultdict(list)
    for row in rows:
        groups[row["ordinal"]].append(row)
    equal("every request retains its own ordinal", set(groups), set(range(1, count + 1)))
    return groups


def lookup_checks(db, queries):
    keys, viewers = ["alice", "bob", "absent", "alice", "quo'te\\雪"], [1, 0, 1, 0, 1]
    groups = indexed_rows(db.prepared(queries["profile"],
                                     [vector(keys,text=True), vector(viewers)]), len(keys))
    for ordinal, (key, viewer) in enumerate(zip(keys,viewers),1):
        rows = groups[ordinal]
        equal("profile has one marker/result per request", len(rows), 1)
        actual = {k:v for k,v in rows[0].items() if k != "ordinal"} if rows[0]["username"] is not None else None
        expected = db.rows(f"SELECT {profile_fields('u',viewer)} FROM public.users u "
                           f"WHERE u.username={literal(key)}")
        equal(f"profile {key!r}, viewer={viewer}", actual, expected[0] if expected else None)

    keys, viewers = ["article-1", "article-2", "absent", "article-1", "article-1104"], [1,0,1,2,1]
    groups = indexed_rows(db.prepared(queries["article"],
                                     [vector(keys,text=True), vector(viewers)]), len(keys))
    for ordinal, (key, viewer) in enumerate(zip(keys,viewers),1):
        rows = groups[ordinal]
        equal("article has one marker/result per request", len(rows), 1)
        actual = {k:v for k,v in rows[0].items() if k != "ordinal"} if rows[0]["slug"] is not None else None
        equal(f"article {key}, viewer={viewer}", actual, article_oracle(db,key,viewer))

    keys, viewers = ["article-1", "article-2", "absent", "article-1"], [1,0,1,2]
    groups = indexed_rows(db.prepared(queries["comments"],
                                     [vector(keys,text=True), vector(viewers)]), len(keys))
    for ordinal, (key, viewer) in enumerate(zip(keys,viewers),1):
        rows = groups[ordinal]
        actual = None if rows[0]["article_id"] is None else [
            {k:v for k,v in row.items() if k not in ("ordinal","article_id")}
            for row in rows if row["id"] is not None]
        equal(f"comments {key}, viewer={viewer}", actual, comments_oracle(db,key,viewer))
    print("PASS: profile/article/comment batches, independent viewers, markers, UTF8/controls and newest100",flush=True)


def check_page_group(db, query, family, inputs):
    parameters = [vector([row[0] for row in inputs],text=True)] + [
        vector([row[column] for row in inputs]) for column in range(1,4)]
    groups = indexed_rows(db.prepared(query, parameters), len(inputs))
    for ordinal, arguments in enumerate(inputs,1):
        rows = groups[ordinal]
        equal("page count remains identical across its rows", len({row["n"] for row in rows}), 1)
        actual = {"articles": [
            {k:v for k,v in row.items() if k not in ("n","ordinal")}
            for row in rows if row["slug"] is not None], "count": rows[0]["n"]}
        equal(f"{family} page {arguments}", actual, page_oracle(db,family,*arguments))


def page_checks(db, queries):
    cases = {
        "global": [("",1,10,0),("",0,10,0),("",2,5,5),("",1,100,0),
                   ("",3,1,MAX_OFFSET),("",1,10,0)],
        "tag": [("alpha",1,10,0),("alpha",0,10,0),("secondary",1,7,9),("absent",2,5,0),
                ("quo'te\\雪",0,1,0),("alpha",2,10,MAX_OFFSET)],
        "author": [("alice",1,10,0),("bob",0,10,0),("alice",2,7,9),("absent",2,5,0),
                   ("quo'te\\雪",1,1,0)],
        "favorited": [("alice",1,10,0),("reader",0,10,0),("reader",1,1,1),("absent",2,5,0),
                      ("bob",1,1,0),("alice",2,10,MAX_OFFSET)],
        "feed": [("",1,10,0),("",2,10,0),("",1,7,9),("",3,100,0),
                 ("",1,100,MAX_OFFSET),("",1,10,0)],
    }
    count = 0
    for family, inputs in cases.items():
        check_page_group(db,queries[family],family,inputs)
        count += len(inputs)
        print(f"PASS: {family}, {len(inputs)} overlapping/missing/capped/huge-offset page requests",flush=True)
    equal("page request matrix remains complete", count, 29)


def feed_overlap_checks(db, query):
    # Distinct viewers share an author with 1100 articles. Keep extreme offsets
    # separate so they cannot disable all ordinary shared-author floor probes.
    groups = [
        [("",1,10,0),("",3,20,5),("",4,100,0)],
        [("",1,20,1000),("",3,1,1099),("",4,20,1000)],
        [("",1,1,MAX_OFFSET),("",3,10,MAX_OFFSET-5)],
    ]
    for inputs in groups:
        check_page_group(db,query,"feed",inputs)
    print("PASS: shared followees, capped counts, pages beyond 1000 and huge-offset fallback",flush=True)
    return sum(map(len,groups))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--generated-c", type=Path, default=ROOT/"build/app.c")
    parser.add_argument("--psql", default=os.environ.get("PSQL","psql"))
    args = parser.parse_args()
    url = os.environ.get("DATABASE_URL")
    if not url:
        parser.error("DATABASE_URL must select a disposable nc_batch_* test database")
    queries = emitted_queries(args.generated_c)
    db = Database(args.psql,url)
    db.reset_fixture()
    lookup_checks(db,queries)
    page_checks(db,queries)
    extra_pages = feed_overlap_checks(db,queries["feed"])
    print(f"PASS: {CHECKS} assertions; 14 lookup/comment and {29 + extra_pages} page requests match SQL oracles",flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError,subprocess.SubprocessError,ValueError,AssertionError,RuntimeError) as exc:
        print(f"FAIL: {exc}",file=sys.stderr)
        sys.exit(1)
