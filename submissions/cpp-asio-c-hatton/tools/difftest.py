#!/usr/bin/env python3
"""Differential test: runs this server's list/article/comment statements and SPEC.md's reference SQL with the
same random parameters inside Postgres and compares the results row by row. Emits a psql script on stdout.

  print_sql > stmts.txt; python3 tools/difftest.py stmts.txt [iterations] | psql -d <a copy of conduit_seed>
"""
import sys

stmts = open(sys.argv[1]).read().split("\n\x1e\n")
N = int(sys.argv[2]) if len(sys.argv) > 2 else 300
(S_TAGS, S_REGISTER, S_LOGIN, S_USER, S_UPDATE_USER, S_PROFILE, S_FOLLOW, S_UNFOLLOW, S_LIST_ALL, S_LIST_ALL_DEEP,
 S_COUNT_ALL, S_LIST_TAG, S_COUNT_TAG, S_LIST_AUTHOR, S_LIST_AUTHOR_DEEP, S_COUNT_AUTHOR, S_LIST_FAV, S_COUNT_FAV,
 S_FEED, S_COUNT_FEED, S_ARTICLE_SLUG, S_ARTICLE_ID, S_ARTICLE_CURR, S_COMMENTS) = range(24)

LIST = """SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a JOIN users u ON u.id = a.author_id"""
FULL = LIST.replace("a.description,", "a.description, a.body,", 1)
REF = {
  "all": (LIST + " ORDER BY a.id DESC LIMIT $2 OFFSET $3", "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s", S_LIST_ALL),
  "tag": (LIST + " WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
          "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000) s", S_LIST_TAG),
  "author": (LIST + " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a.id DESC LIMIT $2 OFFSET $3",
             "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000) s", S_LIST_AUTHOR),
  "all_deep": (LIST + " ORDER BY a.id DESC LIMIT $2 OFFSET $3", "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s", S_LIST_ALL_DEEP),
  "author_deep": (LIST + " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a.id DESC LIMIT $2 OFFSET $3",
             "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000) s", S_LIST_AUTHOR_DEEP),
  "fav": (LIST + " WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
          "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000) s", S_LIST_FAV),
  "feed": (LIST + " WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
           "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s", S_FEED),
}
COLS = "(id, slug, title, description, created_at, updated_at, tag_list, favorites_count, favorited, username, bio, image, following)"
REF_ARTICLE = FULL + " WHERE a.slug = $4"
REF_COMMENTS = """SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following
  FROM comments c JOIN users u ON u.id = c.author_id
 WHERE c.article_id = (SELECT id FROM articles WHERE slug = $4) ORDER BY c.created_at DESC, c.id DESC LIMIT 100"""

def q(s):
    return "$sql$" + s + "$sql$"

out = ["SET jit = off;", "\\set ON_ERROR_STOP 1", "DO $do$", "DECLARE",
       "  v bigint; lim int; off bigint; tg text; au text; fu text; sl text; filt text; ref text; mine text;",
       "  refc bigint; minec bigint; bad int := 0; checks int := 0; k text;",
       "  sub text;",
       "BEGIN",
       f"  FOR i IN 1..{N} LOOP",
       "    v := 1 + floor(random() * 100000)::bigint;",
       "    lim := (ARRAY[1, 5, 10, 10, 10, 20, 100])[1 + floor(random() * 7)::int];",
       "    off := (ARRAY[0, 0, 0, 5, 10, 20, 40, 990, 100000])[1 + floor(random() * 9)::int];",
       "    SELECT name INTO tg FROM tags ORDER BY random() LIMIT 1;",
       "    SELECT u.username INTO au FROM users u WHERE u.id = (SELECT author_id FROM articles WHERE id >= 1 + floor(random() * 500000)::bigint ORDER BY id LIMIT 1);",
       "    SELECT username INTO fu FROM users WHERE id >= 1 + floor(random() * 100000)::bigint ORDER BY id LIMIT 1;",
       "    SELECT slug INTO sl FROM articles WHERE id >= (SELECT max(id) - 2000 FROM articles) + floor(random() * 2000)::bigint ORDER BY id LIMIT 1;",
       "    IF random() < 0.05 THEN v := 0; END IF;",
       ]
for name, (lst, cnt, mine_id) in REF.items():
    filt = {"all": "''", "all_deep": "''", "tag": "tg", "author": "au", "author_deep": "au", "fav": "fu", "feed": "''"}[name]
    if name == "feed":
        out.append("    IF v > 0 THEN")
    out += [
        f"    filt := {filt};",
        f"    sub := replace(replace(replace(replace({q(lst)}, '$4', quote_literal(filt)), '$3', off::text), '$2', lim::text), '$1', v::text);",
        f"    EXECUTE 'SELECT md5(coalesce(string_agg({COLS}::text, ''|'' ORDER BY rn), '''')) FROM (SELECT *, row_number() OVER () rn FROM (' || sub || ') q) z' INTO ref;",
        f"    sub := replace(replace(replace(replace({q(stmts[mine_id])}, '$4', quote_literal(filt)), '$3', off::text), '$2', lim::text), '$1', v::text);",
        f"    EXECUTE 'SELECT md5(coalesce(string_agg({COLS}::text, ''|'' ORDER BY rn), '''')) FROM (SELECT *, row_number() OVER () rn FROM (' || sub || ') q) z' INTO mine;",
        "    checks := checks + 1;",
        f"    IF ref IS DISTINCT FROM mine THEN bad := bad + 1; RAISE NOTICE 'MISMATCH {name}: v=% lim=% off=% filt=%', v, lim, off, filt; END IF;",
        f"    EXECUTE replace(replace({q(cnt)}, '$4', quote_literal(filt)), '$1', v::text) INTO refc;",
        f"    EXECUTE 'SELECT total FROM (' || sub || ') q LIMIT 1' INTO minec;",
        "    checks := checks + 1;",
        f"    IF minec IS NOT NULL AND minec <> refc THEN bad := bad + 1; RAISE NOTICE 'COUNT MISMATCH {name}: % vs %', minec, refc; END IF;",
    ]
    if name == "feed":
        out.append("    END IF;")
# article by slug and comments
out += [
    f"    sub := replace(replace({q(REF_ARTICLE)}, '$4', quote_literal(sl)), '$1', v::text);",
    f"    EXECUTE 'SELECT md5(coalesce(string_agg(q::text, ''|''), '''')) FROM (' || sub || ') q' INTO ref;",
    f"    sub := replace(replace({q(stmts[S_ARTICLE_SLUG])}, '$2', quote_literal(sl)), '$1', v::text);",
    f"    EXECUTE 'SELECT md5(coalesce(string_agg(q::text, ''|''), '''')) FROM (' || sub || ') q' INTO mine;",
    "    checks := checks + 1;",
    "    IF ref IS DISTINCT FROM mine THEN bad := bad + 1; RAISE NOTICE 'MISMATCH article: v=% slug=%', v, sl; END IF;",
    f"    sub := replace(replace({q(REF_COMMENTS)}, '$4', quote_literal(sl)), '$1', v::text);",
    f"    EXECUTE 'SELECT md5(coalesce(string_agg((id, body, created_at, updated_at, username, bio, image, following)::text, ''|'' ORDER BY rn), '''')) FROM (SELECT q0.*, row_number() OVER () rn FROM (' || sub || ') q0) q' INTO ref;",
    f"    sub := replace(replace({q(stmts[S_COMMENTS])}, '$2', quote_literal(sl)), '$1', v::text);",
    f"    EXECUTE 'SELECT md5(coalesce(string_agg((cid, body, created_at, updated_at, username, bio, image, following)::text, ''|'' ORDER BY rn), '''')) FROM (SELECT q0.*, row_number() OVER () rn FROM (' || sub || ') q0(aid, cid, body, created_at, updated_at, username, bio, image, following) WHERE cid IS NOT NULL) q' INTO mine;",
    "    checks := checks + 1;",
    "    IF ref IS DISTINCT FROM mine THEN bad := bad + 1; RAISE NOTICE 'MISMATCH comments: v=% slug=%', v, sl; END IF;",
    "  END LOOP;",
    "  RAISE NOTICE 'difftest: % checks, % mismatches', checks, bad;",
    "END",
    "$do$;",
]
print("\n".join(out))
