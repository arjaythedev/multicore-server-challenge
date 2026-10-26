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
    [S_ARTICLE_BY_CURRVAL] = {FULL_SELECT "WHERE a.id = " CURRVAL, 1, 14, {I8}, FULL_COLTYPES},

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
};

const char *const stmt_names[S_COUNT] = {
    "s0",  "s1",  "s2",  "s3",  "s4",  "s5",  "s6",  "s7",  "s8",  "s9",  "s10", "s11",
    "s12", "s13", "s14", "s15", "s16", "s17", "s18", "s19", "s20", "s21", "s22", "s23",
    "s24", "s25", "s26", "s27", "s28", "s29", "s30", "s31", "s32", "s33", "s34",
};
_Static_assert(S_COUNT == 35, "update stmt_names");

const char *const session_sql[] = {
    "SET plan_cache_mode = force_generic_plan",
    "SET jit = off",
    "SET max_parallel_workers_per_gather = 0",
    NULL,
};
