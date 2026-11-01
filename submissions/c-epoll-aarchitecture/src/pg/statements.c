#include "pg/statements.h"

/* timestamps as epoch microseconds (int8): to_char per row is expensive and
 * the C side formats. exact decomposition: days via date difference plus the
 * within-day interval's components -- extract(epoch) is double and lossy at
 * microsecond precision, extract(second) is numeric and exact */
#define TS(col) \
    "(((" col " AT TIME ZONE 'UTC')::date - DATE '1970-01-01') * 86400000000::bigint" \
    " + (extract(hour from (" col " AT TIME ZONE 'UTC') - date_trunc('day', " col " AT TIME ZONE 'UTC')) * 3600000000" \
    " + extract(minute from (" col " AT TIME ZONE 'UTC') - date_trunc('day', " col " AT TIME ZONE 'UTC')) * 60000000" \
    " + extract(second from (" col " AT TIME ZONE 'UTC') - date_trunc('day', " col " AT TIME ZONE 'UTC')) * 1000000)::bigint)"

/* request row for batched reads: i routes rows back; v/l/o/k =
 * viewer/limit/offset/key */
#define U "unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[], $5::text[]) AS r(i, v, l, o, k)"

/* the merged list statement's request rows add the kind branch */
#define U6 \
    "unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[], $5::text[], $6::int4[]) AS r(i, v, l, o, k, t)"

#define SLUGIFY(x) "trim(both '-' from lower(regexp_replace(" x ", '[^A-Za-z0-9]+', '-', 'g')))"

/* tag names via tags_pkey per link (the generic plan hash-joins the tag
 * table) */
#define TAG_NAMES \
    "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id)\n" \
    "              FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list"

/* count via PK probe, not a per-request EXISTS */
#define FAV_COUNT \
    "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count"
#define FAVORITED_BY(v) \
    "(SELECT true FROM favorites f WHERE f.user_id = " v " AND f.article_id = a.id) IS NOT NULL AS favorited"
#define FOLLOWING_BY(v) \
    "(SELECT true FROM follows fo WHERE fo.follower_id = " v " AND fo.followee_id = a.author_id) IS NOT NULL AS following"
#define FAVORITED FAVORITED_BY("r.v")
#define FOLLOWING FOLLOWING_BY("r.v")

/* list decoration minus viewer flags, once per distinct article */
#define LIST_ENRICH \
    "a.id, a.author_id, a.slug, a.title, a.description, " \
    TS("a.created_at") " AS created_at, " TS("a.updated_at") " AS updated_at, " \
    TAG_NAMES ", " FAV_COUNT ", u.username, u.bio, u.image"

/* full article cols 0..13: list prefix + body at 4 */
#define FULL_COLS \
    "a.id, a.slug, a.title, a.description, a.body, " TS("a.created_at") ", " \
    TS("a.updated_at") ", " TAG_NAMES ", " FAV_COUNT ", " FAVORITED ", " \
    "u.username, u.bio, u.image, " FOLLOWING

/* page cut in the subquery before decoration; count once per distinct key,
 * same snapshot */
#define COUNT_ALL \
    "CASE WHEN EXISTS (SELECT 1 FROM articles c ORDER BY c.id OFFSET 999)\n" \
    "          THEN 1000::bigint\n" \
    "          ELSE (SELECT count(*) FROM articles c) END"
#define COUNT_TAG \
    "CASE WHEN EXISTS (SELECT 1 FROM article_tags c\n" \
    "               WHERE c.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.k)\n" \
    "               OFFSET 999 LIMIT 1) THEN 1000::bigint\n" \
    "          ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags c\n" \
    "               WHERE c.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.k)\n" \
    "               LIMIT 1000) s) END"
#define COUNT_AUTHOR \
    "(SELECT count(*) FROM (SELECT 1 FROM articles c\n" \
    "   WHERE c.author_id = (SELECT u.id FROM users u WHERE u.username = r.k)\n" \
    "   LIMIT 1000) s)"
#define COUNT_FAVORITED \
    "(SELECT count(*) FROM (SELECT 1 FROM favorites c\n" \
    "   WHERE c.user_id = (SELECT u.id FROM users u WHERE u.username = r.k)\n" \
    "   LIMIT 1000) s)"

/* ONE statement for every list-shaped read: all/tag/author/favorited/feed
 * branch per request on r.t. pages cut ids per kind (a kind absent from the
 * batch costs nothing); ONE artx enrichment covers the union of all kinds'
 * ids -- the cross-endpoint dedup; counts once per (kind, key); feed counts
 * once per viewer. feed following is constant true */
#define LIST_ONE \
    "WITH req AS (SELECT * FROM " U6 "),\n" \
    "     reqs AS MATERIALIZED (\n" \
    "       SELECT r.i, r.v, r.l, r.o, COALESCE(r.k, '') AS key, r.t,\n" \
    "              GREATEST(r.l + r.o, 1) AS depth\n" \
    "       FROM req r),\n" \
    "     pages0 AS MATERIALIZED (\n" \
    "       SELECT r.i, r.v AS viewer, 0 AS t, ''::text AS key, p.id\n" \
    "         FROM (SELECT * FROM req WHERE t = 0) r\n" \
    "         LEFT JOIN (SELECT k.l, k.o, x.id\n" \
    "                      FROM (SELECT DISTINCT l, o FROM req WHERE t = 0) k\n" \
    "                      CROSS JOIN LATERAL (SELECT a.id FROM articles a\n" \
    "                        ORDER BY a.id DESC LIMIT k.l OFFSET k.o) x) p\n" \
    "           ON p.l = r.l AND p.o = r.o),\n" \
    "     pages1 AS MATERIALIZED (\n" \
    "       SELECT r.i, r.v AS viewer, 1 AS t, r.key, x.id\n" \
    "         FROM (SELECT * FROM reqs WHERE t = 1) r\n" \
    "         LEFT JOIN LATERAL (SELECT at.article_id AS id FROM article_tags at\n" \
    "           WHERE at.tag_id = (SELECT tu.id FROM tags tu WHERE tu.name = r.key)\n" \
    "           ORDER BY at.article_id DESC LIMIT r.l OFFSET r.o) x ON true),\n" \
    "     pages2 AS MATERIALIZED (\n" \
    "       SELECT r.i, r.v AS viewer, 2 AS t, r.key, x.id\n" \
    "         FROM (SELECT * FROM reqs WHERE t = 2) r\n" \
    "         LEFT JOIN LATERAL (SELECT a.id FROM articles a\n" \
    "           WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = r.key)\n" \
    "           ORDER BY a.id DESC LIMIT r.l OFFSET r.o) x ON true),\n" \
    "     pages3 AS MATERIALIZED (\n" \
    "       SELECT r.i, r.v AS viewer, 3 AS t, r.key, x.id\n" \
    "         FROM (SELECT * FROM reqs WHERE t = 3) r\n" \
    "         LEFT JOIN LATERAL (SELECT f.article_id AS id FROM favorites f\n" \
    "           WHERE f.user_id = (SELECT fu2.id FROM users fu2 WHERE fu2.username = r.key)\n" \
    "           ORDER BY f.article_id DESC LIMIT r.l OFFSET r.o) x ON true),\n" \
    "     fu AS MATERIALIZED (\n" \
    "       SELECT r.v,\n" \
    "              ARRAY(SELECT fo.followee_id FROM follows fo\n" \
    "                     WHERE fo.follower_id = r.v) AS fids,\n" \
    "              COALESCE((SELECT max(q.depth) FROM reqs q\n" \
    "                         WHERE q.v = r.v AND q.t = 4), 1) AS depth\n" \
    "       FROM (SELECT DISTINCT v FROM req WHERE t = 4) r),\n" \
    "     hubs AS MATERIALIZED (\n" \
    "       SELECT h.fid,\n" \
    "              EXISTS (SELECT 1 FROM articles a\n" \
    "                       WHERE a.author_id = h.fid\n" \
    "                       ORDER BY a.id DESC LIMIT 1 OFFSET 999) AS capped,\n" \
    "              (SELECT a.id FROM articles a\n" \
    "                WHERE a.author_id = h.fid\n" \
    "                ORDER BY a.id DESC LIMIT 1 OFFSET h.depth - 1) AS floor_id\n" \
    "       FROM (SELECT f.fid, max(fu.depth) AS depth\n" \
    "               FROM fu, unnest(fu.fids) AS f(fid)\n" \
    "              GROUP BY f.fid HAVING count(*) >= 2\n" \
    "              ORDER BY count(*) DESC, f.fid LIMIT 16) h),\n" \
    "     capped_fids AS MATERIALIZED (\n" \
    "       SELECT ARRAY(SELECT fid FROM hubs WHERE capped) AS fids),\n" \
    "     cnt4 AS MATERIALIZED (\n" \
    "       SELECT fu.v AS vkey,\n" \
    "              CASE WHEN fu.fids && (SELECT fids FROM capped_fids)\n" \
    "                        THEN 1000::bigint\n" \
    "                   ELSE (SELECT count(*) FROM (SELECT 1 FROM articles c\n" \
    "                          WHERE c.author_id = ANY(fu.fids)\n" \
    "                          LIMIT 1000) s) END AS n\n" \
    "       FROM fu),\n" \
    "     cntl AS MATERIALIZED (\n" \
    "       SELECT r.t, r.k, CASE r.t\n" \
    "         WHEN 0 THEN " COUNT_ALL "\n" \
    "         WHEN 1 THEN " COUNT_TAG "\n" \
    "         WHEN 2 THEN " COUNT_AUTHOR "\n" \
    "         WHEN 3 THEN " COUNT_FAVORITED "\n" \
    "       END AS n\n" \
    "       FROM (SELECT DISTINCT t, key AS k FROM reqs WHERE t < 4) r),\n" \
    "     pages4 AS MATERIALIZED (\n" \
    "       SELECT r.i, r.v AS viewer, 4 AS t, r.v::text AS key, x.id\n" \
    "         FROM (SELECT * FROM reqs WHERE t = 4) r\n" \
    "         JOIN fu ON fu.v = r.v\n" \
    "         CROSS JOIN LATERAL (SELECT max(h.floor_id) AS floor_id\n" \
    "                               FROM hubs h\n" \
    "                              WHERE h.fid = ANY(fu.fids)) fl\n" \
    "         LEFT JOIN LATERAL (\n" \
    "           SELECT y.id FROM unnest(fu.fids) AS fid\n" \
    "           CROSS JOIN LATERAL (SELECT a2.id FROM articles a2\n" \
    "             WHERE a2.author_id = fid\n" \
    "               AND a2.id >= COALESCE(fl.floor_id, 0::bigint)\n" \
    "             ORDER BY a2.id DESC LIMIT GREATEST(r.l + r.o, 1)) y\n" \
    "           ORDER BY y.id DESC LIMIT r.l OFFSET r.o) x ON true),\n" \
    "     pages AS MATERIALIZED (\n" \
    "       SELECT * FROM pages0 UNION ALL SELECT * FROM pages1\n" \
    "       UNION ALL SELECT * FROM pages2 UNION ALL SELECT * FROM pages3\n" \
    "       UNION ALL SELECT * FROM pages4),\n" \
    "     artx AS MATERIALIZED (SELECT " LIST_ENRICH "\n" \
    "       FROM (SELECT DISTINCT id FROM pages WHERE id IS NOT NULL) ar\n" \
    "       CROSS JOIN LATERAL (SELECT x.* FROM articles x\n" \
    "         WHERE x.id = ar.id LIMIT 1) a\n" \
    "       CROSS JOIN LATERAL (SELECT x.username, x.bio, x.image FROM users x\n" \
    "         WHERE x.id = a.author_id LIMIT 1) u)\n" \
    "SELECT p.i, ax.id, ax.slug, ax.title, ax.description,\n" \
    "       ax.created_at, ax.updated_at, ax.tag_list, ax.favorites_count,\n" \
    "       CASE WHEN p.t = 4 THEN true\n" \
    "            ELSE (SELECT true FROM favorites f WHERE f.user_id = p.viewer\n" \
    "                  AND f.article_id = p.id) IS NOT NULL END AS favorited,\n" \
    "       ax.username, ax.bio, ax.image,\n" \
    "       CASE WHEN p.t = 4 THEN true\n" \
    "            ELSE (SELECT true FROM follows fo WHERE fo.follower_id = p.viewer\n" \
    "                  AND fo.followee_id = ax.author_id) IS NOT NULL END AS following,\n" \
    "       c.n AS articles_count\n" \
    "  FROM pages p\n" \
    "  LEFT JOIN (SELECT 4 AS t, vkey::text AS key, n FROM cnt4\n" \
    "             UNION ALL SELECT t, k, n FROM cntl) c\n" \
    "    ON c.t = p.t AND c.key = p.key\n" \
    "  LEFT JOIN artx ax ON ax.id = p.id\n" \
    "  ORDER BY p.i, p.id DESC"

/* feed pages: a viewer can follow hundreds of authors, so expand every followee
 * only under a floor. the top-16 followees shared by >=2 viewers in this batch
 * bound the scan: the highest per-hub floor is already deeper than the whole
 * page needs, so anything older cannot appear. counts keep the 1000 cap and
 * short-circuit when a followed author alone is capped */
const char *const PG_STMT_SQL[PG_STMT_COUNT] = {
    /* ON CONFLICT DO NOTHING: a duplicate registration must not abort the
     * write group */
    [PG_STMT_USERS_INSERT] =
        "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)\n"
        "ON CONFLICT DO NOTHING\n"
        "RETURNING id, username, email, bio, image\n",

    [PG_STMT_USERS_UPDATE] =
        "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),\n"
        "                 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio),\n"
        "                 image = COALESCE($6, image)\n"
        " WHERE id = $1\n"
        "RETURNING id, username, email, bio, image\n",

    /* $1 viewer, $2 username; lookup + write in one statement */
    [PG_STMT_FOLLOWS_INSERT] =
        "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),\n"
        "     w AS (INSERT INTO follows (follower_id, followee_id)\n"
        "           SELECT $1, t.id FROM t ON CONFLICT DO NOTHING)\n"
        "SELECT t.id, t.username, t.bio, t.image, true AS following FROM t\n",

    [PG_STMT_FOLLOWS_DELETE] =
        "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),\n"
        "     w AS (DELETE FROM follows fo USING t\n"
        "           WHERE fo.follower_id = $1 AND fo.followee_id = t.id)\n"
        "SELECT t.id, t.username, t.bio, t.image, false AS following FROM t\n",

    /* $1 author, $2 title, $3 desc, $4 body, $5 tagList: creates the article,
     * missing tags + links and returns FULL_COLS */
    [PG_STMT_ARTICLE_INSERT] =
        "WITH n AS (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id),\n"
        "     a AS (INSERT INTO articles (id, slug, author_id, title, description, body)\n"
        "           SELECT n.id, " SLUGIFY("$2") " || '-' || n.id, $1, $2, $3, $4\n"
        "             FROM n\n"
        "           RETURNING id, slug, title, description, body, created_at, updated_at, author_id),\n"
        "     e AS MATERIALIZED (SELECT id, name FROM tags WHERE name = ANY($5::text[])),\n"
        "     t AS (INSERT INTO tags (name)\n"
        "           SELECT x.name FROM (SELECT DISTINCT unnest($5::text[]) AS name) x\n"
        "           WHERE NOT EXISTS (SELECT 1 FROM e WHERE e.name = x.name)\n"
        "           ORDER BY x.name\n"
        "           ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name\n"
        "           RETURNING id, name),\n"
        "     g AS (SELECT id, name FROM e UNION ALL SELECT id, name FROM t),\n"
        "     l AS (INSERT INTO article_tags (article_id, tag_id)\n"
        "           SELECT a.id, g.id FROM a, g)\n"
        "SELECT a.id, a.slug, a.title, a.description, a.body,\n"
        "       " TS("a.created_at") ", " TS("a.updated_at") ",\n"
        "       ARRAY(SELECT g.name FROM g ORDER BY 1) AS tag_list,\n"
        "       0::int8 AS favorites_count, false AS favorited,\n"
        "       u.username, u.bio, u.image,\n"
        "       (SELECT true FROM follows fo\n"
        "         WHERE fo.follower_id = $1 AND fo.followee_id = $1) IS NOT NULL AS following\n"
        "  FROM a JOIN users u ON u.id = a.author_id\n",

    /* $1 viewer, $2 slug, $3 title, $4 desc, $5 body (NULL = unchanged);
     * RETURNING carries the new row so the response needs no read-back; w is
     * empty when the viewer is not the author (handler answers 403) */
    [PG_STMT_ARTICLE_UPDATE] =
        "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $2),\n"
        "     w AS (UPDATE articles a SET title = COALESCE($3, a.title),\n"
        "                 description = COALESCE($4, a.description),\n"
        "                 body = COALESCE($5, a.body),\n"
        "                 slug = CASE WHEN $3::text IS NULL THEN a.slug\n"
        "                             ELSE " SLUGIFY("$3") " || '-' || a.id END,\n"
        "                 updated_at = now()\n"
        "           FROM t WHERE a.id = t.id AND t.author_id = $1\n"
        "           RETURNING a.id, a.slug, a.title, a.description, a.body,\n"
        "                     a.created_at, a.updated_at)\n"
        "SELECT w.id, w.slug, w.title, w.description, w.body,\n"
        "       " TS("w.created_at") ", " TS("w.updated_at") ",\n"
        "       " TAG_NAMES ", " FAV_COUNT ", " FAVORITED_BY("$1") ",\n"
        "       u.username, u.bio, u.image, " FOLLOWING_BY("$1") "\n"
        "  FROM t\n"
        "  JOIN articles a ON a.id = t.id\n"
        "  JOIN users u ON u.id = a.author_id\n"
        "  LEFT JOIN w ON true\n",

    [PG_STMT_ARTICLE_DELETE] =
        "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $2),\n"
        "     w AS (DELETE FROM articles a USING t\n"
        "           WHERE a.id = t.id AND t.author_id = $1)\n"
        "SELECT t.author_id FROM t\n",

    /* favorite writes return the full article: the count is the pre-write
     * snapshot plus/minus the row this statement actually inserted/deleted
     * (same-snapshot CTEs cannot see the write), favorited is literal */
    [PG_STMT_FAVORITES_INSERT] =
        "WITH t AS (SELECT id FROM articles WHERE slug = $2),\n"
        "     n AS (SELECT count(*) AS c FROM favorites f\n"
        "           WHERE f.article_id = (SELECT id FROM t)),\n"
        "     w AS (INSERT INTO favorites (user_id, article_id)\n"
        "           SELECT $1, t.id FROM t ON CONFLICT DO NOTHING\n"
        "           RETURNING article_id)\n"
        "SELECT a.id, a.slug, a.title, a.description, a.body,\n"
        "       " TS("a.created_at") ", " TS("a.updated_at") ",\n"
        "       " TAG_NAMES ",\n"
        "       n.c + (SELECT count(*) FROM w) AS favorites_count,\n"
        "       true AS favorited,\n"
        "       u.username, u.bio, u.image, " FOLLOWING_BY("$1") "\n"
        "  FROM t\n"
        "  JOIN articles a ON a.id = t.id\n"
        "  JOIN users u ON u.id = a.author_id\n"
        "  CROSS JOIN n\n",

    [PG_STMT_FAVORITES_DELETE] =
        "WITH t AS (SELECT id FROM articles WHERE slug = $2),\n"
        "     n AS (SELECT count(*) AS c FROM favorites f\n"
        "           WHERE f.article_id = (SELECT id FROM t)),\n"
        "     w AS (DELETE FROM favorites f USING t\n"
        "           WHERE f.user_id = $1 AND f.article_id = t.id\n"
        "           RETURNING f.article_id)\n"
        "SELECT a.id, a.slug, a.title, a.description, a.body,\n"
        "       " TS("a.created_at") ", " TS("a.updated_at") ",\n"
        "       " TAG_NAMES ",\n"
        "       n.c - (SELECT count(*) FROM w) AS favorites_count,\n"
        "       false AS favorited,\n"
        "       u.username, u.bio, u.image, " FOLLOWING_BY("$1") "\n"
        "  FROM t\n"
        "  JOIN articles a ON a.id = t.id\n"
        "  JOIN users u ON u.id = a.author_id\n"
        "  CROSS JOIN n\n",

    /* $1 viewer, $2 slug, $3 body; article lookup + insert in one statement */
    [PG_STMT_COMMENTS_INSERT] =
        "WITH t AS (SELECT id FROM articles WHERE slug = $2),\n"
        "     c AS (INSERT INTO comments (article_id, author_id, body)\n"
        "           SELECT t.id, $1, $3 FROM t\n"
        "           RETURNING id, body, created_at, updated_at, author_id)\n"
        "SELECT c.id, c.body, " TS("c.created_at") ", " TS("c.updated_at") ",\n"
        "       u.username, u.bio, u.image\n"
        "  FROM c JOIN users u ON u.id = c.author_id\n",

    /* $1 viewer, $2 slug, $3 comment id */
    [PG_STMT_COMMENTS_DELETE] =
        "WITH t AS (SELECT c.id, c.author_id FROM comments c\n"
        "           JOIN articles a ON a.id = c.article_id\n"
        "           WHERE c.id = $3 AND a.slug = $2),\n"
        "     w AS (DELETE FROM comments c USING t\n"
        "           WHERE c.id = t.id AND t.author_id = $1)\n"
        "SELECT t.author_id FROM t\n",
};

const unsigned char PG_STMT_PARAM_COUNT[PG_STMT_COUNT] = {
    [PG_STMT_USERS_INSERT] = 3,
    [PG_STMT_USERS_UPDATE] = 6,
    [PG_STMT_FOLLOWS_INSERT] = 2,
    [PG_STMT_FOLLOWS_DELETE] = 2,
    [PG_STMT_ARTICLE_INSERT] = 5,
    [PG_STMT_ARTICLE_UPDATE] = 5,
    [PG_STMT_ARTICLE_DELETE] = 2,
    [PG_STMT_FAVORITES_INSERT] = 2,
    [PG_STMT_FAVORITES_DELETE] = 2,
    [PG_STMT_COMMENTS_INSERT] = 3,
    [PG_STMT_COMMENTS_DELETE] = 3,
};

/* keep user update alone: a 23505 must reach exactly one request */
const unsigned char PG_STMT_SOLO[PG_STMT_COUNT] = {
    [PG_STMT_USERS_UPDATE] = 1,
};

const char *const PG_READ_SQL[PG_READ_COUNT] = {
    /* one execution broadcast to every waiting tags request; the array keeps it
     * to one row */
    [PG_READ_TAGS] =
        "SELECT ARRAY(SELECT t.name FROM tags t ORDER BY t.name)\n",

    [PG_READ_ARTICLE_SLUG] =
        "SELECT r.i, x.* FROM " U "\n"
        "  CROSS JOIN LATERAL (SELECT " FULL_COLS "\n"
        "    FROM articles a JOIN users u ON u.id = a.author_id\n"
        "    WHERE a.slug = r.k) x\n"
        "  ORDER BY r.i\n",

    /* no row = no article; one NULL-id row = article w/o comments. viewer's
     * followees read once per request */
    [PG_READ_COMMENTS] =
        "SELECT r.i, x.* FROM " U "\n"
        "  CROSS JOIN LATERAL (\n"
        "    SELECT c.id, c.body, " TS("c.created_at") " AS created_at,\n"
        "           " TS("c.updated_at") " AS updated_at,\n"
        "           u.username, u.bio, u.image,\n"
        "           c.author_id = ANY (f.ids) AS following\n"
        "      FROM articles a\n"
        "      CROSS JOIN LATERAL (SELECT ARRAY(SELECT fo.followee_id FROM follows fo\n"
        "                                       WHERE fo.follower_id = r.v) AS ids) f\n"
        "      LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id\n"
        "                         FROM comments c WHERE c.article_id = a.id\n"
        "                         ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true\n"
        "      LEFT JOIN users u ON u.id = c.author_id\n"
        "     WHERE a.slug = r.k\n"
        "     ORDER BY c.created_at DESC, c.id DESC) x\n"
        "  ORDER BY r.i, x.created_at DESC, x.id DESC\n",

    [PG_READ_PROFILE] =
        "SELECT r.i, x.* FROM " U "\n"
        "  CROSS JOIN LATERAL (SELECT u.id, u.username, u.bio, u.image,\n"
        "    (SELECT true FROM follows fo WHERE fo.follower_id = r.v\n"
        "      AND fo.followee_id = u.id) IS NOT NULL AS following\n"
        "    FROM users u WHERE u.username = r.k) x\n"
        "  ORDER BY r.i\n",

    [PG_READ_USER_ID] =
        "SELECT r.i, x.* FROM " U "\n"
        "  CROSS JOIN LATERAL (SELECT u.id, u.username, u.email, u.bio, u.image\n"
        "    FROM users u WHERE u.id = r.v) x\n"
        "  ORDER BY r.i\n",

    [PG_READ_USER_EMAIL] =
        "SELECT r.i, x.* FROM " U "\n"
        "  CROSS JOIN LATERAL (SELECT u.id, u.username, u.email, u.bio, u.image,\n"
        "    u.password_hash FROM users u WHERE u.email = r.k) x\n"
        "  ORDER BY r.i\n",

    [PG_READ_LIST] = LIST_ONE,
};

const unsigned char PG_READ_PARAM_COUNT[PG_READ_COUNT] = {
    [PG_READ_TAGS] = 0,
    [PG_READ_ARTICLE_SLUG] = 5,
    [PG_READ_COMMENTS] = 5,
    [PG_READ_PROFILE] = 5,
    [PG_READ_USER_ID] = 5,
    [PG_READ_USER_EMAIL] = 5,
    [PG_READ_LIST] = 6,
};

/* session-only planner settings: generic plans skip replanning batched stmts;
 * no parallel gather preserves unnest order (rows route by r.i); memoize would
 * cache another request's probes */
const char *const PG_SESSION_INIT =
    "SET plan_cache_mode = force_generic_plan; SET jit = off; "
    "SET max_parallel_workers_per_gather = 0; SET enable_memoize = off; "
    "SET work_mem = '32MB'; SET random_page_cost = 1.1; "
    "SET effective_io_concurrency = 200";
