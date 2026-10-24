// All 19 RealWorld endpoints, optimized prepared SQL statements, and per-worker Read Coalescing.
// Concurrent read requests that arrive while read connections are busy are coalesced into batched
// unnest(...) WITH ORDINALITY queries with shared count and shared article enrichment.
#include "conduit.h"

#define MAX_COALESCE 32
#define MAX_COALESCE_TAGS 64

enum {
    S_REGISTER,
    S_LOGIN,
    S_USER_BY_ID,
    S_UPDATE_USER,
    S_PROFILE,
    S_FOLLOW_PROFILE,
    S_UNFOLLOW_PROFILE,
    S_ARTICLE_BY_SLUG,
    S_INSERT_TAGS,
    S_CREATE_ARTICLE,
    S_ARTICLE_AUTHOR,
    S_UPDATE_ARTICLE,
    S_DELETE_ARTICLE,
    S_FAVORITE,
    S_UNFAVORITE,
    S_LIST_ALL,
    S_LIST_TAG,
    S_LIST_AUTHOR,
    S_LIST_FAV,
    S_FEED,
    S_COMMENTS,
    S_CREATE_COMMENT,
    S_COMMENT_AUTHOR,
    S_DELETE_COMMENT,
    S_TAGS,
    // Coalesced batch read statements
    S_LOGIN_BATCH,
    S_USER_BY_ID_BATCH,
    S_PROFILE_BATCH,
    S_ARTICLE_BY_SLUG_BATCH,
    S_COMMENTS_BATCH,
    S_LIST_ALL_BATCH,
    S_LIST_TAG_BATCH,
    S_LIST_AUTHOR_BATCH,
    S_LIST_FAV_BATCH,
    S_FEED_BATCH,
    S_COUNT
};

#define SLUGIFY(x) "trim(both '-' from lower(regexp_replace(" x ", '[^A-Za-z0-9]+', '-', 'g')))"

// Single-item article select with single-scan LATERAL favorites count + viewer favorited boolean.
#define SELECT_ARTICLE \
    "SELECT a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, " \
    "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at2.tag_id) FROM article_tags at2 WHERE at2.article_id = a.id ORDER BY 1), " \
    "fv.cnt, fv.fav, " \
    "u.username, u.bio, u.image, " \
    "CASE WHEN $1::int8 > 0 THEN EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1::int8 AND fo.followee_id = a.author_id) ELSE false END " \
    "FROM articles a JOIN users u ON u.id = a.author_id " \
    "LEFT JOIN LATERAL (SELECT count(*)::int4 AS cnt, COALESCE(bool_or(f.user_id = $1::int8), false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true "

#define LIST_COLS \
    "SELECT c.total, p.slug, p.title, p.description, p.created_at, p.updated_at, " \
    "CASE WHEN p.id IS NULL THEN NULL ELSE ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at2.tag_id) FROM article_tags at2 WHERE at2.article_id = p.id ORDER BY 1) END, " \
    "fv.cnt, fv.fav, " \
    "u.username, u.bio, u.image, " \
    "CASE WHEN p.id IS NOT NULL AND $1::int8 > 0 THEN EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1::int8 AND fo.followee_id = p.author_id) ELSE false END " \
    "FROM cnt c LEFT JOIN page p ON true LEFT JOIN users u ON u.id = p.author_id " \
    "LEFT JOIN LATERAL (SELECT count(*)::int4 AS cnt, COALESCE(bool_or(f.user_id = $1::int8), false) AS fav FROM favorites f WHERE f.article_id = p.id) fv ON p.id IS NOT NULL " \
    "ORDER BY p.id DESC"

// Shared enrichment tail for S_LIST_TAG_BATCH, S_LIST_AUTHOR_BATCH, S_LIST_FAV_BATCH
#define BATCH_LIST_FILTERED_TAIL \
    "u_arts AS (" \
    "  SELECT a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at, " \
    "    ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at2.tag_id) FROM article_tags at2 WHERE at2.article_id = a.id ORDER BY 1) AS tag_list, " \
    "    (SELECT count(*)::int4 FROM favorites f WHERE f.article_id = a.id) AS fav_cnt, " \
    "    u.username, u.bio, u.image " \
    "  FROM (SELECT DISTINCT id FROM paged_u) d " \
    "  JOIN articles a ON a.id = d.id " \
    "  JOIN users u ON u.id = a.author_id" \
    "), " \
    "v_fav AS (" \
    "  SELECT da.v, da.id, " \
    "    CASE WHEN da.v > 0 THEN EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = da.id AND f.user_id = da.v) ELSE false END AS favorited " \
    "  FROM (SELECT DISTINCT r.v, pu.id FROM reqs r JOIN paged_u pu ON pu.flt = r.flt AND pu.lim = r.lim AND pu.off = r.off) da" \
    "), " \
    "v_fol AS (" \
    "  SELECT df.v, df.author_id, " \
    "    CASE WHEN df.v > 0 THEN EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = df.v AND fo.followee_id = df.author_id) ELSE false END AS following " \
    "  FROM (SELECT DISTINCT r.v, pu.author_id FROM reqs r JOIN paged_u pu ON pu.flt = r.flt AND pu.lim = r.lim AND pu.off = r.off) df" \
    ") " \
    "SELECT r.idx, uf.total, ua.slug, ua.title, ua.description, ua.created_at, ua.updated_at, " \
    "  ua.tag_list, ua.fav_cnt, vf.favorited, ua.username, ua.bio, ua.image, vfl.following " \
    "FROM reqs r " \
    "JOIN u_flt uf ON uf.flt = r.flt " \
    "LEFT JOIN paged_u pu ON pu.flt = r.flt AND pu.lim = r.lim AND pu.off = r.off " \
    "LEFT JOIN u_arts ua ON ua.id = pu.id " \
    "LEFT JOIN v_fav vf ON vf.v = r.v AND vf.id = pu.id " \
    "LEFT JOIN v_fol vfl ON vfl.v = r.v AND vfl.author_id = pu.author_id " \
    "ORDER BY r.idx, pu.ord"

const stmt_def_t STMTS[] = {
    [S_REGISTER] = {"s0",
        "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) "
        "RETURNING id, username, email, bio, image", 3},
    [S_LOGIN] = {"s1",
        "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1", 1},
    [S_USER_BY_ID] = {"s2",
        "SELECT username, email, bio, image FROM users WHERE id = $1::int8", 1},
    [S_UPDATE_USER] = {"s4",
        "UPDATE users SET "
        "email = COALESCE($2, email), username = COALESCE($3, username), password_hash = COALESCE($4, password_hash), "
        "bio = COALESCE($5, bio), image = COALESCE($6, image) "
        "WHERE id = $1::int8 RETURNING id, username, email, bio, image", 6},
    [S_PROFILE] = {"s5",
        "SELECT u.username, u.bio, u.image, "
        "CASE WHEN $1::int8 > 0 THEN EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1::int8 AND fo.followee_id = u.id) ELSE false END "
        "FROM users u WHERE u.username = $2", 2},
    [S_FOLLOW_PROFILE] = {"s6",
        "WITH target AS (SELECT id, username, bio, image FROM users WHERE username = $2), "
        "ins AS (INSERT INTO follows (follower_id, followee_id) SELECT $1::int8, id FROM target WHERE id <> $1::int8 ON CONFLICT DO NOTHING) "
        "SELECT username, bio, image FROM target", 2},
    [S_UNFOLLOW_PROFILE] = {"s7",
        "WITH target AS (SELECT id, username, bio, image FROM users WHERE username = $2), "
        "del AS (DELETE FROM follows WHERE follower_id = $1::int8 AND followee_id IN (SELECT id FROM target)) "
        "SELECT username, bio, image FROM target", 2},
    [S_ARTICLE_BY_SLUG] = {"s8", SELECT_ARTICLE "WHERE a.slug = $2", 2},
    [S_INSERT_TAGS] = {"s9",
        "INSERT INTO tags (name) "
        "SELECT DISTINCT u.name FROM unnest($1::text[]) AS u(name) "
        "WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.name = u.name) "
        "ORDER BY u.name ON CONFLICT (name) DO NOTHING", 1},
    [S_CREATE_ARTICLE] = {"s10",
        "WITH ins_a AS ("
        "  INSERT INTO articles (id, slug, author_id, title, description, body) "
        "  SELECT n.id, " SLUGIFY("$2") " || '-' || n.id, $1::int8, $2, $3, $4 "
        "  FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n "
        "  RETURNING id, slug, title, description, body, author_id, created_at, updated_at"
        "), "
        "u_tags AS (SELECT DISTINCT u.name FROM unnest($5::text[]) AS u(name)), "
        "ins_at AS ("
        "  INSERT INTO article_tags (article_id, tag_id) "
        "  SELECT a.id, t.id FROM ins_a a CROSS JOIN u_tags ut JOIN tags t ON t.name = ut.name "
        "  ON CONFLICT DO NOTHING"
        ") "
        "SELECT a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, "
        "  ARRAY(SELECT ut.name FROM u_tags ut ORDER BY ut.name), "
        "  0::int4, false, u.username, u.bio, u.image, false "
        "FROM ins_a a JOIN users u ON u.id = a.author_id", 5},
    [S_ARTICLE_AUTHOR] = {"s13",
        "SELECT author_id FROM articles WHERE slug = $1", 1},
    [S_UPDATE_ARTICLE] = {"s14",
        "WITH upd AS ("
        "UPDATE articles a SET "
        "slug = CASE WHEN $3::text IS NULL THEN a.slug ELSE " SLUGIFY("$3") " || '-' || a.id END, "
        "title = COALESCE($3, a.title), description = COALESCE($4, a.description), body = COALESCE($5, a.body), "
        "updated_at = now() "
        "WHERE a.slug = $2 AND a.author_id = $1::int8 "
        "RETURNING a.id, a.slug, a.title, a.description, a.body, a.author_id, a.created_at, a.updated_at) "
        "SELECT a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, "
        "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at2.tag_id) FROM article_tags at2 WHERE at2.article_id = a.id ORDER BY 1), "
        "fv.cnt, fv.fav, u.username, u.bio, u.image, false "
        "FROM upd a JOIN users u ON u.id = a.author_id "
        "LEFT JOIN LATERAL (SELECT count(*)::int4 AS cnt, COALESCE(bool_or(f.user_id = $1::int8), false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true", 5},
    [S_DELETE_ARTICLE] = {"s15",
        "DELETE FROM articles WHERE slug = $1 AND author_id = $2::int8", 2},
    [S_FAVORITE] = {"s16",
        "INSERT INTO favorites (user_id, article_id) "
        "SELECT $1::int8, id FROM articles WHERE slug = $2 ON CONFLICT DO NOTHING", 2},
    [S_UNFAVORITE] = {"s17",
        "DELETE FROM favorites WHERE user_id = $1::int8 AND article_id = (SELECT id FROM articles WHERE slug = $2)", 2},
    [S_LIST_ALL] = {"s18",
        "WITH cnt AS (SELECT count(*)::int4 AS total FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s), "
        "page AS (SELECT a.id, a.slug, a.title, a.description, a.author_id, a.created_at, a.updated_at "
        "FROM (SELECT a.id, a.slug, a.title, a.description, a.author_id, a.created_at, a.updated_at FROM articles a ORDER BY a.id DESC OFFSET $3::int4 LIMIT 100) a LIMIT $2::int4) " LIST_COLS, 3},
    [S_LIST_TAG] = {"s19",
        "WITH tg AS (SELECT id FROM tags WHERE name = $4), "
        "cnt AS (SELECT CASE WHEN (SELECT id FROM tg) IS NULL THEN 0 "
        "WHEN EXISTS (SELECT 1 FROM article_tags at2 WHERE at2.tag_id = (SELECT id FROM tg) OFFSET 999 LIMIT 1) THEN 1000 "
        "ELSE (SELECT count(*)::int4 FROM article_tags at2 WHERE at2.tag_id = (SELECT id FROM tg)) END AS total), "
        "page AS (SELECT a.id, a.slug, a.title, a.description, a.author_id, a.created_at, a.updated_at "
        "FROM articles a WHERE a.id IN (SELECT at2.article_id FROM article_tags at2 WHERE at2.tag_id = (SELECT id FROM tg) ORDER BY at2.article_id DESC LIMIT $2::int4 OFFSET $3::int4)) " LIST_COLS, 4},
    [S_LIST_AUTHOR] = {"s20",
        "WITH au AS (SELECT id FROM users WHERE username = $4), "
        "cnt AS (SELECT count(*)::int4 AS total FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT id FROM au) LIMIT 1000) s), "
        "page AS (SELECT a.id, a.slug, a.title, a.description, a.author_id, a.created_at, a.updated_at "
        "FROM articles a WHERE a.author_id = (SELECT id FROM au) ORDER BY a.id DESC LIMIT $2::int4 OFFSET $3::int4) " LIST_COLS, 4},
    [S_LIST_FAV] = {"s21",
        "WITH fu AS (SELECT id FROM users WHERE username = $4), "
        "cnt AS (SELECT count(*)::int4 AS total FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT id FROM fu) LIMIT 1000) s), "
        "page AS (SELECT a.id, a.slug, a.title, a.description, a.author_id, a.created_at, a.updated_at "
        "FROM articles a WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT id FROM fu) ORDER BY f.article_id DESC LIMIT $2::int4 OFFSET $3::int4)) " LIST_COLS, 4},
    [S_FEED] = {"s22",
        "WITH c AS (SELECT count(*)::int4 AS n FROM (SELECT 1 FROM articles a3 WHERE a3.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1::int8)) ORDER BY a3.author_id, a3.id DESC LIMIT 1000) s) "
        "SELECT c.n, "
        " a.slug, a.title, a.description, a.created_at, a.updated_at, "
        " CASE WHEN a.id IS NULL THEN NULL ELSE ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) END, "
        " (SELECT count(*)::int4 FROM favorites f WHERE f.article_id = a.id), "
        " EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1::int8), "
        " u.username, u.bio, u.image, "
        " true "
        "FROM c LEFT JOIN ( "
        "  SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id "
        "  FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a3.id FROM articles a3 WHERE a3.author_id = fo.followee_id ORDER BY a3.id DESC LIMIT ($2::int4 + $3::int4)) x "
        "        WHERE fo.follower_id = $1::int8 ORDER BY x.id DESC LIMIT $2::int4 OFFSET $3::int4) p "
        "  JOIN articles a2 ON a2.id = p.id "
        ") a ON true LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC", 3},
    [S_COMMENTS] = {"s23",
        "WITH art AS (SELECT id FROM articles WHERE slug = $2), "
        "vf AS MATERIALIZED (SELECT ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1::int8) AS ids) "
        "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, "
        "CASE WHEN c.id IS NOT NULL AND $1::int8 > 0 THEN c.author_id = ANY(vf.ids) ELSE false END "
        "FROM art CROSS JOIN vf "
        "LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c WHERE c.article_id = art.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true "
        "LEFT JOIN users u ON u.id = c.author_id "
        "ORDER BY c.created_at DESC, c.id DESC", 2},
    [S_CREATE_COMMENT] = {"s24",
        "WITH ins AS ("
        "INSERT INTO comments (body, article_id, author_id) "
        "SELECT $3, a.id, $1::int8 FROM articles a WHERE a.slug = $2 "
        "RETURNING id, body, author_id, created_at, updated_at) "
        "SELECT ins.id, ins.body, ins.created_at, ins.updated_at, u.username, u.bio, u.image "
        "FROM ins JOIN users u ON u.id = ins.author_id", 3},
    [S_COMMENT_AUTHOR] = {"s25",
        "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id "
        "WHERE c.id = $1::int8 AND a.slug = $2", 2},
    [S_DELETE_COMMENT] = {"s26",
        "DELETE FROM comments c USING articles a "
        "WHERE c.id = $1::int8 AND c.article_id = a.id AND a.slug = $2 AND c.author_id = $3::int8", 3},
    [S_TAGS] = {"s27", "SELECT ARRAY(SELECT name FROM tags ORDER BY name)", 0},

    // ---------- Coalesced Read Batch Statements ----------
    [S_LOGIN_BATCH] = {"b1",
        "SELECT (r.ord - 1)::int4 AS idx, u.id, u.username, u.email, u.bio, u.image, u.password_hash "
        "FROM unnest($1::text[]) WITH ORDINALITY AS r(em, ord) "
        "JOIN users u ON u.email = r.em "
        "ORDER BY idx", 1},
    [S_USER_BY_ID_BATCH] = {"b2",
        "SELECT (r.ord - 1)::int4 AS idx, u.username, u.email, u.bio, u.image "
        "FROM unnest($1::int8[]) WITH ORDINALITY AS r(uid, ord) "
        "JOIN users u ON u.id = r.uid "
        "ORDER BY idx", 1},
    [S_PROFILE_BATCH] = {"b5",
        "SELECT (r.ord - 1)::int4 AS idx, u.username, u.bio, u.image, "
        "  CASE WHEN r.v > 0 THEN EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = u.id) ELSE false END "
        "FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(v, uname, ord) "
        "JOIN users u ON u.username = r.uname "
        "ORDER BY r.ord", 2},
    [S_ARTICLE_BY_SLUG_BATCH] = {"b8",
        "WITH r AS (SELECT * FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(v, sl, ord)), "
        "d AS (SELECT DISTINCT sl FROM r), "
        "m AS (SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, "
        "  ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at2.tag_id) FROM article_tags at2 WHERE at2.article_id = a.id ORDER BY 1) AS tags, "
        "  (SELECT count(*)::int4 FROM favorites f WHERE f.article_id = a.id) AS fc, "
        "  u.username, u.bio, u.image, a.author_id "
        "  FROM d JOIN articles a ON a.slug = d.sl JOIN users u ON u.id = a.author_id) "
        "SELECT (r.ord - 1)::int4 AS idx, m.slug, m.title, m.description, m.body, m.created_at, m.updated_at, "
        "  m.tags, m.fc, "
        "  CASE WHEN r.v > 0 THEN EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = r.v AND f.article_id = m.id) ELSE false END, "
        "  m.username, m.bio, m.image, "
        "  CASE WHEN r.v > 0 THEN EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = m.author_id) ELSE false END "
        "FROM r JOIN m ON m.slug = r.sl ORDER BY r.ord", 2},
    [S_COMMENTS_BATCH] = {"b23",
        "WITH r AS (SELECT * FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(v, sl, ord)), "
        "d AS (SELECT DISTINCT sl FROM r), "
        "a AS (SELECT a.id, a.slug FROM d JOIN articles a ON a.slug = d.sl), "
        "c AS (SELECT a.slug, c2.id, c2.body, c2.created_at, c2.updated_at, c2.author_id, u.username, u.bio, u.image "
        "  FROM a CROSS JOIN LATERAL ("
        "    SELECT c3.id, c3.body, c3.created_at, c3.updated_at, c3.author_id "
        "    FROM comments c3 WHERE c3.article_id = a.id ORDER BY c3.created_at DESC, c3.id DESC LIMIT 100"
        "  ) c2 JOIN users u ON u.id = c2.author_id) "
        "SELECT (r.ord - 1)::int4 AS idx, c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image, "
        "  CASE WHEN c.id IS NOT NULL AND r.v > 0 THEN EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = c.author_id) ELSE false END "
        "FROM r JOIN a ON a.slug = r.sl LEFT JOIN c ON c.slug = a.slug "
        "ORDER BY r.ord, c.created_at DESC, c.id DESC", 2},
    [S_LIST_ALL_BATCH] = {"b18",
        "WITH reqs AS ("
        "  SELECT (ord - 1)::int4 AS idx, v, lim, off "
        "  FROM unnest($1::int8[], $2::int4[], $3::int4[]) WITH ORDINALITY AS t(v, lim, off, ord)"
        "), "
        "cnt AS ("
        "  SELECT count(*)::int4 AS total FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s"
        "), "
        "u_pages AS (SELECT DISTINCT lim, off FROM reqs), "
        "paged_u AS ("
        "  SELECT up.lim, up.off, p.id, p.author_id, p.ord "
        "  FROM u_pages up "
        "  CROSS JOIN LATERAL ("
        "    SELECT a.id, a.author_id, row_number() OVER (ORDER BY a.id DESC) AS ord "
        "    FROM articles a ORDER BY a.id DESC LIMIT up.lim OFFSET up.off"
        "  ) p"
        "), "
        "u_arts AS ("
        "  SELECT a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at, "
        "    ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at2.tag_id) FROM article_tags at2 WHERE at2.article_id = a.id ORDER BY 1) AS tag_list, "
        "    (SELECT count(*)::int4 FROM favorites f WHERE f.article_id = a.id) AS fav_cnt, "
        "    u.username, u.bio, u.image "
        "  FROM (SELECT DISTINCT id FROM paged_u) d "
        "  JOIN articles a ON a.id = d.id "
        "  JOIN users u ON u.id = a.author_id"
        "), "
        "v_fav AS ("
        "  SELECT da.v, da.id, "
        "    CASE WHEN da.v > 0 THEN EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = da.id AND f.user_id = da.v) ELSE false END AS favorited "
        "  FROM (SELECT DISTINCT r.v, pu.id FROM reqs r JOIN paged_u pu ON pu.lim = r.lim AND pu.off = r.off) da"
        "), "
        "v_fol AS ("
        "  SELECT df.v, df.author_id, "
        "    CASE WHEN df.v > 0 THEN EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = df.v AND fo.followee_id = df.author_id) ELSE false END AS following "
        "  FROM (SELECT DISTINCT r.v, pu.author_id FROM reqs r JOIN paged_u pu ON pu.lim = r.lim AND pu.off = r.off) df"
        ") "
        "SELECT r.idx, cnt.total, ua.slug, ua.title, ua.description, ua.created_at, ua.updated_at, "
        "  ua.tag_list, ua.fav_cnt, vf.favorited, ua.username, ua.bio, ua.image, vfl.following "
        "FROM reqs r "
        "CROSS JOIN cnt "
        "LEFT JOIN paged_u pu ON pu.lim = r.lim AND pu.off = r.off "
        "LEFT JOIN u_arts ua ON ua.id = pu.id "
        "LEFT JOIN v_fav vf ON vf.v = r.v AND vf.id = pu.id "
        "LEFT JOIN v_fol vfl ON vfl.v = r.v AND vfl.author_id = pu.author_id "
        "ORDER BY r.idx, pu.ord", 3},
    [S_LIST_TAG_BATCH] = {"b19",
        "WITH reqs AS ("
        "  SELECT (ord - 1)::int4 AS idx, v, lim, off, flt "
        "  FROM unnest($1::int8[], $2::int4[], $3::int4[], $4::text[]) WITH ORDINALITY AS t(v, lim, off, flt, ord)"
        "), "
        "u_flt AS ("
        "  SELECT d.flt, tg.id AS tag_id, "
        "    CASE WHEN tg.id IS NULL THEN 0 "
        "    WHEN EXISTS (SELECT 1 FROM article_tags at2 WHERE at2.tag_id = tg.id OFFSET 999 LIMIT 1) THEN 1000 "
        "    ELSE (SELECT count(*)::int4 FROM article_tags at2 WHERE at2.tag_id = tg.id) END AS total "
        "  FROM (SELECT DISTINCT flt FROM reqs) d "
        "  LEFT JOIN tags tg ON tg.name = d.flt"
        "), "
        "u_pages AS ("
        "  SELECT DISTINCT r.flt, uf.tag_id, r.lim, r.off "
        "  FROM reqs r JOIN u_flt uf ON uf.flt = r.flt WHERE uf.tag_id IS NOT NULL"
        "), "
        "paged_u AS ("
        "  SELECT up.flt, up.lim, up.off, p.id, p.author_id, p.ord "
        "  FROM u_pages up "
        "  CROSS JOIN LATERAL ("
        "    SELECT a.id, a.author_id, row_number() OVER (ORDER BY a.id DESC) AS ord "
        "    FROM articles a "
        "    WHERE a.id IN (SELECT at2.article_id FROM article_tags at2 WHERE at2.tag_id = up.tag_id ORDER BY at2.article_id DESC LIMIT up.lim OFFSET up.off)"
        "  ) p"
        "), " BATCH_LIST_FILTERED_TAIL, 4},
    [S_LIST_AUTHOR_BATCH] = {"b20",
        "WITH reqs AS ("
        "  SELECT (ord - 1)::int4 AS idx, v, lim, off, flt "
        "  FROM unnest($1::int8[], $2::int4[], $3::int4[], $4::text[]) WITH ORDINALITY AS t(v, lim, off, flt, ord)"
        "), "
        "u_flt AS ("
        "  SELECT d.flt, u.id AS author_id, "
        "    CASE WHEN u.id IS NULL THEN 0 "
        "    ELSE (SELECT count(*)::int4 FROM (SELECT 1 FROM articles a WHERE a.author_id = u.id LIMIT 1000) s) END AS total "
        "  FROM (SELECT DISTINCT flt FROM reqs) d "
        "  LEFT JOIN users u ON u.username = d.flt"
        "), "
        "u_pages AS ("
        "  SELECT DISTINCT r.flt, uf.author_id, r.lim, r.off "
        "  FROM reqs r JOIN u_flt uf ON uf.flt = r.flt WHERE uf.author_id IS NOT NULL"
        "), "
        "paged_u AS ("
        "  SELECT up.flt, up.lim, up.off, p.id, p.author_id, p.ord "
        "  FROM u_pages up "
        "  CROSS JOIN LATERAL ("
        "    SELECT a.id, a.author_id, row_number() OVER (ORDER BY a.id DESC) AS ord "
        "    FROM articles a WHERE a.author_id = up.author_id "
        "    ORDER BY a.id DESC LIMIT up.lim OFFSET up.off"
        "  ) p"
        "), " BATCH_LIST_FILTERED_TAIL, 4},
    [S_LIST_FAV_BATCH] = {"b21",
        "WITH reqs AS ("
        "  SELECT (ord - 1)::int4 AS idx, v, lim, off, flt "
        "  FROM unnest($1::int8[], $2::int4[], $3::int4[], $4::text[]) WITH ORDINALITY AS t(v, lim, off, flt, ord)"
        "), "
        "u_flt AS ("
        "  SELECT d.flt, u.id AS fav_uid, "
        "    CASE WHEN u.id IS NULL THEN 0 "
        "    ELSE (SELECT count(*)::int4 FROM (SELECT 1 FROM favorites f WHERE f.user_id = u.id LIMIT 1000) s) END AS total "
        "  FROM (SELECT DISTINCT flt FROM reqs) d "
        "  LEFT JOIN users u ON u.username = d.flt"
        "), "
        "u_pages AS ("
        "  SELECT DISTINCT r.flt, uf.fav_uid, r.lim, r.off "
        "  FROM reqs r JOIN u_flt uf ON uf.flt = r.flt WHERE uf.fav_uid IS NOT NULL"
        "), "
        "paged_u AS ("
        "  SELECT up.flt, up.lim, up.off, p.id, p.author_id, p.ord "
        "  FROM u_pages up "
        "  CROSS JOIN LATERAL ("
        "    SELECT a.id, a.author_id, row_number() OVER (ORDER BY a.id DESC) AS ord "
        "    FROM articles a WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = up.fav_uid ORDER BY f.article_id DESC LIMIT up.lim OFFSET up.off)"
        "  ) p"
        "), " BATCH_LIST_FILTERED_TAIL, 4},
    [S_FEED_BATCH] = {"b22",
        "WITH reqs AS ("
        "  SELECT (ord - 1)::int4 AS idx, v, lim, off "
        "  FROM unnest($1::int8[], $2::int4[], $3::int4[]) WITH ORDINALITY AS t(v, lim, off, ord)"
        "), "
        "u_flt AS ("
        "  SELECT d.v, (SELECT count(*)::int4 FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = d.v) LIMIT 1000) s) AS total "
        "  FROM (SELECT DISTINCT v FROM reqs) d"
        "), "
        "u_pages AS (SELECT DISTINCT v, lim, off FROM reqs), "
        "paged_u AS ("
        "  SELECT up.v, up.lim, up.off, p.id, p.author_id, p.ord "
        "  FROM u_pages up "
        "  CROSS JOIN LATERAL ("
        "    SELECT a.id, a.author_id, row_number() OVER (ORDER BY a.id DESC) AS ord "
        "    FROM articles a "
        "    WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL "
        "      (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT (up.lim + up.off)) x "
        "      WHERE fo.follower_id = up.v ORDER BY x.id DESC LIMIT up.lim OFFSET up.off)"
        "  ) p"
        "), "
        "u_arts AS ("
        "  SELECT a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at, "
        "    ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at2.tag_id) FROM article_tags at2 WHERE at2.article_id = a.id ORDER BY 1) AS tag_list, "
        "    (SELECT count(*)::int4 FROM favorites f WHERE f.article_id = a.id) AS fav_cnt, "
        "    u.username, u.bio, u.image "
        "  FROM (SELECT DISTINCT id FROM paged_u) d "
        "  JOIN articles a ON a.id = d.id "
        "  JOIN users u ON u.id = a.author_id"
        "), "
        "v_fav AS ("
        "  SELECT da.v, da.id, "
        "    CASE WHEN da.v > 0 THEN EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = da.id AND f.user_id = da.v) ELSE false END AS favorited "
        "  FROM (SELECT DISTINCT r.v, pu.id FROM reqs r JOIN paged_u pu ON pu.v = r.v AND pu.lim = r.lim AND pu.off = r.off) da"
        ") "
        "SELECT r.idx, uf.total, ua.slug, ua.title, ua.description, ua.created_at, ua.updated_at, "
        "  ua.tag_list, ua.fav_cnt, vf.favorited, ua.username, ua.bio, ua.image, true "
        "FROM reqs r "
        "JOIN u_flt uf ON uf.v = r.v "
        "LEFT JOIN paged_u pu ON pu.v = r.v AND pu.lim = r.lim AND pu.off = r.off "
        "LEFT JOIN u_arts ua ON ua.id = pu.id "
        "LEFT JOIN v_fav vf ON vf.v = r.v AND vf.id = pu.id "
        "ORDER BY r.idx, pu.ord", 3},
};
const int N_STMTS = S_COUNT;

// ---------- small helpers ----------

static bool query_get(req_t *r, const char *key, str_t *out) {
    size_t klen = strlen(key);
    const char *p = r->query.p, *end = p + r->query.n;
    bool found = false;
    while (p < end) {
        const char *amp = memchr(p, '&', (size_t)(end - p));
        if (!amp) amp = end;
        const char *eq = memchr(p, '=', (size_t)(amp - p));
        if (eq && (size_t)(eq - p) == klen && memcmp(p, key, klen) == 0) {
            size_t vlen = (size_t)(amp - (eq + 1));
            char *dec = arena_alloc(&r->arena, vlen + 1);
            int n = url_decode(dec, eq + 1, vlen);
            if (n >= 0) {
                *out = (str_t){dec, (size_t)n};
                found = true;
            }
        }
        p = amp + 1;
    }
    return found;
}

static bool limit_offset(req_t *r) {
    str_t v;
    r->limit = 20;
    r->offset = 0;
    if (query_get(r, "limit", &v)) {
        int64_t n;
        if (!parse_uint(v.p, v.n, &n) || n < 1 || n > 100) return false;
        r->limit = n;
    }
    if (query_get(r, "offset", &v)) {
        int64_t n;
        if (!parse_uint(v.p, v.n, &n)) return false;
        r->offset = n;
    }
    return true;
}

static jv_t *wrapper(req_t *r, const char *key) {
    jv_t *top = json_parse(&r->arena, r->body.p, r->body.n);
    if (!top || top->type != J_OBJ) return NULL;
    jv_t *in = json_get(top, key);
    return in && in->type == J_OBJ ? in : NULL;
}

static bool opt_str(req_t *r, const jv_t *m, const char *k, bool nonempty, str_t *out) {
    jv_t *v = json_get(m, k);
    *out = STR_NULL;
    if (!v || v->type == J_NULL) return true;
    if (v->type != J_STR || (nonempty && v->s.n == 0)) return false;
    char *cp = arena_strdup(&r->arena, v->s.p, v->s.n);
    *out = (str_t){cp, v->s.n};
    return true;
}

static bool req_str(req_t *r, const jv_t *m, const char *k, str_t *out) {
    return opt_str(r, m, k, true, out) && out->p;
}

static int64_t fld_i64(pgf_t f) {
    int64_t v = 0;
    return f.n > 0 && parse_i64(f.p, (size_t)f.n, &v) ? v : -1;
}

static str_t viewer_str(req_t *r) { return arena_i64(&r->arena, r->viewer); }

static buf_t *body_start(req_t *r) {
    buf_t *b = &r->w->body;
    b->len = 0;
    return b;
}

static bool batch_ok(req_t *r, pgbatch_t *b) {
    if (!b->failed) return true;
    reply_err(r, 500, "internal error");
    return false;
}

static void start_bcrypt(req_t *r, bool hash, str_t pw, const char *setting, void (*cb)(req_t *, job_t *)) {
    job_t *j = &r->job;
    memset(j, 0, sizeof *j);
    j->r = r;
    j->hash = hash;
    j->pw = arena_strdup(&r->arena, pw.p, pw.n);
    j->setting = setting;
    j->cb = cb;
    submit_job(j);
}

static void rq_push(req_t *r, int qkind) {
    worker_t *w = r->w;
    r->rq_next = NULL;
    if (w->rq_tail[qkind]) w->rq_tail[qkind]->rq_next = r;
    else w->rq_head[qkind] = r;
    w->rq_tail[qkind] = r;
    w->rq_len[qkind]++;
}

// ---------- JSON output ----------

static inline void emit_ts(buf_t *b, pgf_t f) {
    if (__builtin_expect(f.n < 19, 0)) { buf_lit(b, "null"); return; }
    buf_reserve(b, 26);
    char *o = b->p + b->len;
    o[0] = '"';
    memcpy(o + 1, f.p, 10);
    o[11] = 'T';
    memcpy(o + 12, f.p + 11, 8);
    o[20] = '.';
    int k = 0;
    const char *p = f.p + 19, *e = f.p + f.n;
    if (p < e && *p == '.')
        for (p++; k < 3 && p < e && *p >= '0' && *p <= '9'; p++) o[21 + k++] = *p;
    while (k < 3) o[21 + k++] = '0';
    o[24] = 'Z';
    o[25] = '"';
    b->len += 26;
}

static void emit_bool(buf_t *b, pgf_t f) {
    if (f.n > 0 && f.p[0] == 't') buf_lit(b, "true");
    else buf_lit(b, "false");
}

static void emit_str(buf_t *b, pgf_t f) {
    if (f.n < 0) buf_lit(b, "null");
    else buf_json_str(b, f.p, (size_t)f.n);
}

static void emit_text_array(buf_t *b, pgf_t f) {
    buf_putc(b, '[');
    if (f.n >= 2) {
        const char *p = f.p + 1, *e = f.p + f.n - 1;
        bool first = true;
        while (p < e) {
            if (!first) buf_putc(b, ',');
            first = false;
            if (*p == '"') {
                static __thread buf_t tmp;
                tmp.len = 0;
                for (p++; p < e && *p != '"'; p++) {
                    if (*p == '\\' && p + 1 < e) p++;
                    buf_putc(&tmp, *p);
                }
                p++;
                buf_json_str(b, tmp.p, tmp.len);
            } else {
                const char *s = p;
                while (p < e && *p != ',') p++;
                buf_json_str(b, s, (size_t)(p - s));
            }
            if (p < e && *p == ',') p++;
        }
    }
    buf_putc(b, ']');
}

static void emit_profile(buf_t *b, pgf_t username, pgf_t bio, pgf_t image, bool following) {
    buf_lit(b, "{\"username\":");
    emit_str(b, username);
    buf_lit(b, ",\"bio\":");
    emit_str(b, bio);
    buf_lit(b, ",\"image\":");
    emit_str(b, image);
    if (following) buf_lit(b, ",\"following\":true}");
    else buf_lit(b, ",\"following\":false}");
}

static void emit_article(buf_t *b, const pgf_t *f, bool full) {
    buf_lit(b, "{\"slug\":");
    emit_str(b, f[0]);
    buf_lit(b, ",\"title\":");
    emit_str(b, f[1]);
    buf_lit(b, ",\"description\":");
    emit_str(b, f[2]);
    int k = 3;
    if (full) {
        buf_lit(b, ",\"body\":");
        emit_str(b, f[3]);
        k = 4;
    }
    buf_lit(b, ",\"tagList\":");
    emit_text_array(b, f[k + 2]);
    buf_lit(b, ",\"createdAt\":");
    emit_ts(b, f[k]);
    buf_lit(b, ",\"updatedAt\":");
    emit_ts(b, f[k + 1]);
    buf_lit(b, ",\"favorited\":");
    emit_bool(b, f[k + 4]);
    buf_lit(b, ",\"favoritesCount\":");
    buf_put(b, f[k + 3].p, f[k + 3].n > 0 ? (size_t)f[k + 3].n : 0);
    buf_lit(b, ",\"author\":");
    emit_profile(b, f[k + 5], f[k + 6], f[k + 7], f[k + 8].n > 0 && f[k + 8].p[0] == 't');
    buf_putc(b, '}');
}

static void reply_article(req_t *r, int status, const pgst_t *st) {
    if (st->nrows == 0) { reply_err(r, 404, "article not found"); return; }
    buf_t *b = body_start(r);
    buf_lit(b, "{\"article\":");
    emit_article(b, st->f, true);
    buf_putc(b, '}');
    reply(r, status, b);
}

static void reply_user(req_t *r, int status, pgf_t email, const char *tok, size_t tokn, pgf_t username, pgf_t bio, pgf_t image) {
    buf_t *b = body_start(r);
    buf_lit(b, "{\"user\":{\"email\":");
    emit_str(b, email);
    buf_lit(b, ",\"token\":");
    buf_json_str(b, tok, tokn);
    buf_lit(b, ",\"username\":");
    emit_str(b, username);
    buf_lit(b, ",\"bio\":");
    emit_str(b, bio);
    buf_lit(b, ",\"image\":");
    emit_str(b, image);
    buf_lit(b, "}}");
    reply(r, status, b);
}

static void reply_profile(req_t *r, pgf_t username, pgf_t bio, pgf_t image, bool following) {
    buf_t *b = body_start(r);
    buf_lit(b, "{\"profile\":");
    emit_profile(b, username, bio, image, following);
    buf_putc(b, '}');
    reply(r, 200, b);
}

// ---------- users ----------

static bool pw_ok(str_t pw) { return pw.n <= 72 && !memchr(pw.p, 0, pw.n); }

static void register_done(req_t *r, pgbatch_t *b) {
    if (b->failed && !strcmp(b->sqlstate, "23505")) { reply_err(r, 422, "username or email is already taken"); return; }
    if (!batch_ok(r, b)) return;
    const pgst_t *st = &b->st[0];
    if (st->nrows != 1) { reply_err(r, 500, "internal error"); return; }
    char tok[256];
    size_t tn = jwt_issue(tok, fld_i64(pg_get(st, 0, 0)));
    reply_user(r, 201, pg_get(st, 0, 2), tok, tn, pg_get(st, 0, 1), pg_get(st, 0, 3), pg_get(st, 0, 4));
}

static void register_hashed(req_t *r, job_t *j) {
    if (!j->ok) { reply_err(r, 500, "internal error"); return; }
    pgbatch_t *b = pg_begin_ex(r->w, r, register_done, true);
    str_t p[3] = {r->s[0], r->s[1], {j->out, strlen(j->out)}};
    pg_stmt(b, S_REGISTER, p);
    pg_end(b);
}

static void h_register(req_t *r) {
    jv_t *m = wrapper(r, "user");
    if (!m) { reply_err(r, 422, "invalid body"); return; }
    str_t pw;
    if (!req_str(r, m, "username", &r->s[0]) || !req_str(r, m, "email", &r->s[1]) || !req_str(r, m, "password", &pw)) {
        reply_err(r, 422, "username, email and password are required");
        return;
    }
    if (!pw_ok(pw)) { reply_err(r, 422, "password is too long"); return; }
    start_bcrypt(r, true, pw, NULL, register_hashed);
}

static pgf_t str_to_pgf(str_t s) {
    if (s.n == SIZE_MAX) return (pgf_t){NULL, -1};
    return (pgf_t){s.p, (int32_t)s.n};
}

static str_t pgf_to_arena(arena_t *a, pgf_t f) {
    if (f.n < 0) return STR_NULL;
    return (str_t){arena_strdup(a, f.p, (size_t)f.n), (size_t)f.n};
}

static void login_verified(req_t *r, job_t *j) {
    if (!j->ok) { reply_err(r, 401, "invalid email or password"); return; }
    char tok[256];
    size_t tn = jwt_issue(tok, r->viewer);
    reply_user(r, 200, str_to_pgf(r->s[2]), tok, tn, str_to_pgf(r->s[1]), str_to_pgf(r->s[3]), str_to_pgf(r->s[4]));
}

static void login_start_verify(req_t *r, const pgf_t *f) {
    if (!pw_ok(r->s[0])) { reply_err(r, 401, "invalid email or password"); return; }
    r->viewer = fld_i64(f[0]);
    r->s[1] = pgf_to_arena(&r->arena, f[1]); // username
    r->s[2] = pgf_to_arena(&r->arena, f[2]); // email
    r->s[3] = pgf_to_arena(&r->arena, f[3]); // bio
    r->s[4] = pgf_to_arena(&r->arena, f[4]); // image
    pgf_t h = f[5];
    start_bcrypt(r, false, r->s[0], arena_strdup(&r->arena, h.p, h.n > 0 ? (size_t)h.n : 0), login_verified);
}

static void login_found(req_t *r, pgbatch_t *b) {
    if (!batch_ok(r, b)) return;
    const pgst_t *st = &b->st[0];
    if (st->nrows == 0) { reply_err(r, 401, "invalid email or password"); return; }
    login_start_verify(r, st->f);
}

static void h_login(req_t *r) {
    jv_t *m = wrapper(r, "user");
    if (!m) { reply_err(r, 422, "invalid body"); return; }
    if (!req_str(r, m, "email", &r->s[1]) || !req_str(r, m, "password", &r->s[0])) {
        reply_err(r, 422, "email and password are required");
        return;
    }
    rq_push(r, RQ_LOGIN);
}

static void get_user_done(req_t *r, pgbatch_t *b) {
    if (!batch_ok(r, b)) return;
    const pgst_t *st = &b->st[0];
    if (st->nrows == 0) { reply_err(r, 401, "unauthorized"); return; }
    reply_user(r, 200, pg_get(st, 0, 1), r->token.p, r->token.n, pg_get(st, 0, 0), pg_get(st, 0, 2), pg_get(st, 0, 3));
}

static void h_get_user(req_t *r) {
    rq_push(r, RQ_USER);
}

static void update_user_done(req_t *r, pgbatch_t *b) {
    if (b->failed && !strcmp(b->sqlstate, "23505")) { reply_err(r, 422, "username or email is already taken"); return; }
    if (!batch_ok(r, b)) return;
    const pgst_t *st = &b->st[0];
    if (st->nrows == 0) { reply_err(r, 401, "unauthorized"); return; }
    reply_user(r, 200, pg_get(st, 0, 2), r->token.p, r->token.n, pg_get(st, 0, 1), pg_get(st, 0, 3), pg_get(st, 0, 4));
}

static void update_user_run(req_t *r) {
    pgbatch_t *b = pg_begin_ex(r->w, r, update_user_done, true);
    str_t p[6] = {viewer_str(r), r->s[0], r->s[1], r->s[2], r->s[3], r->s[4]};
    pg_stmt(b, S_UPDATE_USER, p);
    pg_end(b);
}

static void update_user_hashed(req_t *r, job_t *j) {
    if (!j->ok) { reply_err(r, 500, "internal error"); return; }
    r->s[2] = (str_t){j->out, strlen(j->out)};
    update_user_run(r);
}

static void h_put_user(req_t *r) {
    jv_t *m = wrapper(r, "user");
    if (!m) { reply_err(r, 422, "invalid body"); return; }
    str_t pw;
    if (!opt_str(r, m, "email", true, &r->s[0]) || !opt_str(r, m, "username", true, &r->s[1]) ||
        !opt_str(r, m, "password", true, &pw) || !opt_str(r, m, "bio", false, &r->s[3]) || !opt_str(r, m, "image", false, &r->s[4])) {
        reply_err(r, 422, "invalid user fields");
        return;
    }
    r->s[2] = STR_NULL;
    if (pw.p) {
        if (!pw_ok(pw)) { reply_err(r, 422, "password is too long"); return; }
        start_bcrypt(r, true, pw, NULL, update_user_hashed);
        return;
    }
    update_user_run(r);
}

// ---------- profiles ----------

static void profile_done(req_t *r, pgbatch_t *b) {
    if (!batch_ok(r, b)) return;
    const pgst_t *st = &b->st[0];
    if (st->nrows == 0) { reply_err(r, 404, "profile not found"); return; }
    pgf_t fo = pg_get(st, 0, 3);
    reply_profile(r, pg_get(st, 0, 0), pg_get(st, 0, 1), pg_get(st, 0, 2), fo.n > 0 && fo.p[0] == 't');
}

static void h_profile(req_t *r) {
    rq_push(r, RQ_PROFILE);
}

static void follow_done(req_t *r, pgbatch_t *b) {
    if (!batch_ok(r, b)) return;
    const pgst_t *st = &b->st[0];
    if (st->nrows == 0) { reply_err(r, 404, "profile not found"); return; }
    reply_profile(r, pg_get(st, 0, 0), pg_get(st, 0, 1), pg_get(st, 0, 2), r->kind != 0);
}

static void h_follow(req_t *r, bool follow) {
    r->kind = follow ? 1 : 0;
    pgbatch_t *b = pg_begin_ex(r->w, r, follow_done, true);
    str_t p[2] = {viewer_str(r), r->seg[1]};
    pg_stmt(b, follow ? S_FOLLOW_PROFILE : S_UNFOLLOW_PROFILE, p);
    pg_end(b);
}

// ---------- articles ----------

static void list_done(req_t *r, pgbatch_t *b) {
    if (!batch_ok(r, b)) return;
    const pgst_t *st = &b->st[0];
    if (st->nrows == 0) { reply_err(r, 500, "internal error"); return; }
    buf_t *o = body_start(r);
    buf_lit(o, "{\"articles\":[");
    for (int i = 0, k = 0; i < st->nrows; i++) {
        const pgf_t *f = st->f + (size_t)i * (size_t)st->ncols;
        if (f[1].n < 0) continue;
        if (k++) buf_putc(o, ',');
        emit_article(o, f + 1, false);
    }
    buf_lit(o, "],\"articlesCount\":");
    pgf_t n = pg_get(st, 0, 0);
    buf_put(o, n.p, n.n > 0 ? (size_t)n.n : 0);
    buf_putc(o, '}');
    reply(r, 200, o);
}

static void h_list(req_t *r) {
    if (!limit_offset(r)) { reply_err(r, 422, "limit must be 1-100 and offset >= 0"); return; }
    r->s[0] = STR_NULL;
    if (query_get(r, "tag", &r->s[0]) && r->s[0].n) {
        rq_push(r, RQ_LIST_TAG);
    } else if (query_get(r, "author", &r->s[0]) && r->s[0].n) {
        rq_push(r, RQ_LIST_AUTHOR);
    } else if (query_get(r, "favorited", &r->s[0]) && r->s[0].n) {
        rq_push(r, RQ_LIST_FAV);
    } else {
        rq_push(r, RQ_LIST_ALL);
    }
}

static void h_feed(req_t *r) {
    if (!limit_offset(r)) { reply_err(r, 422, "limit must be 1-100 and offset >= 0"); return; }
    rq_push(r, RQ_FEED);
}

static void article_done(req_t *r, pgbatch_t *b) {
    if (!batch_ok(r, b)) return;
    reply_article(r, r->kind ? r->kind : 200, &b->st[b->nst - 1]);
}

static void h_get_article(req_t *r) {
    rq_push(r, RQ_ARTICLE);
}

static void create_article_done(req_t *r, pgbatch_t *b) {
    if (!batch_ok(r, b)) return;
    const pgst_t *st = &b->st[b->nst - 1];
    if (st->nrows == 0) { reply_err(r, 500, "internal error"); return; }
    reply_article(r, 201, st);
}

static void h_create_article(req_t *r) {
    jv_t *m = wrapper(r, "article");
    if (!m) { reply_err(r, 422, "invalid body"); return; }
    str_t title, desc, body;
    if (!req_str(r, m, "title", &title) || !req_str(r, m, "description", &desc) || !req_str(r, m, "body", &body)) {
        reply_err(r, 422, "title, description and body are required");
        return;
    }
    jv_t *tl = json_get(m, "tagList");
    buf_t *arr = &r->w->scratch[0];
    arr->len = 0;
    int ntags = 0;
    if (tl && tl->type != J_NULL) {
        if (tl->type != J_ARR) { reply_err(r, 422, "tagList must be an array of non-empty strings"); return; }
        for (jv_t *e = tl->child; e; e = e->next) {
            if (e->type != J_STR || e->s.n == 0) {
                reply_err(r, 422, "tagList must be an array of non-empty strings");
                return;
            }
            buf_putc(arr, ntags++ ? ',' : '{');
            buf_putc(arr, '"');
            for (size_t i = 0; i < e->s.n; i++) {
                if (e->s.p[i] == '"' || e->s.p[i] == '\\') buf_putc(arr, '\\');
                buf_putc(arr, e->s.p[i]);
            }
            buf_putc(arr, '"');
        }
        if (ntags) buf_putc(arr, '}');
    }
    if (!ntags) buf_lit(arr, "{}");

    str_t v = viewer_str(r);
    str_t tag_arr = {arr->p, arr->len};
    pgbatch_t *b = pg_begin_ex(r->w, r, create_article_done, true);
    if (ntags) {
        pg_stmt(b, S_INSERT_TAGS, &tag_arr);
    }
    str_t p[5] = {v, title, desc, body, tag_arr};
    pg_stmt(b, S_CREATE_ARTICLE, p);
    pg_end(b);
}

static bool own_check(req_t *r, pgbatch_t *b, const char *what) {
    if (!batch_ok(r, b)) return false;
    const pgst_t *st = &b->st[0];
    if (st->nrows == 0) { reply_err(r, 404, what); return false; }
    if (fld_i64(pg_get(st, 0, 0)) != r->viewer) { reply_err(r, 403, "not the author"); return false; }
    return true;
}

static void update_article_done(req_t *r, pgbatch_t *b) {
    if (!own_check(r, b, "article not found")) return;
    reply_article(r, 200, &b->st[1]);
}

static void h_put_article(req_t *r) {
    jv_t *m = wrapper(r, "article");
    if (!m) { reply_err(r, 422, "invalid body"); return; }
    str_t p[5] = {viewer_str(r), r->seg[1], STR_NULL, STR_NULL, STR_NULL};
    if (!opt_str(r, m, "title", true, &p[2]) || !opt_str(r, m, "description", true, &p[3]) || !opt_str(r, m, "body", true, &p[4])) {
        reply_err(r, 422, "title, description and body must be non-empty strings");
        return;
    }
    pgbatch_t *b = pg_begin_ex(r->w, r, update_article_done, true);
    pg_stmt(b, S_ARTICLE_AUTHOR, &r->seg[1]);
    pg_stmt(b, S_UPDATE_ARTICLE, p);
    pg_end(b);
}

static void delete_done(req_t *r, pgbatch_t *b) {
    if (!own_check(r, b, r->kind ? "comment not found" : "article not found")) return;
    reply(r, 204, NULL);
}

static void h_delete_article(req_t *r) {
    pgbatch_t *b = pg_begin_ex(r->w, r, delete_done, true);
    str_t p[2] = {r->seg[1], viewer_str(r)};
    pg_stmt(b, S_ARTICLE_AUTHOR, &r->seg[1]);
    pg_stmt(b, S_DELETE_ARTICLE, p);
    pg_end(b);
}

static void h_favorite(req_t *r, bool fav) {
    pgbatch_t *b = pg_begin_ex(r->w, r, article_done, true);
    str_t p[2] = {viewer_str(r), r->seg[1]};
    pg_stmt(b, fav ? S_FAVORITE : S_UNFAVORITE, p);
    pg_stmt(b, S_ARTICLE_BY_SLUG, p);
    pg_end(b);
}

// ---------- comments ----------

static void emit_comment_cols(buf_t *o, const pgf_t *f, bool has_following) {
    buf_lit(o, "{\"id\":");
    buf_put(o, f[0].p, f[0].n > 0 ? (size_t)f[0].n : 0);
    buf_lit(o, ",\"createdAt\":");
    emit_ts(o, f[2]);
    buf_lit(o, ",\"updatedAt\":");
    emit_ts(o, f[3]);
    buf_lit(o, ",\"body\":");
    emit_str(o, f[1]);
    buf_lit(o, ",\"author\":");
    emit_profile(o, f[4], f[5], f[6], has_following && f[7].n > 0 && f[7].p[0] == 't');
    buf_putc(o, '}');
}

static void comments_done(req_t *r, pgbatch_t *b) {
    if (!batch_ok(r, b)) return;
    const pgst_t *st = &b->st[0];
    if (st->nrows == 0) { reply_err(r, 404, "article not found"); return; }
    buf_t *o = body_start(r);
    buf_lit(o, "{\"comments\":[");
    for (int i = 0, k = 0; i < st->nrows; i++) {
        const pgf_t *f = st->f + (size_t)i * (size_t)st->ncols;
        if (f[0].n < 0) continue;
        if (k++) buf_putc(o, ',');
        emit_comment_cols(o, f, true);
    }
    buf_lit(o, "]}");
    reply(r, 200, o);
}

static void h_comments(req_t *r) {
    rq_push(r, RQ_COMMENTS);
}

static void create_comment_done(req_t *r, pgbatch_t *b) {
    if (!batch_ok(r, b)) return;
    const pgst_t *st = &b->st[0];
    if (st->nrows == 0) { reply_err(r, 404, "article not found"); return; }
    buf_t *o = body_start(r);
    buf_lit(o, "{\"comment\":");
    emit_comment_cols(o, st->f, false);
    buf_putc(o, '}');
    reply(r, 201, o);
}

static void h_create_comment(req_t *r) {
    jv_t *m = wrapper(r, "comment");
    str_t body;
    if (!m || !req_str(r, m, "body", &body)) { reply_err(r, 422, "body is required"); return; }
    pgbatch_t *b = pg_begin_ex(r->w, r, create_comment_done, true);
    str_t p[3] = {viewer_str(r), r->seg[1], body};
    pg_stmt(b, S_CREATE_COMMENT, p);
    pg_end(b);
}

static void h_delete_comment(req_t *r) {
    int64_t id;
    if (!parse_uint(r->seg[3].p, r->seg[3].n, &id)) { reply_err(r, 404, "comment not found"); return; }
    r->kind = 1;
    str_t ids = arena_i64(&r->arena, id);
    pgbatch_t *b = pg_begin_ex(r->w, r, delete_done, true);
    str_t p[3] = {ids, r->seg[1], viewer_str(r)};
    pg_stmt(b, S_COMMENT_AUTHOR, p);
    pg_stmt(b, S_DELETE_COMMENT, p);
    pg_end(b);
}

// ---------- tags ----------

static void tags_done(req_t *r, pgbatch_t *b) {
    if (!batch_ok(r, b)) return;
    const pgst_t *st = &b->st[0];
    if (st->nrows == 0) { reply_err(r, 500, "internal error"); return; }
    buf_t *o = body_start(r);
    buf_lit(o, "{\"tags\":");
    emit_text_array(o, pg_get(st, 0, 0));
    buf_putc(o, '}');
    reply(r, 200, o);
}

static void h_tags(req_t *r) {
    rq_push(r, RQ_TAGS);
}

// ---------- Coalesced Read Batch Execution & Demultiplexers ----------

typedef struct {
    int n;
    req_t *reqs[MAX_COALESCE_TAGS];
    int st_idx[MAX_COALESCE_TAGS];
} coal_batch_t;

static void tags_batch_done(req_t *r0, pgbatch_t *b) {
    coal_batch_t *cb = (coal_batch_t *)r0->ctx;
    if (b->failed) {
        for (int i = 0; i < cb->n; i++) reply_err(cb->reqs[i], 500, "internal error");
        return;
    }
    const pgst_t *st = &b->st[0];
    if (st->nrows == 0) {
        for (int i = 0; i < cb->n; i++) reply_err(cb->reqs[i], 500, "internal error");
        return;
    }
    buf_t *o = body_start(r0);
    buf_lit(o, "{\"tags\":");
    emit_text_array(o, pg_get(st, 0, 0));
    buf_putc(o, '}');
    for (int i = 0; i < cb->n; i++) {
        reply(cb->reqs[i], 200, o);
    }
}

static void reply_list_st(req_t *r, const pgst_t *st) {
    if (st->nrows == 0) { reply_err(r, 500, "internal error"); return; }
    buf_t *o = body_start(r);
    buf_lit(o, "{\"articles\":[");
    for (int i = 0, k = 0; i < st->nrows; i++) {
        const pgf_t *f = st->f + (size_t)i * (size_t)st->ncols;
        if (f[1].n < 0) continue;
        if (k++) buf_putc(o, ',');
        emit_article(o, f + 1, false);
    }
    buf_lit(o, "],\"articlesCount\":");
    pgf_t n = pg_get(st, 0, 0);
    buf_put(o, n.p, n.n > 0 ? (size_t)n.n : 0);
    buf_putc(o, '}');
    reply(r, 200, o);
}

static void list_pipe_done(req_t *r0, pgbatch_t *b) {
    coal_batch_t *cb = (coal_batch_t *)r0->ctx;
    if (b->failed) {
        for (int i = 0; i < cb->n; i++) reply_err(cb->reqs[i], 500, "internal error");
        return;
    }
    for (int i = 0; i < cb->n; i++) {
        reply_list_st(cb->reqs[i], &b->st[cb->st_idx[i]]);
    }
}

static void article_batch_done(req_t *r0, pgbatch_t *b) {
    coal_batch_t *cb = (coal_batch_t *)r0->ctx;
    if (b->failed) {
        for (int i = 0; i < cb->n; i++) reply_err(cb->reqs[i], 500, "internal error");
        return;
    }
    const pgst_t *st = &b->st[0];
    int row = 0;
    for (int idx = 0; idx < cb->n; idx++) {
        req_t *r = cb->reqs[idx];
        if (row < st->nrows && fld_i64(pg_get(st, row, 0)) == idx) {
            const pgf_t *f = st->f + (size_t)row * (size_t)st->ncols;
            buf_t *o = body_start(r);
            buf_lit(o, "{\"article\":");
            emit_article(o, f + 1, true);
            buf_putc(o, '}');
            reply(r, 200, o);
            row++;
        } else {
            reply_err(r, 404, "article not found");
        }
    }
}

static void comments_batch_done(req_t *r0, pgbatch_t *b) {
    coal_batch_t *cb = (coal_batch_t *)r0->ctx;
    if (b->failed) {
        for (int i = 0; i < cb->n; i++) reply_err(cb->reqs[i], 500, "internal error");
        return;
    }
    const pgst_t *st = &b->st[0];
    int row = 0;
    for (int idx = 0; idx < cb->n; idx++) {
        req_t *r = cb->reqs[idx];
        if (row >= st->nrows || fld_i64(pg_get(st, row, 0)) != idx) {
            reply_err(r, 404, "article not found");
            continue;
        }
        buf_t *o = body_start(r);
        buf_lit(o, "{\"comments\":[");
        int k = 0;
        while (row < st->nrows && fld_i64(pg_get(st, row, 0)) == idx) {
            const pgf_t *f = st->f + (size_t)row * (size_t)st->ncols;
            if (f[1].n >= 0) {
                if (k++) buf_putc(o, ',');
                emit_comment_cols(o, f + 1, true);
            }
            row++;
        }
        buf_lit(o, "]}");
        reply(r, 200, o);
    }
}

static void profile_batch_done(req_t *r0, pgbatch_t *b) {
    coal_batch_t *cb = (coal_batch_t *)r0->ctx;
    if (b->failed) {
        for (int i = 0; i < cb->n; i++) reply_err(cb->reqs[i], 500, "internal error");
        return;
    }
    const pgst_t *st = &b->st[0];
    int row = 0;
    for (int idx = 0; idx < cb->n; idx++) {
        req_t *r = cb->reqs[idx];
        if (row < st->nrows && fld_i64(pg_get(st, row, 0)) == idx) {
            const pgf_t *f = st->f + (size_t)row * (size_t)st->ncols;
            reply_profile(r, f[1], f[2], f[3], f[4].n > 0 && f[4].p[0] == 't');
            row++;
        } else {
            reply_err(r, 404, "profile not found");
        }
    }
}

static void user_batch_done(req_t *r0, pgbatch_t *b) {
    coal_batch_t *cb = (coal_batch_t *)r0->ctx;
    if (b->failed) {
        for (int i = 0; i < cb->n; i++) reply_err(cb->reqs[i], 500, "internal error");
        return;
    }
    const pgst_t *st = &b->st[0];
    int row = 0;
    for (int idx = 0; idx < cb->n; idx++) {
        req_t *r = cb->reqs[idx];
        if (row < st->nrows && fld_i64(pg_get(st, row, 0)) == idx) {
            const pgf_t *f = st->f + (size_t)row * (size_t)st->ncols;
            reply_user(r, 200, f[2], r->token.p, r->token.n, f[1], f[3], f[4]);
            row++;
        } else {
            reply_err(r, 401, "unauthorized");
        }
    }
}

static void login_batch_done(req_t *r0, pgbatch_t *b) {
    coal_batch_t *cb = (coal_batch_t *)r0->ctx;
    if (b->failed) {
        for (int i = 0; i < cb->n; i++) reply_err(cb->reqs[i], 500, "internal error");
        return;
    }
    const pgst_t *st = &b->st[0];
    int row = 0;
    for (int idx = 0; idx < cb->n; idx++) {
        req_t *r = cb->reqs[idx];
        if (row < st->nrows && fld_i64(pg_get(st, row, 0)) == idx) {
            const pgf_t *f = st->f + (size_t)row * (size_t)st->ncols;
            login_start_verify(r, f + 1);
            row++;
        } else {
            reply_err(r, 401, "invalid email or password");
        }
    }
}

static str_t fmt_i64_arr(buf_t *b, coal_batch_t *cb, int field) {
    b->len = 0;
    buf_putc(b, '{');
    for (int i = 0; i < cb->n; i++) {
        if (i) buf_putc(b, ',');
        int64_t v = (field == 0) ? cb->reqs[i]->viewer : (field == 1) ? cb->reqs[i]->limit : cb->reqs[i]->offset;
        buf_i64(b, v);
    }
    buf_putc(b, '}');
    return (str_t){b->p, b->len};
}

static str_t fmt_str_arr(buf_t *b, coal_batch_t *cb, bool use_seg1) {
    b->len = 0;
    buf_putc(b, '{');
    for (int i = 0; i < cb->n; i++) {
        if (i) buf_putc(b, ',');
        str_t s = use_seg1 ? cb->reqs[i]->seg[1] : cb->reqs[i]->s[0];
        if (use_seg1 == false && cb->reqs[i]->s[1].p && !cb->reqs[i]->s[0].p) s = cb->reqs[i]->s[1];
        buf_putc(b, '"');
        for (size_t k = 0; k < s.n; k++) {
            char c = s.p[k];
            if (c == '"' || c == '\\') buf_putc(b, '\\');
            buf_putc(b, c ? c : ' ');
        }
        buf_putc(b, '"');
    }
    buf_putc(b, '}');
    return (str_t){b->p, b->len};
}

static str_t fmt_login_arr(buf_t *b, coal_batch_t *cb) {
    b->len = 0;
    buf_putc(b, '{');
    for (int i = 0; i < cb->n; i++) {
        if (i) buf_putc(b, ',');
        str_t s = cb->reqs[i]->s[1]; // email
        buf_putc(b, '"');
        for (size_t k = 0; k < s.n; k++) {
            char c = s.p[k];
            if (c == '"' || c == '\\') buf_putc(b, '\\');
            buf_putc(b, c ? c : ' ');
        }
        buf_putc(b, '"');
    }
    buf_putc(b, '}');
    return (str_t){b->p, b->len};
}

static void dispatch_coalesced_queue(worker_t *w, pgconn_t *c, int q) {
    int max_take = (q == RQ_TAGS) ? MAX_COALESCE_TAGS : MAX_COALESCE;
    req_t *r0 = w->rq_head[q];
    if (!r0) return;

    if (!r0->rq_next) {
        // Single-item fast path: zero array-unnest overhead at low concurrency
        w->rq_head[q] = NULL;
        w->rq_tail[q] = NULL;
        w->rq_len[q] = 0;

        pgbatch_t *b = NULL;
        switch (q) {
        case RQ_TAGS:
            b = pg_begin_ex(w, r0, tags_done, false);
            pg_stmt(b, S_TAGS, NULL);
            break;
        case RQ_LIST_ALL: {
            b = pg_begin_ex(w, r0, list_done, false);
            str_t p[3] = {viewer_str(r0), arena_i64(&r0->arena, r0->limit), arena_i64(&r0->arena, r0->offset)};
            pg_stmt(b, S_LIST_ALL, p);
            break;
        }
        case RQ_LIST_TAG:
        case RQ_LIST_AUTHOR:
        case RQ_LIST_FAV: {
            b = pg_begin_ex(w, r0, list_done, false);
            str_t p[4] = {viewer_str(r0), arena_i64(&r0->arena, r0->limit), arena_i64(&r0->arena, r0->offset), r0->s[0]};
            int st = (q == RQ_LIST_TAG) ? S_LIST_TAG : (q == RQ_LIST_AUTHOR) ? S_LIST_AUTHOR : S_LIST_FAV;
            pg_stmt(b, st, p);
            break;
        }
        case RQ_FEED: {
            b = pg_begin_ex(w, r0, list_done, false);
            str_t p[3] = {viewer_str(r0), arena_i64(&r0->arena, r0->limit), arena_i64(&r0->arena, r0->offset)};
            pg_stmt(b, S_FEED, p);
            break;
        }
        case RQ_ARTICLE: {
            b = pg_begin_ex(w, r0, article_done, false);
            str_t p[2] = {viewer_str(r0), r0->seg[1]};
            pg_stmt(b, S_ARTICLE_BY_SLUG, p);
            break;
        }
        case RQ_COMMENTS: {
            b = pg_begin_ex(w, r0, comments_done, false);
            str_t p[2] = {viewer_str(r0), r0->seg[1]};
            pg_stmt(b, S_COMMENTS, p);
            break;
        }
        case RQ_PROFILE: {
            b = pg_begin_ex(w, r0, profile_done, false);
            str_t p[2] = {viewer_str(r0), r0->seg[1]};
            pg_stmt(b, S_PROFILE, p);
            break;
        }
        case RQ_USER: {
            b = pg_begin_ex(w, r0, get_user_done, false);
            str_t p[1] = {viewer_str(r0)};
            pg_stmt(b, S_USER_BY_ID, p);
            break;
        }
        case RQ_LOGIN: {
            b = pg_begin_ex(w, r0, login_found, false);
            pg_stmt(b, S_LOGIN, &r0->s[1]);
            break;
        }
        default:
            break;
        }
        if (b) pg_end_on(c, b);
        return;
    }

    // Multi-request coalesced batch path (n >= 2)
    bool is_list_q = (q >= RQ_LIST_ALL && q <= RQ_FEED);
    if (is_list_q) max_take = 8;
    pgbatch_t *b = pg_begin_ex(w, r0, NULL, false);
    coal_batch_t *cb = arena_alloc(&b->arena, sizeof(coal_batch_t));
    cb->n = 0;
    while (w->rq_head[q] && cb->n < max_take) {
        req_t *r = w->rq_head[q];
        w->rq_head[q] = r->rq_next;
        if (!w->rq_head[q]) w->rq_tail[q] = NULL;
        w->rq_len[q]--;
        r->rq_next = NULL;
        cb->reqs[cb->n++] = r;
    }
    r0->ctx = cb;

    switch (q) {
    case RQ_TAGS:
        b->cb = tags_batch_done;
        pg_stmt(b, S_TAGS, NULL);
        break;
    case RQ_LIST_ALL:
    case RQ_LIST_TAG:
    case RQ_LIST_AUTHOR:
    case RQ_LIST_FAV:
    case RQ_FEED: {
        b->cb = list_pipe_done;
        int st = (q == RQ_LIST_ALL) ? S_LIST_ALL :
                 (q == RQ_LIST_TAG) ? S_LIST_TAG :
                 (q == RQ_LIST_AUTHOR) ? S_LIST_AUTHOR :
                 (q == RQ_LIST_FAV) ? S_LIST_FAV : S_FEED;
        for (int i = 0; i < cb->n; i++) {
            req_t *ri = cb->reqs[i];
            int dup = -1;
            for (int j = 0; j < i; j++) {
                req_t *rj = cb->reqs[j];
                if (ri->viewer == rj->viewer && ri->limit == rj->limit && ri->offset == rj->offset &&
                    ri->s[0].n == rj->s[0].n && (ri->s[0].n == SIZE_MAX || memcmp(ri->s[0].p, rj->s[0].p, ri->s[0].n) == 0)) {
                    dup = cb->st_idx[j];
                    break;
                }
            }
            if (dup >= 0) {
                cb->st_idx[i] = dup;
            } else {
                cb->st_idx[i] = b->nst;
                str_t p[4] = {viewer_str(ri), arena_i64(&ri->arena, ri->limit), arena_i64(&ri->arena, ri->offset), ri->s[0]};
                pg_stmt(b, st, p);
            }
        }
        break;
    }
    case RQ_ARTICLE: {
        b->cb = article_batch_done;
        str_t p[2] = {
            fmt_i64_arr(&w->scratch[0], cb, 0),
            fmt_str_arr(&w->scratch[1], cb, true),
        };
        pg_stmt(b, S_ARTICLE_BY_SLUG_BATCH, p);
        break;
    }
    case RQ_COMMENTS: {
        b->cb = comments_batch_done;
        str_t p[2] = {
            fmt_i64_arr(&w->scratch[0], cb, 0),
            fmt_str_arr(&w->scratch[1], cb, true),
        };
        pg_stmt(b, S_COMMENTS_BATCH, p);
        break;
    }
    case RQ_PROFILE: {
        b->cb = profile_batch_done;
        str_t p[2] = {
            fmt_i64_arr(&w->scratch[0], cb, 0),
            fmt_str_arr(&w->scratch[1], cb, true),
        };
        pg_stmt(b, S_PROFILE_BATCH, p);
        break;
    }
    case RQ_USER: {
        b->cb = user_batch_done;
        str_t p[1] = {fmt_i64_arr(&w->scratch[0], cb, 0)};
        pg_stmt(b, S_USER_BY_ID_BATCH, p);
        break;
    }
    case RQ_LOGIN: {
        b->cb = login_batch_done;
        str_t p[1] = {fmt_login_arr(&w->scratch[0], cb)};
        pg_stmt(b, S_LOGIN_BATCH, p);
        break;
    }
    default:
        break;
    }
    pg_end_on(c, b);
}

void api_flush_coalesced(worker_t *w) {
    for (;;) {
        pgconn_t *c = pg_pick_idle_read(w);
        if (!c) return;

        int picked = -1;
        for (int i = 0; i < RQ_COUNT; i++) {
            int q = (w->rq_rr + i) % RQ_COUNT;
            if (w->rq_head[q]) {
                picked = q;
                w->rq_rr = (q + 1) % RQ_COUNT;
                break;
            }
        }
        if (picked < 0) return;
        dispatch_coalesced_queue(w, c, picked);
    }
}

// ---------- routing ----------

enum { A_NONE, A_OPTIONAL, A_REQUIRED };
enum {
    R_NONE, R_REGISTER, R_LOGIN, R_GET_USER, R_PUT_USER, R_PROFILE, R_FOLLOW, R_UNFOLLOW, R_LIST, R_FEED,
    R_CREATE_ARTICLE, R_GET_ARTICLE, R_PUT_ARTICLE, R_DEL_ARTICLE, R_FAV, R_UNFAV, R_COMMENTS,
    R_CREATE_COMMENT, R_DEL_COMMENT, R_TAGS
};
static const int AUTH[] = {
    [R_GET_USER] = A_REQUIRED, [R_PUT_USER] = A_REQUIRED, [R_PROFILE] = A_OPTIONAL, [R_FOLLOW] = A_REQUIRED,
    [R_UNFOLLOW] = A_REQUIRED, [R_LIST] = A_OPTIONAL, [R_FEED] = A_REQUIRED, [R_CREATE_ARTICLE] = A_REQUIRED,
    [R_GET_ARTICLE] = A_OPTIONAL, [R_PUT_ARTICLE] = A_REQUIRED, [R_DEL_ARTICLE] = A_REQUIRED, [R_FAV] = A_REQUIRED,
    [R_UNFAV] = A_REQUIRED, [R_COMMENTS] = A_OPTIONAL, [R_CREATE_COMMENT] = A_REQUIRED, [R_DEL_COMMENT] = A_REQUIRED,
    [R_TAGS] = A_NONE, [R_REGISTER] = A_NONE, [R_LOGIN] = A_NONE,
};

static int route(req_t *r) {
    const str_t *s = r->seg;
    int n = r->nseg, m = r->method;
    if (n <= 0) return R_NONE;
    if (str_eq(s[0], "articles")) {
        if (n == 1) return m == M_GET ? R_LIST : m == M_POST ? R_CREATE_ARTICLE : R_NONE;
        if (s[1].n == 0) return R_NONE;
        if (n == 2) {
            if (m == M_GET) return str_eq(s[1], "feed") ? R_FEED : R_GET_ARTICLE;
            return m == M_PUT ? R_PUT_ARTICLE : m == M_DELETE ? R_DEL_ARTICLE : R_NONE;
        }
        if (n == 3 && str_eq(s[2], "favorite")) return m == M_POST ? R_FAV : m == M_DELETE ? R_UNFAV : R_NONE;
        if (n == 3 && str_eq(s[2], "comments")) return m == M_GET ? R_COMMENTS : m == M_POST ? R_CREATE_COMMENT : R_NONE;
        if (n == 4 && str_eq(s[2], "comments") && s[3].n && m == M_DELETE) return R_DEL_COMMENT;
        return R_NONE;
    }
    if (str_eq(s[0], "tags")) return n == 1 && m == M_GET ? R_TAGS : R_NONE;
    if (str_eq(s[0], "user")) return n == 1 ? (m == M_GET ? R_GET_USER : m == M_PUT ? R_PUT_USER : R_NONE) : R_NONE;
    if (str_eq(s[0], "profiles") && n >= 2 && s[1].n) {
        if (n == 2) return m == M_GET ? R_PROFILE : R_NONE;
        if (n == 3 && str_eq(s[2], "follow")) return m == M_POST ? R_FOLLOW : m == M_DELETE ? R_UNFOLLOW : R_NONE;
        return R_NONE;
    }
    if (str_eq(s[0], "users")) {
        if (n == 1) return m == M_POST ? R_REGISTER : R_NONE;
        if (n == 2 && str_eq(s[1], "login")) return m == M_POST ? R_LOGIN : R_NONE;
    }
    return R_NONE;
}

static int authenticate(req_t *r) {
    if (!r->auth.p || r->auth.n == 0) return 0;
    if (r->auth.n < 6 || memcmp(r->auth.p, "Token ", 6) != 0) return -1;
    str_t t = {r->auth.p + 6, r->auth.n - 6};
    int64_t id;
    if (!jwt_verify(&r->arena, t.p, t.n, &id)) return -1;
    r->viewer = id;
    r->token = t;
    return 1;
}

void api_dispatch(req_t *r) {
    int rt = route(r);
    if (rt == R_NONE) { reply_err(r, 404, "not found"); return; }
    if (AUTH[rt] != A_NONE) {
        int a = authenticate(r);
        if (a < 0 || (a == 0 && AUTH[rt] == A_REQUIRED)) { reply_err(r, 401, "unauthorized"); return; }
    }
    switch (rt) {
    case R_REGISTER: h_register(r); break;
    case R_LOGIN: h_login(r); break;
    case R_GET_USER: h_get_user(r); break;
    case R_PUT_USER: h_put_user(r); break;
    case R_PROFILE: h_profile(r); break;
    case R_FOLLOW: h_follow(r, true); break;
    case R_UNFOLLOW: h_follow(r, false); break;
    case R_LIST: h_list(r); break;
    case R_FEED: h_feed(r); break;
    case R_CREATE_ARTICLE: h_create_article(r); break;
    case R_GET_ARTICLE: h_get_article(r); break;
    case R_PUT_ARTICLE: h_put_article(r); break;
    case R_DEL_ARTICLE: h_delete_article(r); break;
    case R_FAV: h_favorite(r, true); break;
    case R_UNFAV: h_favorite(r, false); break;
    case R_COMMENTS: h_comments(r); break;
    case R_CREATE_COMMENT: h_create_comment(r); break;
    case R_DEL_COMMENT: h_delete_comment(r); break;
    case R_TAGS: h_tags(r); break;
    default: break;
    }
}
