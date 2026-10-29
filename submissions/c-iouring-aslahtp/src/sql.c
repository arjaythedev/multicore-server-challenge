/* M4: the reference SQL from SPEC.md, statement for statement. Later milestones replace these with the rewritten
 * and batched forms; the reference versions are the baseline every change is diffed against. */
#include "sql.h"

#include "pg_wire.h"

#define I8 OID_INT8
#define I4 OID_INT4
#define T OID_TEXT
#define TZ OID_TIMESTAMPTZ
#define TA OID_TEXT_ARRAY
#define B OID_BOOL

#define ARTICLE_COLS(body)                                                                                  \
    "SELECT a.id, a.slug, a.title, a.description, " body "a.created_at, a.updated_at, "                     \
    "ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id "                             \
    "WHERE at.article_id = a.id ORDER BY t.name) AS tag_list, "                                             \
    "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, "                     \
    "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, "        \
    "u.username, u.bio, u.image, "                                                                          \
    "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following " \
    "FROM articles a JOIN users u ON u.id = a.author_id "

#define LIST_SELECT ARTICLE_COLS("")
#define FULL_SELECT ARTICLE_COLS("a.body, ")
#define LIST_COLTYPES {I8, T, T, T, TZ, TZ, TA, I8, B, T, T, T, B}
#define FULL_COLTYPES {I8, T, T, T, T, TZ, TZ, TA, I8, B, T, T, T, B}
#define SLUGIFY(x) "trim(both '-' from lower(regexp_replace(" x ", '[^A-Za-z0-9]+', '-', 'g')))"
#define CURRVAL "currval(pg_get_serial_sequence('articles', 'id'))"
#define I8A OID_INT8_ARRAY
#define LEAN_COLS "a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at"
#define LEAN_TYPES {I8, I8, I8, T, T, T, TZ, TZ}

const struct stmt_def stmts[S_COUNT] = {
    [S_TAGS] = {"SELECT name FROM tags ORDER BY name", 0, 1, {0}, {T}},

    [S_USER_INSERT] = {"INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) "
                       "RETURNING id, username, email, bio, image",
                       3, 5, {T, T, T}, {I8, T, T, T, T}},
    [S_USER_BY_EMAIL] = {"SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1",
                         1, 6, {T}, {I8, T, T, T, T, T}},
    [S_USER_BY_ID] = {"SELECT id, username, email, bio, image FROM users WHERE id = $1", 1, 5, {I8},
                      {I8, T, T, T, T}},
    [S_USER_UPDATE] = {"UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), "
                       "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), "
                       "image = COALESCE($6, image) WHERE id = $1 RETURNING id, username, email, bio, image",
                       6, 5, {I8, T, T, T, T, T}, {I8, T, T, T, T}},

    [S_PROFILE] = {"SELECT u.id, u.username, u.bio, u.image, "
                   "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) "
                   "AS following FROM users u WHERE u.username = $2",
                   2, 5, {I8, T}, {I8, T, T, T, B}},
    [S_USER_BY_NAME] = {"SELECT id, username, bio, image FROM users WHERE username = $1", 1, 4, {T},
                        {I8, T, T, T}},
    [S_FOLLOW] = {"INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING", 2, 0,
                  {I8, I8}, {0}},
    [S_UNFOLLOW] = {"DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2", 2, 0, {I8, I8}, {0}},

    [S_LIST_ALL] = {LIST_SELECT "ORDER BY a.id DESC LIMIT $2 OFFSET $3", 3, 13, {I8, I8, I8}, LIST_COLTYPES},
    [S_COUNT_ALL] = {"SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s", 0, 1, {0}, {I8}},
    [S_LIST_TAG] = {LIST_SELECT "WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = "
                                "(SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC "
                                "LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
                    4, 13, {I8, I8, I8, T}, LIST_COLTYPES},
    [S_COUNT_TAG] = {"SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = "
                     "(SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s",
                     1, 1, {T}, {I8}},
    [S_LIST_AUTHOR] = {LIST_SELECT "WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) "
                                   "ORDER BY a.id DESC LIMIT $2 OFFSET $3",
                       4, 13, {I8, I8, I8, T}, LIST_COLTYPES},
    [S_COUNT_AUTHOR] = {"SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = "
                        "(SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s",
                        1, 1, {T}, {I8}},
    [S_LIST_FAVORITED] = {LIST_SELECT "WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = "
                                      "(SELECT fu.id FROM users fu WHERE fu.username = $4) "
                                      "ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
                          4, 13, {I8, I8, I8, T}, LIST_COLTYPES},
    [S_COUNT_FAVORITED] = {"SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = "
                           "(SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s",
                           1, 1, {T}, {I8}},
    [S_FEED] = {LIST_SELECT "WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL "
                            "(SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id "
                            "ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x "
                            "WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
                3, 13, {I8, I8, I8}, LIST_COLTYPES},
    [S_COUNT_FEED] = {"SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN "
                      "(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s",
                      1, 1, {I8}, {I8}},

    [S_ARTICLE_BY_SLUG] = {FULL_SELECT "WHERE a.slug = $2", 2, 14, {I8, T}, FULL_COLTYPES},
    [S_ARTICLE_BY_ID] = {FULL_SELECT "WHERE a.id = $2", 2, 14, {I8, I8}, FULL_COLTYPES},

    /* POST /api/articles: these four run as one unit (one implicit transaction, ended by one Sync). The tag
     * statements and the read-back find the new row through currval, which is this session's own nextval. */
    [S_ARTICLE_INSERT] = {"INSERT INTO articles (id, slug, author_id, title, description, body) "
                          "SELECT n.id, " SLUGIFY("$2") " || '-' || n.id, $1, $2, $3, $4 "
                          "FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id",
                          4, 1, {I8, T, T, T}, {I8}},
    [S_TAGS_INSERT] = {"INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING",
                       1, 0, {TA}, {0}},
    [S_ARTICLE_TAGS_INSERT] = {"INSERT INTO article_tags (article_id, tag_id) SELECT " CURRVAL ", t.id "
                               "FROM tags t WHERE t.name = ANY($1::text[])",
                               1, 0, {TA}, {0}},
    /* currval is volatile: compared directly it would be re-evaluated per row (a scan of every article); as a
     * sub-select it runs once and the lookup uses the primary key. */
    [S_ARTICLE_BY_CURRVAL] = {FULL_SELECT "WHERE a.id = (SELECT " CURRVAL ")", 1, 14, {I8}, FULL_COLTYPES},

    [S_ARTICLE_OWNER] = {"SELECT id, author_id FROM articles WHERE slug = $1", 1, 2, {T}, {I8, I8}},
    [S_ARTICLE_UPDATE] = {"UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), "
                          "body = COALESCE($4, body), "
                          "slug = CASE WHEN $2::text IS NULL THEN slug ELSE " SLUGIFY("$2") " || '-' || id END, "
                          "updated_at = now() WHERE id = $1",
                          4, 0, {I8, T, T, T}, {0}},
    [S_ARTICLE_DELETE] = {"DELETE FROM articles WHERE id = $1", 1, 0, {I8}, {0}},
    [S_ARTICLE_ID] = {"SELECT id FROM articles WHERE slug = $1", 1, 1, {T}, {I8}},
    [S_FAVORITE] = {"INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING", 2, 0,
                    {I8, I8}, {0}},
    [S_UNFAVORITE] = {"DELETE FROM favorites WHERE user_id = $1 AND article_id = $2", 2, 0, {I8, I8}, {0}},

    [S_COMMENTS_BY_SLUG] = {"SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, "
                            "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 "
                            "AND fo.followee_id = c.author_id) AS following "
                            "FROM comments c JOIN users u ON u.id = c.author_id "
                            "WHERE c.article_id = (SELECT id FROM articles WHERE slug = $2) "
                            "ORDER BY c.created_at DESC, c.id DESC LIMIT 100",
                            2, 8, {I8, T}, {I8, T, TZ, TZ, T, T, T, B}},
    /* The slug lookup and the insert in one statement: no row back means no such article (404). */
    [S_COMMENT_INSERT] = {"WITH c AS (INSERT INTO comments (article_id, author_id, body) "
                          "SELECT a.id, $2, $3 FROM articles a WHERE a.slug = $1 "
                          "RETURNING id, body, created_at, updated_at, author_id) "
                          "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image "
                          "FROM c JOIN users u ON u.id = c.author_id",
                          3, 7, {T, I8, T}, {I8, T, TZ, TZ, T, T, T}},
    [S_COMMENT_OWNER] = {"SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id "
                         "WHERE c.id = $1 AND a.slug = $2",
                         2, 1, {I8, T}, {I8}},
    [S_COMMENT_DELETE] = {"DELETE FROM comments WHERE id = $1", 1, 0, {I8}, {0}},

    /* Writes that find their target themselves, so a request is one statement (plus its read-back) in one
     * round trip instead of a lookup, then a write. A missing target writes nothing and returns no row. */
    [S_FAVORITE_SLUG] = {"INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a "
                         "WHERE a.slug = $2 ON CONFLICT DO NOTHING",
                         2, 0, {I8, T}, {0}},
    [S_UNFAVORITE_SLUG] = {"DELETE FROM favorites WHERE user_id = $1 AND article_id = "
                           "(SELECT a.id FROM articles a WHERE a.slug = $2)",
                           2, 0, {I8, T}, {0}},
    [S_FOLLOW_NAME] = {"WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), "
                       "w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM u ON CONFLICT DO NOTHING) "
                       "SELECT username, bio, image FROM u",
                       2, 3, {I8, T}, {T, T, T}},
    [S_UNFOLLOW_NAME] = {"WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), "
                         "w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id IN (SELECT id FROM u)) "
                         "SELECT username, bio, image FROM u",
                         2, 3, {I8, T}, {T, T, T}},

    /* ---- the drain's planner (see planner.c). Every page statement returns lean article rows:
     * k, id, author_id, slug, title, description, created_at, updated_at; the page's ids are cut first from the
     * narrowest index, and only those rows are read from articles. Rows come back in any order; the planner
     * sorts each page by id. The constant LIMIT 100 around each page is a no-op (limit <= 100) that keeps the
     * generic plan's estimate small: LIMIT with a parameter is estimated at 10% of the rows, and 50,000 rows
     * per page would make it hash-join a scan of every article. */
    [P_GLOBAL_PAGES] = {"SELECT r.k, " LEAN_COLS " FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY r(lim, off, k) "
                        "CROSS JOIN LATERAL (SELECT z.id FROM (SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) z "
                        "LIMIT 100) p "
                        "JOIN articles a ON a.id = p.id",
                        2, 8, {I8A, I8A}, LEAN_TYPES},
    /* Walks the primary key from the oldest end: those pages are all-visible, so this stays an index-only scan
     * while new inserts keep the newest pages dirty. */
    [P_GLOBAL_COUNT] = {"SELECT count(*) FROM (SELECT 1 FROM articles a ORDER BY a.id LIMIT 1000) s", 0, 1, {0}, {I8}},
    [P_TAG_PAGES] = {"SELECT r.k, " LEAN_COLS " FROM unnest($1::text[], $2::int8[], $3::int8[]) WITH ORDINALITY "
                     "r(name, lim, off, k) CROSS JOIN LATERAL (SELECT z.id FROM (SELECT at.article_id AS id FROM article_tags at "
                     "WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.name) "
                     "ORDER BY at.article_id DESC LIMIT r.lim OFFSET r.off) z LIMIT 100) p JOIN articles a ON a.id = p.id",
                     3, 8, {TA, I8A, I8A}, LEAN_TYPES},
    [P_TAG_COUNTS] = {"SELECT r.k, (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = "
                      "(SELECT t.id FROM tags t WHERE t.name = r.name) LIMIT 1000) s) "
                      "FROM unnest($1::text[]) WITH ORDINALITY r(name, k)",
                      1, 2, {TA}, {I8, I8}},
    [P_AUTHOR_PAGES] = {"SELECT r.k, " LEAN_COLS " FROM unnest($1::text[], $2::int8[], $3::int8[]) WITH ORDINALITY "
                        "r(name, lim, off, k) CROSS JOIN LATERAL (SELECT z.id FROM (SELECT a2.id FROM articles a2 WHERE a2.author_id = "
                        "(SELECT u.id FROM users u WHERE u.username = r.name) "
                        "ORDER BY a2.id DESC LIMIT r.lim OFFSET r.off) z LIMIT 100) p JOIN articles a ON a.id = p.id",
                        3, 8, {TA, I8A, I8A}, LEAN_TYPES},
    [P_AUTHOR_COUNTS] = {"SELECT r.k, (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = "
                         "(SELECT u.id FROM users u WHERE u.username = r.name) LIMIT 1000) s) "
                         "FROM unnest($1::text[]) WITH ORDINALITY r(name, k)",
                         1, 2, {TA}, {I8, I8}},
    [P_FAV_PAGES] = {"SELECT r.k, " LEAN_COLS " FROM unnest($1::text[], $2::int8[], $3::int8[]) WITH ORDINALITY "
                     "r(name, lim, off, k) CROSS JOIN LATERAL (SELECT z.id FROM (SELECT f.article_id AS id FROM favorites f "
                     "WHERE f.user_id = (SELECT u.id FROM users u WHERE u.username = r.name) "
                     "ORDER BY f.article_id DESC LIMIT r.lim OFFSET r.off) z LIMIT 100) p JOIN articles a ON a.id = p.id",
                     3, 8, {TA, I8A, I8A}, LEAN_TYPES},
    [P_FAV_COUNTS] = {"SELECT r.k, (SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = "
                      "(SELECT u.id FROM users u WHERE u.username = r.name) LIMIT 1000) s) "
                      "FROM unnest($1::text[]) WITH ORDINALITY r(name, k)",
                      1, 2, {TA}, {I8, I8}},
    /* Feed counts and pages in one statement. Count rows: -k (k = the distinct viewer's ordinal in $1), then the
     * count, padding NULLs. Page rows: k (the request's ordinal in $2..$4) and lean article columns.
     *   hubs: followees that at least two viewers of the batch share (the 16 most shared) are looked at once.
     *     A hub with 1000+ articles proves the capped count (1000) of every viewer following it, with no
     *     counting. floor_id is the hub's article at the deepest page any of its followers needs: the hub alone
     *     has that many articles at or above it, so a page needs nothing older, and every followee's walk stops
     *     there.
     *   Pages: each followee contributes at most lim+off of its newest ids (from the (author_id, id) index)
     *     before the merge, so a prolific author costs no more than a quiet one. */
    [P_FEED] = {"WITH reqs AS MATERIALIZED (SELECT p.v, p.lim, p.off, p.lim + p.off AS depth, p.k "
                "FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY p(v, lim, off, k)), "
                "u AS MATERIALIZED (SELECT r.k, r.v, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v) AS fids, "
                "COALESCE((SELECT max(q.depth) FROM reqs q WHERE q.v = r.v), 1) AS depth "
                "FROM unnest($1::int8[]) WITH ORDINALITY r(v, k)), "
                "hubs AS MATERIALIZED (SELECT h.fid, "
                "EXISTS (SELECT 1 FROM articles a WHERE a.author_id = h.fid ORDER BY a.id DESC LIMIT 1 OFFSET 999) AS capped, "
                "(SELECT a.id FROM articles a WHERE a.author_id = h.fid ORDER BY a.id DESC LIMIT 1 OFFSET h.depth - 1) AS floor_id "
                "FROM (SELECT f.fid, max(u.depth) AS depth FROM u, unnest(u.fids) AS f(fid) "
                "GROUP BY f.fid HAVING count(*) >= 2 ORDER BY count(*) DESC, f.fid LIMIT 16) h), "
                "cap AS MATERIALIZED (SELECT ARRAY(SELECT fid FROM hubs WHERE capped) AS fids) "
                "SELECT -u.k, CASE WHEN u.fids && (SELECT fids FROM cap) THEN 1000::int8 "
                "ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = ANY (u.fids) LIMIT 1000) s) END, "
                "NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz FROM u "
                "UNION ALL "
                "SELECT p.k, " LEAN_COLS " FROM reqs p JOIN u ON u.v = p.v "
                "CROSS JOIN LATERAL (SELECT max(h.floor_id) AS floor_id FROM hubs h WHERE h.fid = ANY (u.fids)) fl "
                "CROSS JOIN LATERAL (SELECT z.id FROM (SELECT y.id FROM unnest(u.fids) AS f(fid) CROSS JOIN LATERAL "
                "(SELECT a2.id FROM articles a2 WHERE a2.author_id = f.fid AND a2.id >= COALESCE(fl.floor_id, 0) "
                "ORDER BY a2.id DESC LIMIT p.depth) y ORDER BY y.id DESC LIMIT p.lim OFFSET p.off) z LIMIT 100) x "
                "JOIN articles a ON a.id = x.id",
                4, 8, {I8A, I8A, I8A, I8A}, LEAN_TYPES},
    [P_ARTICLES] = {"SELECT r.k, " LEAN_COLS ", a.body FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) "
                    "JOIN articles a ON a.slug = r.slug",
                    1, 9, {TA}, {I8, I8, I8, T, T, T, TZ, TZ, T}},
    /* One row per comment (or one row with NULL comment columns: the article exists but has no comments). */
    [P_COMMENTS] = {"SELECT r.k, a.id, c.id, c.body, c.created_at, c.updated_at, c.author_id, c.username, c.bio, "
                    "c.image FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug "
                    "LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, "
                    "u.bio, u.image FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = a.id "
                    "ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true",
                    1, 10, {TA}, {I8, I8, I8, T, TZ, TZ, I8, T, T, T}},
    [P_PROFILES] = {"SELECT r.k, u.id, u.username, u.bio, u.image FROM unnest($1::text[]) WITH ORDINALITY "
                    "r(name, k) JOIN users u ON u.username = r.name",
                    1, 5, {TA}, {I8, I8, T, T, T}},
    /* Per distinct article: its tag ids (names come from P_TAGDICT, once per plan, instead of a tags lookup per
     * tag per article) and its favorites count. Authors are fetched once per distinct author (P_AUTHORS). */
    [P_ARTX] = {"SELECT r.id, ARRAY(SELECT at.tag_id FROM article_tags at WHERE at.article_id = r.id), "
                "(SELECT count(*) FROM favorites f WHERE f.article_id = r.id) FROM unnest($1::int8[]) r(id)",
                1, 3, {I8A}, {I8, OID_INT4_ARRAY, I8}},
    /* Every tag in name order (the database's collation, as ORDER BY name per article was): a tag's position is
     * its rank when an article's tags are put in order. 200 rows on 2 heap pages. Sent after P_ARTX in the same
     * pipeline: tags are never deleted, so every id P_ARTX returned is here. */
    [P_TAGDICT] = {"SELECT id, name FROM tags ORDER BY name", 0, 2, {0}, {I4, T}},
    [P_AUTHORS] = {"SELECT u.id, u.username, u.bio, u.image FROM unnest($1::int8[]) r(id) JOIN users u ON u.id = r.id",
                   1, 4, {I8A}, {I8, T, T, T}},
    /* Which (viewer, article) pairs are favorites and which (viewer, user) pairs are follows: one primary-key
     * range scan per viewer instead of one probe per article. */
    [P_FLAGS] = {"WITH p AS (SELECT v, array_agg(x) AS xs FROM unnest($1::int8[], $2::int8[]) t(v, x) GROUP BY v), "
                 "q AS (SELECT v, array_agg(x) AS xs FROM unnest($3::int8[], $4::int8[]) t(v, x) GROUP BY v) "
                 "SELECT 0::int8, p.v, f.article_id FROM p CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f "
                 "WHERE f.user_id = p.v AND f.article_id = ANY (p.xs)) f "
                 "UNION ALL SELECT 1::int8, q.v, fo.followee_id FROM q CROSS JOIN LATERAL (SELECT fo.followee_id "
                 "FROM follows fo WHERE fo.follower_id = q.v AND fo.followee_id = ANY (q.xs)) fo",
                 4, 3, {I8A, I8A, I8A, I8A}, {I8, I8, I8}},
};

char stmt_names[S_COUNT][8];

__attribute__((constructor)) static void name_stmts(void) {
    for (int i = 0; i < S_COUNT; i++) snprintf(stmt_names[i], sizeof stmt_names[i], "s%d", i);
}

/* Generic plans size hash aggregates and memoize caches for many keys; our statements group a few dozen rows. */
const char *const session_tune_sql[] = {
    "SET enable_memoize = off",
    "SET enable_hashagg = off",
    "SET work_mem = '32MB'",
    "SET random_page_cost = 1.1",
    NULL,
};
bool session_tune;

const char *const session_sql[] = {
    "SET plan_cache_mode = force_generic_plan",
    "SET jit = off",
    "SET max_parallel_workers_per_gather = 0",
    NULL,
};
