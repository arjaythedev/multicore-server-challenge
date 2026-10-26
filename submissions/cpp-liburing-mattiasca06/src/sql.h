// Statements, prepared once per connection. SQL follows the reference SQL in SPEC.md.
#pragma once

#define ARTICLE_PAGE_COLS "a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id "

// Pick the page of articles first, then compute tags, favorites and follows for just those rows.
#define ARTICLE_LIST(page)                                                                                            \
    "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, tg.tag_list, "                          \
    "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, "                               \
    "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, "                  \
    "u.username, u.bio, u.image, "                                                                                    \
    "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following "      \
    "FROM (" page ") a JOIN users u ON u.id = a.author_id "                                                           \
    "CROSS JOIN LATERAL (SELECT ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) "                     \
    "FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list) tg ORDER BY a.id DESC"

#define ARTICLE_FULL_SELECT ARTICLE_FULL_COLS "FROM articles a JOIN users u ON u.id = a.author_id "

#define ARTICLE_FULL_COLS                                                                                             \
    "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, "                               \
    "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at "                           \
    "WHERE at.article_id = a.id ORDER BY 1) AS tag_list, "                                                            \
    "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, "                               \
    "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, "                  \
    "u.username, u.bio, u.image, "                                                                                    \
    "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following "

// ---- batched read variants ----
// Requests that wait in the same read segment and ask the same kind of question go out as ONE statement: every
// parameter becomes an array and the result carries the request's position (ord, 1-based) as its first column, rows
// of one request contiguous and in the request's own order. Work that does not depend on the viewer (the page of
// articles with tags/counts/authors, the comments of a slug) is computed once per distinct page/slug inside this
// one execution; the per-viewer flags (favorited, following) are computed per request. Nothing outlives the execution.
#define REQ(types, cols) "WITH req AS (SELECT * FROM unnest(" types ") WITH ORDINALITY AS r(" cols ", ord)) "

#define TAG_LIST_COL                                                                                                  \
    "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at "                           \
    "WHERE at.article_id = a.id ORDER BY 1) AS tag_list"

// pages(d): the viewer-independent part of a list page. `d` yields one row per distinct page.
#define PAGE_BATCH(keys, from_where)                                                                                  \
    ", pg AS MATERIALIZED (SELECT d.*, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, "            \
    "a.author_id, " TAG_LIST_COL ", (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, " \
    "u.username, u.bio, u.image FROM (SELECT DISTINCT " keys " FROM req) d CROSS JOIN LATERAL ("                      \
    "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM articles a "           \
    from_where ") a JOIN users u ON u.id = a.author_id) "

#define PAGE_BATCH_OUT(join_on)                                                                                       \
    "SELECT r.ord::int4, pg.id, pg.slug, pg.title, pg.description, pg.created_at, pg.updated_at, pg.tag_list, "       \
    "pg.favorites_count, EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = pg.id AND f.user_id = r.v) AS "       \
    "favorited, pg.username, pg.bio, pg.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND "      \
    "fo.followee_id = pg.author_id) AS following FROM req r JOIN pg ON " join_on " ORDER BY r.ord, pg.id DESC"

// The home feed. Page ids: the newest (limit + offset) articles of every followee, merged and cut to the page. The
// page's tags, favorite counts and authors are fetched once per distinct article of the whole batch. `following` is
// always true (a feed only holds followed authors). The count is min(count, 1000); a page that ends before `limit`
// already tells the total, anything else counts through the follows (capped) in this same execution.
#define FEED(arrays, ord_col)                                                                                         \
    "WITH req AS (SELECT * FROM unnest(" arrays ") WITH ORDINALITY AS r(v, lm, ofs, ord)), "                          \
    "pages AS MATERIALIZED (SELECT r.ord, r.v, p.id FROM req r LEFT JOIN LATERAL ("                                   \
    "SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = "             \
    "fo.followee_id ORDER BY a2.id DESC LIMIT (r.lm + r.ofs)) x WHERE fo.follower_id = r.v "                          \
    "ORDER BY x.id DESC LIMIT r.lm OFFSET r.ofs) p ON true), "                                                        \
    "cnt AS MATERIALIZED (SELECT r.ord, CASE WHEN pc.k < r.lm AND (pc.k > 0 OR r.ofs = 0) THEN LEAST(1000, r.ofs + "  \
    "pc.k) ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM "    \
    "follows fo WHERE fo.follower_id = r.v) LIMIT 1000) s) END AS n FROM req r JOIN (SELECT ord, count(id) AS k "     \
    "FROM pages GROUP BY ord) pc ON pc.ord = r.ord), "                                                                \
    "ids AS MATERIALIZED (SELECT DISTINCT id FROM pages WHERE id IS NOT NULL), "                                      \
    "pt AS MATERIALIZED (SELECT at.article_id AS id, array_agg(t.name ORDER BY t.name) AS tag_list FROM ids i "       \
    "JOIN article_tags at ON at.article_id = i.id JOIN tags t ON t.id = at.tag_id GROUP BY at.article_id), "         \
    "e AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, "                    \
    "COALESCE(pt.tag_list, ARRAY[]::text[]) AS tag_list, "                                                            \
    "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, u.username, u.bio, u.image "    \
    "FROM ids i JOIN articles a ON a.id = i.id JOIN users u ON u.id = a.author_id LEFT JOIN pt ON pt.id = a.id) "     \
    "SELECT " ord_col "c.n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at, e.tag_list, "          \
    "e.favorites_count, (fv.user_id IS NOT NULL) AS favorited, e.username, e.bio, e.image, "                          \
    "(e.id IS NOT NULL) AS following FROM pages p JOIN cnt c ON c.ord = p.ord LEFT JOIN e ON e.id = p.id "            \
    "LEFT JOIN favorites fv ON fv.user_id = p.v AND fv.article_id = p.id ORDER BY p.ord, p.id DESC NULLS LAST"

#define SLUGIFY(x) "trim(both '-' from lower(regexp_replace(" x ", '[^A-Za-z0-9]+', '-', 'g')))"

struct Stmt {
    const char *name, *sql;
};

inline constexpr Stmt kStatements[] = {
    {"tags", "SELECT name FROM tags ORDER BY name"},
    {"user_register",
     "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image"},
    {"user_login", "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1"},
    {"user_by_id", "SELECT id, username, email, bio, image FROM users WHERE id = $1"},
    {"user_update",
     "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), "
     "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) "
     "WHERE id = $1 RETURNING id, username, email, bio, image"},
    {"profile",
     "SELECT u.id, u.username, u.bio, u.image, "
     "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following "
     "FROM users u WHERE u.username = $2"},
    {"user_by_name", "SELECT id, username, bio, image FROM users WHERE username = $1"},
    {"follow_add", "INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING"},
    {"follow_del", "DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2"},

    {"list_all",
     ARTICLE_LIST("SELECT " ARTICLE_PAGE_COLS "FROM articles a ORDER BY a.id DESC LIMIT $2 OFFSET $3")},
    {"count_all", "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s"},
    {"list_tag",
     ARTICLE_LIST("SELECT " ARTICLE_PAGE_COLS "FROM articles a WHERE a.id IN (SELECT at.article_id FROM article_tags at "
                  "WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) "
                  "ORDER BY at.article_id DESC LIMIT $2 OFFSET $3)")},
    {"count_tag",
     "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = "
     "(SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s"},
    {"list_author",
     ARTICLE_LIST("SELECT " ARTICLE_PAGE_COLS "FROM articles a "
                  "WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) "
                  "ORDER BY a.id DESC LIMIT $2 OFFSET $3")},
    {"count_author",
     "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = "
     "(SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s"},
    {"list_fav",
     ARTICLE_LIST("SELECT " ARTICLE_PAGE_COLS "FROM articles a WHERE a.id IN (SELECT f.article_id FROM favorites f "
                  "WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) "
                  "ORDER BY f.article_id DESC LIMIT $2 OFFSET $3)")},
    {"count_fav",
     "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = "
     "(SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s"},
    // The feed page and its capped count come back together: every row starts with the count (n), a viewer whose page is
    // empty gets one row with a NULL id. The single statement is the batched one with arrays of length one.
    {"feed", FEED("ARRAY[$1::bigint], ARRAY[$2::bigint], ARRAY[$3::bigint]", "")},

    {"article_by_slug", ARTICLE_FULL_SELECT "WHERE a.slug = $2"},
    {"article_by_id", ARTICLE_FULL_SELECT "WHERE a.id = $2"},
    {"article_nextval", "SELECT nextval(pg_get_serial_sequence('articles', 'id'))"},
    {"article_insert",
     "INSERT INTO articles (id, slug, author_id, title, description, body) "
     "VALUES ($1::bigint, " SLUGIFY("$2::text") " || '-' || $1::bigint, $3::bigint, $2::text, $4::text, $5::text)"},
    {"tags_insert", "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING"},
    {"article_tags_insert",
     "INSERT INTO article_tags (article_id, tag_id) SELECT $1::bigint, t.id FROM tags t WHERE t.name = ANY($2::text[])"},
    {"article_owner", "SELECT id, author_id FROM articles WHERE slug = $1"},
    {"article_update",
     "UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), "
     "body = COALESCE($4, body), slug = CASE WHEN $2::text IS NULL THEN slug ELSE " SLUGIFY("$2::text") " || '-' || id END, "
     "updated_at = now() WHERE id = $1"},
    {"article_delete", "DELETE FROM articles WHERE id = $1"},
    {"article_id", "SELECT id FROM articles WHERE slug = $1"},
    {"fav_add", "INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING"},
    {"fav_del", "DELETE FROM favorites WHERE user_id = $1 AND article_id = $2"},

    {"comments_list",
     "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, "
     "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following "
     "FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = $2 "
     "ORDER BY c.created_at DESC, c.id DESC LIMIT 100"},
    {"comment_insert",
     "WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3) "
     "RETURNING id, body, created_at, updated_at, author_id) "
     "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id"},
    {"comment_owner",
     "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2"},
    {"comment_delete", "DELETE FROM comments WHERE id = $1"},

    // ---- single-round-trip variants (lookup and action in one statement) ----
    {"follow_slug",  // $1 viewer, $2 username; one row (username, bio, image) if the user exists
     "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), "
     "i AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, t.id FROM t ON CONFLICT DO NOTHING) "
     "SELECT username, bio, image FROM t"},
    {"unfollow_slug",
     "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), "
     "d AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id IN (SELECT id FROM t)) "
     "SELECT username, bio, image FROM t"},
    {"article_update_full",  // $1 viewer(=author), $2 slug, $3 title, $4 description, $5 body; zero rows if not the author
     "WITH upd AS (UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description), "
     "body = COALESCE($5, body), slug = CASE WHEN $3::text IS NULL THEN slug ELSE " SLUGIFY("$3::text")
     " || '-' || id END, updated_at = now() WHERE slug = $2 AND author_id = $1 "
     "RETURNING id, slug, title, description, body, created_at, updated_at, author_id) "
     ARTICLE_FULL_COLS "FROM upd a JOIN users u ON u.id = a.author_id"},
    {"article_delete_slug",  // $1 slug, $2 viewer -> (deleted count, author_id or NULL if no such article)
     "WITH d AS (DELETE FROM articles WHERE slug = $1 AND author_id = $2 RETURNING 1) "
     "SELECT (SELECT count(*) FROM d), (SELECT author_id FROM articles WHERE slug = $1)"},
    {"fav_add_slug",
     "INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2 "
     "ON CONFLICT DO NOTHING"},
    {"fav_del_slug",
     "DELETE FROM favorites WHERE user_id = $1 AND article_id IN (SELECT id FROM articles WHERE slug = $2)"},
    {"comments_by_slug",  // $1 viewer, $2 slug; zero rows = no article, one row with NULL id = no comments
     "SELECT c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image, c.following "
     "FROM articles a LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, "
     "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following "
     "FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = a.id "
     "ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true WHERE a.slug = $2 "
     "ORDER BY c.created_at DESC NULLS LAST, c.id DESC"},
    {"comment_insert_slug",  // $1 slug, $2 author, $3 body; zero rows if no such article
     "WITH a AS (SELECT id FROM articles WHERE slug = $1), "
     "c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $2, $3 FROM a "
     "RETURNING id, body, created_at, updated_at, author_id) "
     "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id"},
    {"comment_delete_slug",  // $1 comment id, $2 slug, $3 viewer -> (deleted count, author_id or NULL if not found)
     "WITH d AS (DELETE FROM comments c USING articles a WHERE c.id = $1 AND a.id = c.article_id AND a.slug = $2 "
     "AND c.author_id = $3 RETURNING 1) "
     "SELECT (SELECT count(*) FROM d), (SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id "
     "WHERE c.id = $1 AND a.slug = $2)"},

    // Batched variants (see above). Same parameters as the single versions, each one an array.
    {"article_by_slug_b",  // v bigint[], slug text[]
     // One lateral probe per request, no shared CTE: cheaper at the batch sizes of 1-6 this sees.
     "SELECT r.ord::int4, q.* FROM unnest($1::bigint[], $2::text[]) WITH ORDINALITY AS r(v, slug, ord) "
     "CROSS JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, "
     TAG_LIST_COL ", (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, "
     "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = r.v) AS favorited, "
     "u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND "
     "fo.followee_id = a.author_id) AS following FROM articles a JOIN users u ON u.id = a.author_id "
     "WHERE a.slug = r.slug) q ORDER BY r.ord"},
    {"comments_by_slug_b",  // v bigint[], slug text[]
     REQ("$1::bigint[], $2::text[]", "v, slug")
     ", cm AS MATERIALIZED (SELECT d.slug, c.id, c.body, c.created_at, c.updated_at, c.author_id, c.username, c.bio, "
     "c.image FROM (SELECT DISTINCT slug FROM req) d JOIN articles a ON a.slug = d.slug LEFT JOIN LATERAL ("
     "SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image FROM comments c "
     "JOIN users u ON u.id = c.author_id WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c "
     "ON true) "
     "SELECT r.ord::int4, cm.id, cm.body, cm.created_at, cm.updated_at, cm.username, cm.bio, cm.image, "
     "(cm.id IS NOT NULL AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND "
     "fo.followee_id = cm.author_id)) AS following FROM req r JOIN cm ON cm.slug = r.slug "
     "ORDER BY r.ord, cm.created_at DESC NULLS LAST, cm.id DESC"},
    {"list_all_b",  // v bigint[], limit bigint[], offset bigint[]
     REQ("$1::bigint[], $2::bigint[], $3::bigint[]", "v, lm, ofs")
     PAGE_BATCH("lm, ofs", "ORDER BY a.id DESC LIMIT d.lm OFFSET d.ofs")
     PAGE_BATCH_OUT("pg.lm = r.lm AND pg.ofs = r.ofs")},
    {"list_author_b",  // v bigint[], limit bigint[], offset bigint[], username text[]
     REQ("$1::bigint[], $2::bigint[], $3::bigint[], $4::text[]", "v, lm, ofs, author")
     PAGE_BATCH("lm, ofs, author",
                "WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = d.author) "
                "ORDER BY a.id DESC LIMIT d.lm OFFSET d.ofs")
     PAGE_BATCH_OUT("pg.lm = r.lm AND pg.ofs = r.ofs AND pg.author = r.author")},
    {"list_fav_b",  // v bigint[], limit bigint[], offset bigint[], username text[]
     REQ("$1::bigint[], $2::bigint[], $3::bigint[], $4::text[]", "v, lm, ofs, fav")
     PAGE_BATCH("lm, ofs, fav",
                "WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = "
                "(SELECT fu.id FROM users fu WHERE fu.username = d.fav) "
                "ORDER BY f.article_id DESC LIMIT d.lm OFFSET d.ofs)")
     PAGE_BATCH_OUT("pg.lm = r.lm AND pg.ofs = r.ofs AND pg.fav = r.fav")},
    {"count_tag_b",  // tag text[]; one row per request
     REQ("$1::text[]", "tag")
     "SELECT r.ord::int4, (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = "
     "(SELECT t.id FROM tags t WHERE t.name = r.tag) LIMIT 1000) s) FROM req r ORDER BY r.ord"},
    {"count_author_b",  // username text[]
     REQ("$1::text[]", "name")
     "SELECT r.ord::int4, (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = "
     "(SELECT u.id FROM users u WHERE u.username = r.name) LIMIT 1000) s) FROM req r ORDER BY r.ord"},
    {"count_fav_b",  // username text[]
     REQ("$1::text[]", "name")
     "SELECT r.ord::int4, (SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = "
     "(SELECT fu.id FROM users fu WHERE fu.username = r.name) LIMIT 1000) s) FROM req r ORDER BY r.ord"},
    {"profile_b",  // v bigint[], username text[]; zero rows for an unknown user
     REQ("$1::bigint[], $2::text[]", "v, name")
     "SELECT r.ord::int4, u.id, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE "
     "fo.follower_id = r.v AND fo.followee_id = u.id) AS following FROM req r JOIN users u ON u.username = r.name "
     "ORDER BY r.ord"},
    {"feed_b",  // v bigint[], limit bigint[], offset bigint[]
     FEED("$1::bigint[], $2::bigint[], $3::bigint[]", "p.ord::int4, ")},
    {"list_tag_b",  // v bigint[], limit bigint[], offset bigint[], tag text[]
     REQ("$1::bigint[], $2::bigint[], $3::bigint[], $4::text[]", "v, lm, ofs, tag")
     PAGE_BATCH("lm, ofs, tag",
                "WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = "
                "(SELECT t.id FROM tags t WHERE t.name = d.tag) ORDER BY at.article_id DESC LIMIT d.lm OFFSET d.ofs)")
     PAGE_BATCH_OUT("pg.lm = r.lm AND pg.ofs = r.ofs AND pg.tag = r.tag")},

    // POST /articles in one segment: the id comes from the sequence, later statements use currval() of this session.
    {"article_create",  // $1 title, $2 author, $3 description, $4 body
     "WITH n AS (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) "
     "INSERT INTO articles (id, slug, author_id, title, description, body) "
     "SELECT n.id, " SLUGIFY("$1::text") " || '-' || n.id, $2::bigint, $1::text, $3::text, $4::text FROM n"},
    {"article_tags_curr",
     "INSERT INTO article_tags (article_id, tag_id) "
     "SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])"},
    // currval() is volatile: compared directly it forces a scan of articles, so evaluate it once in a CTE and join.
    {"article_by_curr",
     "WITH c AS MATERIALIZED (SELECT currval(pg_get_serial_sequence('articles', 'id')) AS id) "
     ARTICLE_FULL_COLS "FROM c JOIN articles a ON a.id = c.id JOIN users u ON u.id = a.author_id"},
};
