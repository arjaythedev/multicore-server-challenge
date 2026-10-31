/* api.c - the Conduit API: routing, the prepared statement table, and the
 * request continuations that build each response.
 *
 * Shape: every handler validates its input, appends statements with pg_add()
 * and hands the request to pg_go(); the batch completes with one round trip
 * (one Bind/Execute per statement and one Sync, so writes are committed
 * before anything is answered) and the continuation builds the JSON straight
 * out of the Postgres text columns. List endpoints run their page query and
 * their capped count in the same batch: two statements, still one round
 * trip, so an empty page still carries the count. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "http.h"

#include "bcrypt.h"
#include "conduit.h"
#include "json.h"
#include "jwt.h"
#include "pg.h"
#include "util.h"

/* ================================================================ statements */

static const char *SQL[] = {
    [ST_TAGS] =
        "SELECT name FROM tags ORDER BY name",
    [ST_USER_INS] =
        "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) "
        "RETURNING id, username, email, bio, image",
    [ST_USER_BY_EMAIL] =
        "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1",
    [ST_USER_BY_ID] =
        "SELECT id, username, email, bio, image FROM users WHERE id = $1",
    [ST_USER_UPD] =
        "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), "
        "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) "
        "WHERE id = $1 RETURNING id, username, email, bio, image",
    [ST_PROFILE] =
        "SELECT u.id, u.username, u.bio, u.image, "
        "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following "
        "FROM users u WHERE u.username = $2",
    [ST_FOLLOW] =
        "INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM users WHERE username = $2 "
        "ON CONFLICT DO NOTHING",
    [ST_UNFOLLOW] =
        "DELETE FROM follows WHERE follower_id = $1 "
        "AND followee_id = (SELECT id FROM users WHERE username = $2)",
    [ST_LIST] =
        "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, "
        "ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id "
        " WHERE at.article_id = a.id ORDER BY t.name) AS tag_list, "
        "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, "
        "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, "
        "u.username, u.bio, u.image, "
        "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following "
        "FROM (SELECT id FROM articles ORDER BY id DESC OFFSET $3 LIMIT $2) ids "
        "JOIN articles a ON a.id = ids.id JOIN users u ON u.id = a.author_id "
        "ORDER BY a.id DESC",
    [ST_LIST_COUNT] =
        "SELECT count(*) FROM (SELECT 1 FROM articles LIMIT 1000) s",
    [ST_LIST_TAG] =
        "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, "
        "ARRAY(SELECT t.name FROM article_tags at2 JOIN tags t ON t.id = at2.tag_id "
        " WHERE at2.article_id = a.id ORDER BY t.name) AS tag_list, "
        "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, "
        "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, "
        "u.username, u.bio, u.image, "
        "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following "
        "FROM (SELECT at.article_id FROM article_tags at "
        " WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) "
        " ORDER BY at.article_id DESC OFFSET $3 LIMIT $2) ids "
        "JOIN articles a ON a.id = ids.article_id JOIN users u ON u.id = a.author_id "
        "ORDER BY a.id DESC",
    [ST_LIST_TAG_COUNT] =
        "SELECT count(*) FROM (SELECT 1 FROM article_tags at "
        " WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s",
    [ST_LIST_AUTHOR] =
        "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, "
        "ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id "
        " WHERE at.article_id = a.id ORDER BY t.name) AS tag_list, "
        "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, "
        "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, "
        "u.username, u.bio, u.image, "
        "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following "
        "FROM (SELECT id FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = $4) "
        " ORDER BY id DESC OFFSET $3 LIMIT $2) ids "
        "JOIN articles a ON a.id = ids.id JOIN users u ON u.id = a.author_id "
        "ORDER BY a.id DESC",
    [ST_LIST_AUTHOR_COUNT] =
        "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = "
        "(SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s",
    [ST_LIST_FAV] =
        "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, "
        "ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id "
        " WHERE at.article_id = a.id ORDER BY t.name) AS tag_list, "
        "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, "
        "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, "
        "u.username, u.bio, u.image, "
        "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following "
        "FROM (SELECT f.article_id FROM favorites f "
        " WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) "
        " ORDER BY f.article_id DESC OFFSET $3 LIMIT $2) ids "
        "JOIN articles a ON a.id = ids.article_id JOIN users u ON u.id = a.author_id "
        "ORDER BY a.id DESC",
    [ST_LIST_FAV_COUNT] =
        "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = "
        "(SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s",
    [ST_FEED] =
        "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, "
        "ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id "
        " WHERE at.article_id = a.id ORDER BY t.name) AS tag_list, "
        "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, "
        "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, "
        "u.username, u.bio, u.image, "
        "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following "
        "FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL "
        " (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x "
        " WHERE fo.follower_id = $1 ORDER BY x.id DESC OFFSET $3 LIMIT $2) ids "
        "JOIN articles a ON a.id = ids.id JOIN users u ON u.id = a.author_id "
        "ORDER BY a.id DESC",
    [ST_FEED_COUNT] =
        "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN "
        "(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s",
    [ST_ART_FULL_SLUG] =
        "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, "
        "ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id "
        " WHERE at.article_id = a.id ORDER BY t.name) AS tag_list, "
        "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, "
        "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, "
        "u.username, u.bio, u.image, "
        "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following "
        "FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2",
    [ST_ART_FULL_ID] =
        "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, "
        "ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id "
        " WHERE at.article_id = a.id ORDER BY t.name) AS tag_list, "
        "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, "
        "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, "
        "u.username, u.bio, u.image, "
        "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following "
        "FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = $2",
    [ST_ART_LAST] =
        "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, "
        "ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id "
        " WHERE at.article_id = a.id ORDER BY t.name) AS tag_list, "
        "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, "
        "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, "
        "u.username, u.bio, u.image, "
        "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following "
        "FROM articles a JOIN users u ON u.id = a.author_id "
        "WHERE a.id = currval(pg_get_serial_sequence('articles', 'id'))",
    [ST_ART_SEL] =
        "SELECT id, author_id FROM articles WHERE slug = $1",
    [ST_ART_UPD] =
        "UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), "
        "body = COALESCE($4, body), "
        "slug = CASE WHEN $2::text IS NULL THEN slug "
        "ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END, "
        "updated_at = now() WHERE id = $1 RETURNING id",
    [ST_ART_DEL] =
        "DELETE FROM articles WHERE id = $1",
    [ST_ART_INS] =
        "INSERT INTO articles (id, slug, author_id, title, description, body) "
        "SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, "
        "$1, $2, $3, $4 FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n "
        "RETURNING id",
    [ST_TAGS_INS] =
        "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING",
    [ST_ARTTAGS_INS] =
        "INSERT INTO article_tags (article_id, tag_id) "
        "SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])",
    [ST_FAV_INS] =
        "INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM articles WHERE slug = $2 "
        "ON CONFLICT DO NOTHING",
    [ST_FAV_DEL] =
        "DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM articles WHERE slug = $2)",
    [ST_COMMENTS] =
        "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, "
        "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following "
        "FROM (SELECT a.id FROM articles a WHERE a.slug = $2) s "
        "LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c "
        " WHERE c.article_id = s.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true "
        "LEFT JOIN users u ON u.id = c.author_id",
    [ST_COMMENT_INS] =
        "WITH a AS (SELECT id FROM articles WHERE slug = $1), "
        "ins AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $2, $3 FROM a "
        " RETURNING id, body, created_at, updated_at, author_id) "
        "SELECT ins.id, ins.body, ins.created_at, ins.updated_at, u.username, u.bio, u.image "
        "FROM ins JOIN users u ON u.id = ins.author_id",
    [ST_COMMENT_DEL] =
        "WITH t AS (SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id "
        " WHERE c.id = $1 AND a.slug = $2), "
        "d AS (DELETE FROM comments WHERE id = $1 AND author_id = $3 "
        " AND EXISTS (SELECT 1 FROM t WHERE author_id = $3) RETURNING 1) "
        "SELECT t.author_id, (SELECT count(*) FROM d) FROM t",
};

const char *pg_sql(int stmt) { return SQL[stmt]; }

/* forward decls (handlers reference each other's continuations) */
static void cb_login_verified(bcrypt_job_t *j);
static void cb_article_del(req_t *r);
static void cb_comment_deleted(req_t *r);
static void cb_user_put_hashed(bcrypt_job_t *j);
static int ascii_only(const char *s, size_t n);
static const char *int64_span(req_t *r, int64_t v);

/* 2 bits per parameter: 0 = none, 1 = int8, 2 = text, 3 = text[] */
static const int PARAM_OIDS[ST_COMMENT_DEL + 1] = {
    [ST_USER_INS] = (2 << 0) | (2 << 2) | (2 << 4),
    [ST_USER_BY_EMAIL] = 2,
    [ST_USER_BY_ID] = 1,
    [ST_USER_UPD] = (1 << 0) | (2 << 2) | (2 << 4) | (2 << 6) | (2 << 8) | (2 << 10),
    [ST_PROFILE] = (1 << 0) | (2 << 2),
    [ST_FOLLOW] = (1 << 0) | (2 << 2),
    [ST_UNFOLLOW] = (1 << 0) | (2 << 2),
    [ST_LIST] = (1 << 0) | (1 << 2) | (1 << 4),
    [ST_LIST_COUNT] = 0,
    [ST_LIST_TAG] = (1 << 0) | (1 << 2) | (1 << 4) | (2 << 6),
    [ST_LIST_TAG_COUNT] = 2,
    [ST_LIST_AUTHOR] = (1 << 0) | (1 << 2) | (1 << 4) | (2 << 6),
    [ST_LIST_AUTHOR_COUNT] = 2,
    [ST_LIST_FAV] = (1 << 0) | (1 << 2) | (1 << 4) | (2 << 6),
    [ST_LIST_FAV_COUNT] = 2,
    [ST_FEED] = (1 << 0) | (1 << 2) | (1 << 4),
    [ST_FEED_COUNT] = 1,
    [ST_ART_FULL_SLUG] = (1 << 0) | (2 << 2),
    [ST_ART_FULL_ID] = (1 << 0) | (1 << 2),
    [ST_ART_LAST] = 1,
    [ST_ART_SEL] = 2,
    [ST_ART_UPD] = (1 << 0) | (2 << 2) | (2 << 4) | (2 << 6),
    [ST_ART_DEL] = 1,
    [ST_ART_INS] = (1 << 0) | (2 << 2) | (2 << 4) | (2 << 6),
    [ST_TAGS_INS] = 3,
    [ST_ARTTAGS_INS] = 3,
    [ST_FAV_INS] = (1 << 0) | (2 << 2),
    [ST_FAV_DEL] = (1 << 0) | (2 << 2),
    [ST_COMMENTS] = (1 << 0) | (2 << 2),
    [ST_COMMENT_INS] = (2 << 0) | (1 << 2) | (2 << 4),
    [ST_COMMENT_DEL] = (1 << 0) | (2 << 2) | (1 << 4),
};

int pg_param_oids(int stmt) { return PARAM_OIDS[stmt]; }

static const int NPARAMS[ST_COMMENT_DEL + 1] = {
    [ST_TAGS] = 0,
    [ST_USER_INS] = 3,
    [ST_USER_BY_EMAIL] = 1,
    [ST_USER_BY_ID] = 1,
    [ST_USER_UPD] = 6,
    [ST_PROFILE] = 2,
    [ST_FOLLOW] = 2,
    [ST_UNFOLLOW] = 2,
    [ST_LIST] = 3,
    [ST_LIST_COUNT] = 0,
    [ST_LIST_TAG] = 4,
    [ST_LIST_TAG_COUNT] = 1,
    [ST_LIST_AUTHOR] = 4,
    [ST_LIST_AUTHOR_COUNT] = 1,
    [ST_LIST_FAV] = 4,
    [ST_LIST_FAV_COUNT] = 1,
    [ST_FEED] = 3,
    [ST_FEED_COUNT] = 1,
    [ST_ART_FULL_SLUG] = 2,
    [ST_ART_FULL_ID] = 2,
    [ST_ART_LAST] = 1,
    [ST_ART_SEL] = 1,
    [ST_ART_UPD] = 4,
    [ST_ART_DEL] = 1,
    [ST_ART_INS] = 4,
    [ST_TAGS_INS] = 1,
    [ST_ARTTAGS_INS] = 1,
    [ST_FAV_INS] = 2,
    [ST_FAV_DEL] = 2,
    [ST_COMMENTS] = 2,
    [ST_COMMENT_INS] = 3,
    [ST_COMMENT_DEL] = 3,
};

int pg_nparams(int stmt) { return NPARAMS[stmt]; }

/* ================================================================ emit helpers */

static void jlit(req_t *r, const char *s) { buf_put(&r->resp, s, strlen(s)); }

static void jstr(req_t *r, const char *s, size_t n)
{
    char tmp[8192];
    buf_reserve(&r->resp, n * 6 + 16);
    char *o = r->resp.p + r->resp.len;
    *o++ = '"';
    r->resp.len++;
    while (n) {
        size_t chunk = n < 4096 ? n : 4096;
        char *e = j_escape(o, (const unsigned char *)s, chunk);
        r->resp.len += (uint32_t)(e - o);
        o = r->resp.p + r->resp.len;
        s += chunk;
        n -= chunk;
    }
    buf_put(&r->resp, "\"", 1);
    (void)tmp;
}

/* null when the cell is NULL */
static void jcell(req_t *r, const pgval_t *v)
{
    if (!v || v->n == (uint32_t)-1) { jlit(r, "null"); return; }
    jstr(r, v->p, v->n);
}

/* PG timestamptz text (ISO, UTC): "2025-04-01 12:00:00.123456+00" ->
 * RFC 3339 with exactly 3 fractional digits, truncated */
char *emit_ts(char *o, const char *src, size_t n)
{
    if (n < 19) return o;
    memcpy(o, src, 10);          /* date */
    o += 10;
    *o++ = 'T';
    memcpy(o, src + 11, 8);      /* HH:MM:SS */
    o += 8;
    /* fractional digits: present or not, always exactly 3 */
    *o++ = '.';
    if (n > 20 && src[19] == '.') {
        int have = 0;
        const char *f = src + 20;
        while (f < src + n && *f >= '0' && *f <= '9' && have < 6) { if (have < 3) *o++ = *f; have++; f++; }
        while (have < 3) { *o++ = '0'; have++; }
    } else {
        *o++ = '0'; *o++ = '0'; *o++ = '0';
    }
    *o++ = 'Z';
    return o;
}

void put_ts(req_t *r, const pgval_t *v)
{
    if (!v || v->n == (uint32_t)-1) { jlit(r, "null"); return; }
    char tmp[40];
    char *e = emit_ts(tmp, v->p, v->n);
    buf_put(&r->resp, "\"", 1);
    buf_put(&r->resp, tmp, (size_t)(e - tmp));
    buf_put(&r->resp, "\"", 1);
}

/* PG text[] literal: {a,b,"c d"} -> JSON array of strings */
char *emit_text_array(char *o, const char *s, size_t n)
{
    *o++ = '[';
    if (n >= 2 && s[0] == '{' && s[n - 1] == '}') {
        const char *p = s + 1, *e = s + n - 1;
        int first = 1;
        while (p < e) {
            if (!first) *o++ = ',';
            first = 0;
            *o++ = '"';
            if (*p == '"') {
                p++;
                while (p < e && *p != '"') {
                    if (*p == '\\' && p + 1 < e) p++;
                    o = j_escape(o, (const unsigned char *)p, 1);
                    p++;
                }
                if (p < e) p++; /* closing quote */
            } else {
                const char *z = memchr(p, ',', (size_t)(e - p));
                const char *el = z ? z : e;
                if (el > p) o = j_escape(o, (const unsigned char *)p, (size_t)(el - p));
                p = el;
            }
            *o++ = '"';
            if (p < e && *p == ',') p++;
        }
    }
    *o++ = ']';
    return o;
}

void put_text_array(req_t *r, const pgval_t *v)
{
    if (!v || v->n == (uint32_t)-1) { jlit(r, "[]"); return; }
    buf_reserve(&r->resp, v->n * 6 + 4);
    char *o = r->resp.p + r->resp.len;
    char *e = emit_text_array(o, v->p, v->n);
    r->resp.len += (uint32_t)(e - o);
}

/* verbatim numeric text (favoritesCount, ids) */
static void jnum(req_t *r, const pgval_t *v)
{
    if (!v || v->n == (uint32_t)-1) { jlit(r, "null"); return; }
    /* sanitize: digits only (PG count(*) and bigint text are clean, but be safe) */
    for (uint32_t i = 0; i < v->n; i++)
        if (v->p[i] < '0' || v->p[i] > '9') { jlit(r, "0"); return; }
    buf_put(&r->resp, v->p, v->n);
}

/* ================================================================ replies */

static const char ERR_401[] = "{\"errors\":{\"body\":[\"unauthorized\"]}}";
static const char ERR_403[] = "{\"errors\":{\"body\":[\"forbidden\"]}}";
static const char ERR_404[] = "{\"errors\":{\"body\":[\"not found\"]}}";
static const char ERR_422[] = "{\"errors\":{\"body\":[\"validation error\"]}}";
static const char ERR_500[] = "{\"errors\":{\"body\":[\"internal error\"]}}";

static void reply_err(req_t *r, int status)
{
    switch (status) {
    case 401: srv_reply(r, 401, ERR_401, sizeof ERR_401 - 1); break;
    case 403: srv_reply(r, 403, ERR_403, sizeof ERR_403 - 1); break;
    case 404: srv_reply(r, 404, ERR_404, sizeof ERR_404 - 1); break;
    case 422: srv_reply(r, 422, ERR_422, sizeof ERR_422 - 1); break;
    default: srv_reply(r, 500, ERR_500, sizeof ERR_500 - 1); break;
    }
}

/* a failed batch: 23505 is a unique violation -> 422, everything else 500 */
static void reply_failed(req_t *r)
{
    reply_err(r, !strcmp(r->sqlstate, "23505") ? 422 : 500);
}

/* ================================================================ objects */

static void emit_user(req_t *r, const pgval_t *row, const char *token, size_t tl)
{
    /* row: id, username, email, bio, image */
    jlit(r, "{\"user\":{\"email\":");
    jcell(r, &row[2]);
    jlit(r, ",\"token\":");
    if (token) jstr(r, token, tl);
    else jcell(r, NULL);
    jlit(r, ",\"username\":");
    jcell(r, &row[1]);
    jlit(r, ",\"bio\":");
    jcell(r, &row[3]);
    jlit(r, ",\"image\":");
    jcell(r, &row[4]);
    jlit(r, "}}");
}

static void emit_profile(req_t *r, const pgval_t *row, int following)
{
    /* row: id, username, bio, image */
    (void)row;
    jlit(r, "{\"profile\":{\"bio\":");
    jcell(r, &row[2]);
    jlit(r, ",\"following\":");
    jlit(r, following ? "true" : "false");
    jlit(r, ",\"image\":");
    jcell(r, &row[3]);
    jlit(r, ",\"username\":");
    jcell(r, &row[1]);
    jlit(r, "}}");
}

/* article (full, 14 cols): id, slug, title, description, body, created,
 * updated, tag_list, favorites_count, favorited, username, bio, image, following */
static void emit_article_full(req_t *r, const pgval_t *row)
{
    jlit(r, "{\"slug\":");
    jcell(r, &row[1]);
    jlit(r, ",\"title\":");
    jcell(r, &row[2]);
    jlit(r, ",\"description\":");
    jcell(r, &row[3]);
    jlit(r, ",\"body\":");
    jcell(r, &row[4]);
    jlit(r, ",\"tagList\":");
    put_text_array(r, &row[7]);
    jlit(r, ",\"createdAt\":");
    put_ts(r, &row[5]);
    jlit(r, ",\"updatedAt\":");
    put_ts(r, &row[6]);
    jlit(r, ",\"favorited\":");
    jlit(r, row[9].n == 1 && row[9].p[0] == 't' ? "true" : "false");
    jlit(r, ",\"favoritesCount\":");
    jnum(r, &row[8]);
    jlit(r, ",\"author\":{\"bio\":");
    jcell(r, &row[11]);
    jlit(r, ",\"following\":");
    jlit(r, row[13].n == 1 && row[13].p[0] == 't' ? "true" : "false");
    jlit(r, ",\"image\":");
    jcell(r, &row[12]);
    jlit(r, ",\"username\":");
    jcell(r, &row[10]);
    jlit(r, "}}");
}

/* article (list, 13 cols, no body): id, slug, title, description, created,
 * updated, tag_list, favorites_count, favorited, username, bio, image, following */
static void emit_article_list(req_t *r, const pgval_t *row)
{
    jlit(r, "{\"slug\":");
    jcell(r, &row[1]);
    jlit(r, ",\"title\":");
    jcell(r, &row[2]);
    jlit(r, ",\"description\":");
    jcell(r, &row[3]);
    jlit(r, ",\"tagList\":");
    put_text_array(r, &row[6]);
    jlit(r, ",\"createdAt\":");
    put_ts(r, &row[4]);
    jlit(r, ",\"updatedAt\":");
    put_ts(r, &row[5]);
    jlit(r, ",\"favorited\":");
    jlit(r, row[8].n == 1 && row[8].p[0] == 't' ? "true" : "false");
    jlit(r, ",\"favoritesCount\":");
    jnum(r, &row[7]);
    jlit(r, ",\"author\":{\"bio\":");
    jcell(r, &row[10]);
    jlit(r, ",\"following\":");
    jlit(r, row[12].n == 1 && row[12].p[0] == 't' ? "true" : "false");
    jlit(r, ",\"image\":");
    jcell(r, &row[11]);
    jlit(r, ",\"username\":");
    jcell(r, &row[9]);
    jlit(r, "}}");
}

/* comment row: id, body, created, updated, username, bio, image[, following] */
static void emit_comment(req_t *r, const pgval_t *row, uint32_t ncols)
{
    jlit(r, "{\"id\":");
    jnum(r, &row[0]);
    jlit(r, ",\"createdAt\":");
    put_ts(r, &row[2]);
    jlit(r, ",\"updatedAt\":");
    put_ts(r, &row[3]);
    jlit(r, ",\"body\":");
    jcell(r, &row[1]);
    jlit(r, ",\"author\":{\"bio\":");
    jcell(r, &row[5]);
    jlit(r, ",\"following\":");
    if (ncols >= 8)
        jlit(r, row[7].n == 1 && row[7].p[0] == 't' ? "true" : "false");
    else
        jlit(r, "false");
    jlit(r, ",\"image\":");
    jcell(r, &row[6]);
    jlit(r, ",\"username\":");
    jcell(r, &row[4]);
    jlit(r, "}}");
}

/* ================================================================ input helpers */

static span_t seg(req_t *r, int i)
{
    return i < r->nseg ? r->seg[i] : (span_t){ 0 };
}

static int span_ieq(span_t s, const char *lit)
{
    return strlen(lit) == s.n && !memcmp(s.p, lit, s.n);
}

static char *span_dup(req_t *r, span_t s)
{
    char *d = arena_alloc(r, s.n + 1);
    memcpy(d, s.p, s.n);
    d[s.n] = 0;
    return d;
}

/* find a query parameter; value percent-decoded into the arena; 0 if absent */
static span_t q_get(req_t *r, const char *key)
{
    size_t kl = strlen(key);
    const char *p = r->query.p, *e = r->query.p + r->query.n;
    while (p < e) {
        const char *amp = memchr(p, '&', (size_t)(e - p));
        const char *pe = amp ? amp : e;
        const char *eq = memchr(p, '=', (size_t)(pe - p));
        size_t kn = eq ? (size_t)(eq - p) : (size_t)(pe - p);
        if (kn == kl && !memcmp(p, key, kl)) {
            span_t v;
            if (eq) {
                const char *vs = eq + 1;
                size_t vn = (size_t)(pe - vs);
                if (pct_needs(vs, vn)) {
                    char *d = arena_alloc(r, vn + 1);
                    size_t dl = pct_decode(vs, vn, d);
                    if (dl == (size_t)-1) return (span_t){ 0 };
                    v.p = d;
                    v.n = (uint32_t)dl;
                } else {
                    v.p = vs;
                    v.n = (uint32_t)vn;
                }
            } else {
                v.p = "";
                v.n = 0;
            }
            return v;
        }
        p = amp ? amp + 1 : e;
    }
    (void)r;
    return (span_t){ 0 };
}

/* strict non-negative integer: digits only, fits int */
static int parse_int(span_t s, int *out)
{
    if (!s.n || s.n > 9) return 0;
    long v = 0;
    for (uint32_t i = 0; i < s.n; i++) {
        if (s.p[i] < '0' || s.p[i] > '9') return 0;
        v = v * 10 + (s.p[i] - '0');
    }
    *out = (int)v;
    return 1;
}

/* body JSON: {"<wrap>":{...}} -> the inner object, or NULL */
static const char *body_obj(req_t *r, const char *wrap, size_t *n)
{
    if (!r->body.n) return NULL;
    jfield_t f[1] = { { .name = wrap } };
    if (json_fields(r->body.p, r->body.n, f, 1) != JT_OTHER || f[0].type != JT_OTHER) return NULL;
    *n = (size_t)(f[0].ve - f[0].v);
    return f[0].v;
}

/* Extract a named string field. *state: 0 = absent or null (unchanged),
 * 1 = string (span valid, may be empty), -1 = present but not a string. */
static span_t obj_str(req_t *r, const char *s, size_t n, const char *key, int *state)
{
    jfield_t f[1] = { { .name = key } };
    span_t out = { 0 };
    if (state) *state = 0;
    if (json_fields(s, n, f, 1) != JT_OTHER) return out;
    if (f[0].type == JT_NONE || f[0].type == JT_NULL) return out; /* absent */
    if (f[0].type != JT_STRING) {
        if (state) *state = -1;
        return out;
    }
    if (state) *state = 1;
    char *d = arena_alloc(r, (size_t)(f[0].ve - f[0].v) + 1);
    size_t dl = j_unescape(f[0].v, f[0].ve, d);
    if (dl == (size_t)-1) {
        if (state) *state = -1;
        return out;
    }
    out.p = d;
    out.n = (uint32_t)dl;
    return out;
}

/* non-empty string, else fail */
static int nonempty(span_t s) { return s.n > 0; }

/* ================================================================ tags */

static void cb_tags(req_t *r)
{
    if (r->failed) return reply_failed(r);
    pgres_t *res = pg_result(r, 0);
    jlit(r, "{\"tags\":[");
    for (uint32_t i = 0; i < res->nrows; i++) {
        if (i) jlit(r, ",");
        jcell(r, &res->vals[i * res->ncols]);
    }
    jlit(r, "]}");
    srv_reply(r, 200, r->resp.p, r->resp.len);
}

/* ================================================================ register */

static int64_t cell_id(const pgval_t *v)
{
    int64_t id = 0;
    for (uint32_t i = 0; i < v->n; i++)
        if (v->p[i] >= '0' && v->p[i] <= '9') id = id * 10 + (v->p[i] - '0');
    return id;
}

/* format an int64 into the request arena as text */
static const char *int64_span(req_t *r, int64_t v)
{
    char *d = arena_alloc(r, 24);
    char *e = u64_to(d, (uint64_t)(v < 0 ? 0 : v));
    *e = 0;
    return d;
}

static void cb_register_ins(req_t *r)
{
    if (r->failed) return reply_failed(r); /* 23505 -> 422 */
    pgres_t *res = pg_result(r, 0);
    if (res->nrows != 1) return reply_err(r, 500);
    char token[256];
    size_t tl = jwt_issue(cell_id(res->vals), now_realtime(), token, sizeof token);
    if (!tl) return reply_err(r, 500);
    emit_user(r, res->vals, token, tl);
    srv_reply(r, 201, r->resp.p, r->resp.len);
}

static void cb_register_hashed(bcrypt_job_t *j)
{
    req_t *r = j->req;
    if (!j->hash[0]) return reply_err(r, 500);
    const char *params[3] = { r->reg_username, r->reg_email, j->hash };
    pg_add(r, ST_USER_INS, 3, params);
    r->cb = cb_register_ins;
    pg_go(r);
}

/* ================================================================ login */

static void cb_login_user(req_t *r)
{
    if (r->failed) return reply_failed(r);
    pgres_t *res = pg_result(r, 0);
    if (res->nrows != 1) return reply_err(r, 401);
    pgval_t *row = res->vals;
    /* columns: id, username, email, bio, image, password_hash */
    pgval_t *hashv = &row[5];
    if (hashv->n == (uint32_t)-1) return reply_err(r, 401);

    bcrypt_job_t *j = arena_alloc(r, sizeof *j);
    memset(j, 0, sizeof *j);
    j->mode = BCRYPT_VERIFY;
    j->req = r;
    j->done = cb_login_verified;
    size_t pl = r->login_pw ? strlen(r->login_pw) : 0;
    if (pl > BCRYPT_PWMAX - 1) pl = BCRYPT_PWMAX - 1;
    memcpy(j->pw, r->login_pw, pl);
    j->pwlen = pl;
    size_t hl = hashv->n < BCRYPT_HASHLEN ? hashv->n : BCRYPT_HASHLEN;
    memcpy(j->hash, hashv->p, hl);
    j->hash[hl] = 0;
    if (hl != BCRYPT_HASHLEN) return cb_login_verified(j);
    int cost;
    uint8_t salt[16];
    if (bcrypt_parse_hash(j->hash, &cost, salt)) {
        return cb_login_verified(j);
    }
    j->cost = cost;
    memcpy(j->saltbin, salt, 16);
    if (pl > 72 || !ascii_only(j->pw, pl)) j->fallback = 1;
    r->login_row = row;
    r->pending = 1;
    bcrypt_submit(j);
}

static void cb_login_verified(bcrypt_job_t *j)
{
    req_t *r = j->req;
    pgval_t *row = r->login_row;
    if (!j->verified) return reply_err(r, 401);
    char token[256];
    size_t tl = jwt_issue(cell_id(&row[0]), now_realtime(), token, sizeof token);
    if (!tl) return reply_err(r, 500);
    emit_user(r, row, token, tl);
    srv_reply(r, 200, r->resp.p, r->resp.len);
}

static int ascii_only(const char *s, size_t n)
{
    for (size_t i = 0; i < n; i++)
        if ((unsigned char)s[i] >= 0x80) return 0;
    return 1;
}

/* ================================================================ current user */

static void cb_user_get(req_t *r)
{
    if (r->failed) return reply_failed(r);
    pgres_t *res = pg_result(r, 0);
    if (res->nrows != 1) return reply_err(r, 401);
    emit_user(r, res->vals, r->auth_token.p, r->auth_token.n);
    srv_reply(r, 200, r->resp.p, r->resp.len);
}

static void cb_user_put(req_t *r)
{
    if (r->failed) return reply_failed(r); /* unique violation -> 422 */
    pgres_t *res = pg_result(r, 0);
    if (res->nrows != 1) return reply_err(r, 401);
    emit_user(r, res->vals, r->auth_token.p, r->auth_token.n);
    srv_reply(r, 200, r->resp.p, r->resp.len);
}

static void cb_user_put_hashed(bcrypt_job_t *j)
{
    req_t *r = j->req;
    const char *params[6] = {
        int64_span(r, r->viewer), r->upd_email, r->upd_username, j->hash[0] ? j->hash : NULL,
        r->upd_bio, r->upd_image,
    };
    pg_add(r, ST_USER_UPD, 6, params);
    r->cb = cb_user_put;
    pg_go(r);
}

/* ================================================================ profiles */

static void cb_profile(req_t *r)
{
    if (r->failed) return reply_failed(r);
    pgres_t *res = pg_result(r, r->full_idx);
    if (res->nrows != 1) return reply_err(r, 404);
    emit_profile(r, res->vals, res->vals[4].n == 1 && res->vals[4].p[0] == 't');
    srv_reply(r, 200, r->resp.p, r->resp.len);
}

/* ================================================================ articles: lists */

static void cb_list(req_t *r)
{
    if (r->failed) return reply_failed(r);
    pgres_t *page = pg_result(r, 0);
    pgres_t *count = pg_result(r, 1);
    jlit(r, "{\"articles\":[");
    for (uint32_t i = 0; i < page->nrows; i++) {
        if (i) jlit(r, ",");
        emit_article_list(r, page->vals + i * page->ncols);
    }
    jlit(r, "],\"articlesCount\":");
    jnum(r, count->nrows ? count->vals : NULL);
    jlit(r, "}");
    srv_reply(r, 200, r->resp.p, r->resp.len);
}

/* ================================================================ article single */

static void cb_article_full(req_t *r)
{
    if (r->failed) return reply_failed(r);
    pgres_t *res = pg_result(r, r->full_idx);
    if (res->nrows != 1) return reply_err(r, 404);
    jlit(r, "{\"article\":");
    emit_article_full(r, res->vals);
    jlit(r, "}");
    srv_reply(r, 200, r->resp.p, r->resp.len);
}

/* after the article SELECT that decides 404/403 */
static void cb_art_sel(req_t *r)
{
    pgres_t *res = pg_result(r, 0);
    if (res->nrows != 1) return reply_err(r, 404);
    pgval_t *row = res->vals;
    int64_t author = cell_id(&row[1]);
    if (author != r->viewer) return reply_err(r, 403);
    if (r->method == M_PUT) {
        r->nstmts = 0;          /* phase 2: a fresh batch */
        const char *params[4] = { int64_span(r, cell_id(&row[0])), r->art_title,
                                  r->art_desc, r->art_body };
        pg_add(r, ST_ART_UPD, 4, params);
        pg_add(r, ST_ART_FULL_ID, 2,
               (const char *[]){ int64_span(r, r->viewer), int64_span(r, cell_id(&row[0])) });
        r->full_idx = 1;
        r->cb = cb_article_full;
        pg_go(r);
    } else {
        pg_add(r, ST_ART_DEL, 1, (const char *[]){ int64_span(r, cell_id(&row[0])) });
        r->cb = cb_article_del;
        pg_go(r);
    }
}

static void cb_article_del(req_t *r)
{
    if (r->failed) return reply_failed(r);
    srv_reply(r, 204, "", 0);
}

/* after the create-article batch */
static void cb_article_created(req_t *r)
{
    if (r->failed) return reply_failed(r);
    pgres_t *res = pg_result(r, r->full_idx);
    if (res->nrows != 1) return reply_err(r, 500);
    jlit(r, "{\"article\":");
    emit_article_full(r, res->vals);
    jlit(r, "}");
    srv_reply(r, 201, r->resp.p, r->resp.len);
}

/* ================================================================ favorites */

static void cb_favorite(req_t *r)
{
    if (r->failed) return reply_failed(r);
    pgres_t *res = pg_result(r, 1);
    if (res->nrows != 1) return reply_err(r, 404);
    jlit(r, "{\"article\":");
    emit_article_full(r, res->vals);
    jlit(r, "}");
    srv_reply(r, 200, r->resp.p, r->resp.len);
}

/* ================================================================ comments */

static void cb_comments(req_t *r)
{
    if (r->failed) return reply_failed(r);
    pgres_t *res = pg_result(r, 0);
    if (res->nrows == 0) return reply_err(r, 404); /* no such article */
    jlit(r, "{\"comments\":[");
    int first = 1;
    for (uint32_t i = 0; i < res->nrows; i++) {
        pgval_t *row = res->vals + i * res->ncols;
        if (row[0].n == (uint32_t)-1) continue; /* empty thread sentinel */
        if (!first) jlit(r, ",");
        first = 0;
        emit_comment(r, row, res->ncols);
    }
    jlit(r, "]}");
    srv_reply(r, 200, r->resp.p, r->resp.len);
}

static void cb_comment_created(req_t *r)
{
    if (r->failed) return reply_failed(r);
    pgres_t *res = pg_result(r, 0);
    if (res->nrows != 1) return reply_err(r, 404);
    jlit(r, "{\"comment\":");
    emit_comment(r, res->vals, res->ncols);
    jlit(r, "}");
    srv_reply(r, 201, r->resp.p, r->resp.len);
}

/* ================================================================ route */

static int random_salt(uint8_t out[16])
{
    static __thread uint64_t st;
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        ssize_t n = read(fd, out, 16);
        close(fd);
        if (n == 16) return 0;
    }
    for (int i = 0; i < 2; i++) {
        st ^= st << 13; st ^= st >> 7; st ^= st << 17;
        memcpy(out + i * 8, &st, 8);
    }
    return 0;
}

/* auth gates. Required: missing or invalid token -> 401 (already replied).
 * Optional: invalid token -> 401; absent -> anonymous viewer 0. */
static int need_auth(req_t *r)
{
    if (r->auth_bad) { reply_err(r, 401); return 0; }
    if (!r->has_token) { reply_err(r, 401); return 0; }
    if (r->viewer <= 0) { reply_err(r, 401); return 0; }
    return 1;
}

static int opt_auth(req_t *r)
{
    if (r->auth_bad) { reply_err(r, 401); return 0; }
    return 1;
}

/* limit/offset with spec validation: integers, limit 1..100 (default 20),
 * offset >= 0 (default 0); out of range or non-integer -> 422 */
static int parse_page(req_t *r, int *limit, int *offset)
{
    *limit = 20;
    *offset = 0;
    span_t l = q_get(r, "limit");
    span_t o = q_get(r, "offset");
    if (l.p && !parse_int(l, limit)) return 0;
    if (o.p && !parse_int(o, offset)) return 0;
    if (*limit < 1 || *limit > 100 || *offset < 0) return 0;
    return 1;
}

void route(req_t *r)
{
    /* path: /api/<seg0>[/<seg1>...] */
    span_t s0 = seg(r, 0), s1 = seg(r, 1), s2 = seg(r, 2), s3 = seg(r, 3);

    if (r->nseg >= 1 && span_ieq(s0, "tags") && r->method == M_GET && r->nseg == 1) {
        pg_add(r, ST_TAGS, 0, NULL);
        r->cb = cb_tags;
        pg_go(r);
        return;
    }

    if (r->nseg >= 1 && span_ieq(s0, "users")) {
        if (r->nseg == 2 && span_ieq(s1, "login") && r->method == M_POST) {
            size_t n;
            const char *uo = body_obj(r, "user", &n);
            span_t email = uo ? obj_str(r, uo, n, "email", NULL) : (span_t){ 0 };
            span_t pw = uo ? obj_str(r, uo, n, "password", NULL) : (span_t){ 0 };
            if (!nonempty(email) || !nonempty(pw)) return reply_err(r, 422);
            const char *params[1] = { span_dup(r, email) };
            pg_add(r, ST_USER_BY_EMAIL, 1, params);
            r->login_pw = span_dup(r, pw);
            r->cb = cb_login_user;
            pg_go(r);
            return;
        }
        if (r->nseg == 1 && r->method == M_POST) {
            size_t n;
            const char *uo = body_obj(r, "user", &n);
            span_t un = uo ? obj_str(r, uo, n, "username", NULL) : (span_t){ 0 };
            span_t email = uo ? obj_str(r, uo, n, "email", NULL) : (span_t){ 0 };
            span_t pw = uo ? obj_str(r, uo, n, "password", NULL) : (span_t){ 0 };
            if (!nonempty(un) || !nonempty(email) || !nonempty(pw)) return reply_err(r, 422);
            if (pw.n > 72) return reply_err(r, 422); /* Go's bcrypt: password too long */
            bcrypt_job_t *j = arena_alloc(r, sizeof *j);
            memset(j, 0, sizeof *j);
            j->mode = BCRYPT_HASH;
            j->cost = 10;
            j->req = r;
            j->done = cb_register_hashed;
            random_salt(j->saltbin);
            size_t pl = pw.n < BCRYPT_PWMAX - 1 ? pw.n : BCRYPT_PWMAX - 1;
            memcpy(j->pw, pw.p, pl);
            j->pwlen = pl;
            if (pl > 72 || !ascii_only(j->pw, pl)) j->fallback = 1;
            r->reg_username = span_dup(r, un);
            r->reg_email = span_dup(r, email);
            r->pending = 1;
            bcrypt_submit(j);
            return;
        }
        return reply_err(r, 404);
    }

    if (r->nseg == 1 && span_ieq(s0, "user")) {
        if (r->nseg == 1 && r->method == M_GET) {
            if (!need_auth(r)) return;
            pg_add(r, ST_USER_BY_ID, 1, (const char *[]){ int64_span(r, r->viewer) });
            r->cb = cb_user_get;
            pg_go(r);
            return;
        }
        if (r->nseg == 1 && r->method == M_PUT) {
            if (!need_auth(r)) return;
            size_t n;
            const char *uo = body_obj(r, "user", &n);
            if (!uo) return reply_err(r, 422);
            int st_email = 0, st_un = 0, st_pw = 0, st_bio = 0, st_image = 0;
            span_t email = obj_str(r, uo, n, "email", &st_email);
            span_t un = obj_str(r, uo, n, "username", &st_un);
            span_t pw = obj_str(r, uo, n, "password", &st_pw);
            span_t bio = obj_str(r, uo, n, "bio", &st_bio);
            span_t image = obj_str(r, uo, n, "image", &st_image);
            if (st_email < 0 || st_un < 0 || st_pw < 0 || st_bio < 0 || st_image < 0)
                return reply_err(r, 422);
            if ((st_email == 1 && !nonempty(email)) || (st_un == 1 && !nonempty(un)))
                return reply_err(r, 422);
            /* null/absent mean unchanged; empty-string email/username are 422 */
            r->upd_email = st_email == 1 ? span_dup(r, email) : NULL;
            r->upd_username = st_un == 1 ? span_dup(r, un) : NULL;
            r->upd_bio = st_bio == 1 ? span_dup(r, bio) : NULL;
            r->upd_image = st_image == 1 ? span_dup(r, image) : NULL;
            if (st_pw == 1) {
                bcrypt_job_t *j = arena_alloc(r, sizeof *j);
                memset(j, 0, sizeof *j);
                j->mode = BCRYPT_HASH;
                j->cost = 10;
                j->req = r;
                j->done = cb_user_put_hashed;
                random_salt(j->saltbin);
                size_t pl = pw.n < BCRYPT_PWMAX - 1 ? pw.n : BCRYPT_PWMAX - 1;
                memcpy(j->pw, pw.p, pl);
                j->pwlen = pl;
                if (pl > 72 || !ascii_only(j->pw, pl)) j->fallback = 1;
                r->pending = 1;
                bcrypt_submit(j);
            } else if (st_pw < 0) {
                return reply_err(r, 422);
            } else {
                cb_user_put_hashed(&(bcrypt_job_t){ .req = r, .hash = "" });
            }
            return;
        }
        return reply_err(r, 404);
    }

    if (r->nseg >= 2 && span_ieq(s0, "profiles")) {
        if (r->nseg == 2 && r->method == M_GET) {
            if (!opt_auth(r)) return;
            pg_add(r, ST_PROFILE, 2,
                   (const char *[]){ int64_span(r, r->viewer), span_dup(r, s1) });
            r->cb = cb_profile;
            pg_go(r);
            return;
        }
        if (r->nseg == 3 && span_ieq(s2, "follow") &&
            (r->method == M_POST || r->method == M_DELETE)) {
            if (!need_auth(r)) return;
            if (r->method == M_POST) {
                pg_add(r, ST_FOLLOW, 2,
                       (const char *[]){ int64_span(r, r->viewer), span_dup(r, s1) });
            } else {
                pg_add(r, ST_UNFOLLOW, 2,
                       (const char *[]){ int64_span(r, r->viewer), span_dup(r, s1) });
            }
            pg_add(r, ST_PROFILE, 2,
                   (const char *[]){ int64_span(r, r->viewer), span_dup(r, s1) });
            r->full_idx = 1;
            r->cb = cb_profile;
            pg_go(r);
            return;
        }
        return reply_err(r, 404);
    }

    if (r->nseg >= 1 && span_ieq(s0, "articles")) {
        if (r->nseg == 1 && r->method == M_GET) {
            if (!opt_auth(r)) return;
            int limit, offset;
            if (!parse_page(r, &limit, &offset)) return reply_err(r, 422);
            span_t tag = q_get(r, "tag");
            span_t author = q_get(r, "author");
            span_t fav = q_get(r, "favorited");
            char lim[16], off[16];
            snprintf(lim, sizeof lim, "%d", limit);
            snprintf(off, sizeof off, "%d", offset);
            const char *common[4] = { int64_span(r, r->viewer), lim, off, NULL };
            if (tag.n) {
                common[3] = span_dup(r, tag);
                pg_add(r, ST_LIST_TAG, 4, common);
                pg_add(r, ST_LIST_TAG_COUNT, 1, (const char *[]){ common[3] });
            } else if (author.n) {
                common[3] = span_dup(r, author);
                pg_add(r, ST_LIST_AUTHOR, 4, common);
                pg_add(r, ST_LIST_AUTHOR_COUNT, 1, (const char *[]){ common[3] });
            } else if (fav.n) {
                common[3] = span_dup(r, fav);
                pg_add(r, ST_LIST_FAV, 4, common);
                pg_add(r, ST_LIST_FAV_COUNT, 1, (const char *[]){ common[3] });
            } else {
                pg_add(r, ST_LIST, 3, common);
                pg_add(r, ST_LIST_COUNT, 0, NULL);
            }
            r->cb = cb_list;
            pg_go(r);
            return;
        }
        if (r->nseg == 2 && span_ieq(s1, "feed") && r->method == M_GET) {
            if (!need_auth(r)) return;
            int limit, offset;
            if (!parse_page(r, &limit, &offset)) return reply_err(r, 422);
            char lim[16], off[16];
            snprintf(lim, sizeof lim, "%d", limit);
            snprintf(off, sizeof off, "%d", offset);
            const char *params[3] = { int64_span(r, r->viewer), lim, off };
            pg_add(r, ST_FEED, 3, params);
            pg_add(r, ST_FEED_COUNT, 1, (const char *[]){ params[0] });
            r->cb = cb_list;
            pg_go(r);
            return;
        }
        if (r->nseg == 1 && r->method == M_POST) {
            if (!need_auth(r)) return;
            size_t n;
            const char *ao = body_obj(r, "article", &n);
            if (!ao) return reply_err(r, 422);
            int st_t = 0, st_d = 0, st_b = 0;
            span_t title = obj_str(r, ao, n, "title", &st_t);
            span_t desc = obj_str(r, ao, n, "description", &st_d);
            span_t body = obj_str(r, ao, n, "body", &st_b);
            if (st_t != 1 || st_d != 1 || st_b != 1 ||
                !nonempty(title) || !nonempty(desc) || !nonempty(body))
                return reply_err(r, 422);
            r->art_title = span_dup(r, title);
            r->art_desc = span_dup(r, desc);
            r->art_body = span_dup(r, body);
            pg_add(r, ST_ART_INS, 4,
                   (const char *[]){ int64_span(r, r->viewer), r->art_title, r->art_desc,
                                     r->art_body });
            /* tags: optional array of non-empty strings; null means absent;
             * anything else that is not an array is a 422 */
            int ntags = 0;
            if (ao) {
                jfield_t tf[1] = { { .name = "tagList" } };
                json_fields(ao, n, tf, 1);
                if (tf[0].type != JT_NONE && tf[0].type != JT_NULL) {
                    if (tf[0].type != JT_OTHER) return reply_err(r, 422);
                    jfield_t els[64];
                    int cnt = json_array(tf[0].v, (size_t)(tf[0].ve - tf[0].v), els, 64);
                    if (cnt < 0) return reply_err(r, 422);
                    char *names[64];
                    for (int i = 0; i < cnt; i++) {
                        if (els[i].type != JT_STRING) return reply_err(r, 422);
                        char *d = arena_alloc(r, (size_t)(els[i].ve - els[i].v) + 1);
                        size_t dl = j_unescape(els[i].v, els[i].ve, d);
                        if (dl == (size_t)-1 || dl == 0) return reply_err(r, 422);
                        d[dl] = 0;
                        names[ntags++] = d;
                        if (ntags == 64) break;
                    }
                    if (ntags) {
                        /* serialize as a PG text[] literal */
                        char *t = (char *)r->tag_json;
                        *t++ = '{';
                        for (int i = 0; i < ntags; i++) {
                            if (i) *t++ = ',';
                            for (const char *c = names[i]; *c; c++) {
                                if (*c == ',' || *c == '{' || *c == '}' || *c == '"' || *c == '\\')
                                    *t++ = '\\';
                                *t++ = *c;
                            }
                        }
                        *t++ = '}';
                        *t = 0;
                        pg_add(r, ST_TAGS_INS, 1, (const char *[]){ (char *)r->tag_json });
                        pg_add(r, ST_ARTTAGS_INS, 1, (const char *[]){ (char *)r->tag_json });
                    }
                }
            }
            pg_add(r, ST_ART_LAST, 1, (const char *[]){ int64_span(r, r->viewer) });
            r->full_idx = ntags ? 3 : 1;
            r->cb = cb_article_created;
            pg_go(r);
            return;
        }
        if (r->nseg >= 2) {
            span_t slug = s1;
            if (r->nseg == 2 && r->method == M_GET) {
                if (!opt_auth(r)) return;
                pg_add(r, ST_ART_FULL_SLUG, 2,
                       (const char *[]){ int64_span(r, r->viewer), span_dup(r, slug) });
                r->full_idx = 0;
                r->cb = cb_article_full;
                pg_go(r);
                return;
            }
            if (r->nseg == 2 && r->method == M_PUT) {
                if (!need_auth(r)) return;
                size_t n;
                const char *ao = body_obj(r, "article", &n);
                if (!ao) return reply_err(r, 422);
                int ht = 0, hd = 0, hb = 0;
                span_t title = obj_str(r, ao, n, "title", &ht);
                span_t desc = obj_str(r, ao, n, "description", &hd);
                span_t body = obj_str(r, ao, n, "body", &hb);
                if (ht < 0 || hd < 0 || hb < 0) return reply_err(r, 422);
                if ((ht == 1 && !nonempty(title)) || (hd == 1 && !nonempty(desc)) ||
                    (hb == 1 && !nonempty(body)))
                    return reply_err(r, 422);
                r->art_title = ht == 1 ? span_dup(r, title) : NULL;
                r->art_desc = hd == 1 ? span_dup(r, desc) : NULL;
                r->art_body = hb == 1 ? span_dup(r, body) : NULL;
                pg_add(r, ST_ART_SEL, 1, (const char *[]){ span_dup(r, slug) });
                r->cb = cb_art_sel;
                pg_go(r);
                return;
            }
            if (r->nseg == 2 && r->method == M_DELETE) {
                if (!need_auth(r)) return;
                pg_add(r, ST_ART_SEL, 1, (const char *[]){ span_dup(r, slug) });
                r->cb = cb_art_sel;
                pg_go(r);
                return;
            }
            if (r->nseg == 3 && span_ieq(s2, "favorite") &&
                (r->method == M_POST || r->method == M_DELETE)) {
                if (!need_auth(r)) return;
                if (r->method == M_POST)
                    pg_add(r, ST_FAV_INS, 2,
                           (const char *[]){ int64_span(r, r->viewer), span_dup(r, slug) });
                else
                    pg_add(r, ST_FAV_DEL, 2,
                           (const char *[]){ int64_span(r, r->viewer), span_dup(r, slug) });
                pg_add(r, ST_ART_FULL_SLUG, 2,
                       (const char *[]){ int64_span(r, r->viewer), span_dup(r, slug) });
                r->full_idx = 1;
                r->cb = cb_favorite;
                pg_go(r);
                return;
            }
            if (r->nseg == 3 && span_ieq(s2, "comments")) {
                if (r->method == M_GET) {
                    if (!opt_auth(r)) return;
                    pg_add(r, ST_COMMENTS, 2,
                           (const char *[]){ int64_span(r, r->viewer), span_dup(r, slug) });
                    r->cb = cb_comments;
                    pg_go(r);
                    return;
                }
                if (r->method == M_POST) {
                    if (!need_auth(r)) return;
                    size_t n;
                    const char *co = body_obj(r, "comment", &n);
                    span_t body = co ? obj_str(r, co, n, "body", NULL) : (span_t){ 0 };
                    if (!nonempty(body)) return reply_err(r, 422);
                    pg_add(r, ST_COMMENT_INS, 3,
                           (const char *[]){ span_dup(r, slug), int64_span(r, r->viewer),
                                             span_dup(r, body) });
                    r->cb = cb_comment_created;
                    pg_go(r);
                    return;
                }
                return reply_err(r, 404);
            }
            if (r->nseg == 4 && span_ieq(s2, "comments") && r->method == M_DELETE) {
                if (!need_auth(r)) return;
                int64_t cid = 0;
                if (s3.n == 0 || s3.n > 18) return reply_err(r, 404);
                for (uint32_t i = 0; i < s3.n; i++) {
                    if (s3.p[i] < '0' || s3.p[i] > '9') return reply_err(r, 404);
                    cid = cid * 10 + (s3.p[i] - '0');
                }
                if (cid <= 0) return reply_err(r, 404);
                pg_add(r, ST_COMMENT_DEL, 3,
                       (const char *[]){ int64_span(r, cid), span_dup(r, slug),
                                         int64_span(r, r->viewer) });
                r->cb = cb_comment_deleted;
                pg_go(r);
                return;
            }
        }
        return reply_err(r, 404);
    }

    reply_err(r, 404);
}

static void cb_comment_deleted(req_t *r)
{
    if (r->failed) return reply_failed(r);
    pgres_t *res = pg_result(r, 0);
    if (res->nrows != 1) return reply_err(r, 404);
    pgval_t *row = res->vals;
    /* row: author_id, deleted */
    if (row[1].n != 1 || row[1].p[0] != '1') return reply_err(r, 403);
    srv_reply(r, 204, "", 0);
}
