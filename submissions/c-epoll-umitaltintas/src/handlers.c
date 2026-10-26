// Routing, validation, SQL and response building for the 19 endpoints.
//
// Every request makes one round trip to Postgres where the reference SQL would make several: dependent
// statements are folded into one statement with CTEs, or queued together before one Sync (statements
// before a Sync run in one implicit transaction, so a later statement sees an earlier one's writes).
// Parameters go as text, results come back in binary.
#include "app.h"

#include <stdio.h>
#include <arpa/inet.h>

// ---- SQL ----

#define SLUGIFY(x) "trim(both '-' from lower(regexp_replace(" x ", '[^A-Za-z0-9]+', '-', 'g')))"
// Tag names by primary key: one index probe per tag instead of a join against every tag.
#define TAG_LIST                                                                                          \
  "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at "         \
  "WHERE at.article_id = a.id ORDER BY 1)"
// The article columns for an `a` joined with its author `u`: with or without the body; V = the viewer;
// FAVS = the favorites count, FAVD = favorited, FOLL = following.
#define ART_COLS_X(body, FAVS, FAVD, FOLL)                                                                \
  "a.id, a.slug, a.title, a.description, " body "a.created_at, a.updated_at, " TAG_LIST ", "             \
  FAVS ", " FAVD ", u.username, u.bio, u.image, " FOLL
#define FAVS_OF "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id)"
#define FAVD_OF(V) "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = " V ")"
#define FOLL_OF(V) "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = " V " AND fo.followee_id = a.author_id)"
#define ART_COLS_V(body, V) ART_COLS_X(body, FAVS_OF, FAVD_OF(V), FOLL_OF(V))
#define ART_COLS(body) ART_COLS_V(body, "$1")
#define FULL_SELECT "SELECT " ART_COLS("a.body, ") " FROM articles a JOIN users u ON u.id = a.author_id"
// Batched reads (see pg.c): each waiting request is one row r of the unnested parameter arrays, with its
// ordinal r.i, and runs its own query in a LATERAL subquery. The subqueries are correlated with r (LIMIT,
// OFFSET 0 or r.i > 0 where nothing else ties them to the request), so Postgres runs each request's query
// for that request; with Memoize off, nothing is shared between requests.
#define UNNEST_VK "unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(v, k, i)"
#define UNNEST_L4 "unnest($1::int8[], $2::int8[], $3::int8[], $4::text[]) WITH ORDINALITY AS r(v, l, o, k, i)"
#define UNNEST_L3 "unnest($1::int8[], $2::int8[], $3::int8[]) WITH ORDINALITY AS r(v, l, o, i)"
// the capped count: count(*) over at most 1000 rows
#define COUNT_CAP(q) "(SELECT count(*) FROM (" q " LIMIT 1000) s)"
// the same, for sets that nearly always reach the cap: step over 999 rows first (no aggregation)
#define COUNT_CAP_BIG(q) "(CASE WHEN EXISTS (" q " OFFSET 999) THEN 1000 ELSE " COUNT_CAP(q) " END)"
#define CURRVAL "currval(pg_get_serial_sequence('articles', 'id'))"

// ---- shared batched reads ----
// A batch's requests share what doesn't depend on who is asking: each distinct page key (limit, offset,
// tag/author/...), count key and article is read once per statement, and only favorited / following are
// computed per request. Requests in one statement see one snapshot, and nothing outlives the statement.
// Each CTE is MATERIALIZED so it runs once; the per-key lookups are LATERAL ... LIMIT so generic plans
// probe indexes instead of hashing whole tables.
#define FAVD_R "(r.v > 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = r.v))"
#define FOLL_R "(r.v > 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = a.author_id))"
// the shared columns of each article with id d.id (or slug d.k: cond), its body if body = "a.body, "
#define ENRICH(src, body, cond)                                                                           \
  "SELECT x.* FROM (" src ") d CROSS JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, " body    \
  "a.created_at, a.updated_at, a.author_id, " TAG_LIST " AS tags, " FAVS_OF " AS favs, u.username, "      \
  "u.bio, u.image FROM articles a JOIN users u ON u.id = a.author_id WHERE " cond " LIMIT 1) x"
// A list page: c = one capped count per distinct count key, p = the page's ids per distinct page key
// (ids walks the index for the key d.*; the inner LIMIT 100 is the API's maximum page), a = the articles.
// The count row is always there, so an empty page comes back as one row with a NULL article.
#define SLIST(un, ckeys, cjoin, count, pkeys, pjoin, ids, FOLL)                                           \
  "WITH r AS MATERIALIZED (SELECT * FROM " un "), "                                                       \
  "c AS MATERIALIZED (SELECT d.*, (" count ") AS n FROM (SELECT DISTINCT " ckeys " FROM r) d), "         \
  "p AS MATERIALIZED (SELECT d.*, q.id FROM (SELECT DISTINCT " pkeys " FROM r) d LEFT JOIN LATERAL ("    \
  "SELECT id FROM (" ids " OFFSET d.o LIMIT 100) q ORDER BY id DESC LIMIT d.l) q ON true), "              \
  "a AS MATERIALIZED (" ENRICH("SELECT DISTINCT id FROM p WHERE id IS NOT NULL", "", "a.id = d.id") ") " \
  "SELECT r.i, c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.tags, a.favs, "  \
  FAVD_R ", a.username, a.bio, a.image, " FOLL " FROM r JOIN c ON " cjoin " JOIN p ON " pjoin            \
  " LEFT JOIN a ON a.id = p.id ORDER BY r.i, p.id DESC"
#define PJOIN_LO "p.l = r.l AND p.o = r.o"
#define TAG_ID(k) "(SELECT t.id FROM tags t WHERE t.name = " k ")"
#define USER_ID(k) "(SELECT u.id FROM users u WHERE u.username = " k ")"

enum {
  S_REGISTER, S_LOGIN, S_USER, S_UPD_USER, S_FOLLOW, S_UNFOLLOW,
  S_ART_SLUG, S_ART_ID, S_INS_ART, S_INS_TAGS, S_INS_ATAGS, S_ART_CUR,
  S_OWN, S_UPD_ART, S_DEL_ART, S_FAV, S_UNFAV, S_CMT_ADD, S_CMT_DEL,
  SB_ART, SB_CMT, SB_TAGS, SB_TAGS1, SB_PROF, SB_LALL, SB_LTAG, SB_LAUTH, SB_LFAV, SB_FEED,
  S_COUNT
};

const stmt_t STMTS[] = {
  [S_REGISTER] = {"INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) "
                  "RETURNING id, username, email, bio, image", 3},
  [S_LOGIN] = {"SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1", 1},
  [S_USER] = {"SELECT id, username, email, bio, image FROM users WHERE id = $1", 1},
  [S_UPD_USER] = {"UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), "
                  "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) "
                  "WHERE id = $1 RETURNING id, username, email, bio, image", 6},
  [S_FOLLOW] = {"WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), "
                "i AS (INSERT INTO follows (follower_id, followee_id) SELECT $1::bigint, u.id FROM u ON CONFLICT DO NOTHING) "
                "SELECT username, bio, image FROM u", 2},
  [S_UNFOLLOW] = {"WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), "
                  "d AS (DELETE FROM follows f USING u WHERE f.follower_id = $1 AND f.followee_id = u.id) "
                  "SELECT username, bio, image FROM u", 2},
  [S_ART_SLUG] = {FULL_SELECT " WHERE a.slug = $2", 2},
  [S_ART_ID] = {FULL_SELECT " WHERE a.id = $2", 2},
  [S_INS_ART] = {"INSERT INTO articles (id, slug, author_id, title, description, body) "
                 "SELECT n.id, " SLUGIFY("$2::text") " || '-' || n.id, $1::bigint, $2::text, $3::text, $4::text "
                 "FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id", 4},
  [S_INS_TAGS] = {"INSERT INTO tags (name) SELECT DISTINCT x FROM unnest($1::text[]) AS x ORDER BY 1 "
                  "ON CONFLICT (name) DO NOTHING", 1},
  [S_INS_ATAGS] = {"INSERT INTO article_tags (article_id, tag_id) SELECT " CURRVAL ", t.id FROM tags t "
                   "WHERE t.name = ANY($1::text[])", 1},
  [S_ART_CUR] = {FULL_SELECT " WHERE a.id = (SELECT " CURRVAL ")", 1},
  [S_OWN] = {"SELECT id, author_id FROM articles WHERE slug = $1", 1},
  [S_UPD_ART] = {"UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), "
                 "body = COALESCE($4, body), "
                 "slug = CASE WHEN $2::text IS NULL THEN slug ELSE " SLUGIFY("$2") " || '-' || id END, "
                 "updated_at = now() WHERE id = $1", 4},
  [S_DEL_ART] = {"WITH a AS (SELECT id, author_id FROM articles WHERE slug = $2), "
                 "d AS (DELETE FROM articles x USING a WHERE x.id = a.id AND a.author_id = $1) "
                 "SELECT author_id FROM a", 2},
  // Favorite / unfavorite and read the article back in one statement. The read runs in the statement's
  // snapshot, which doesn't include its own insert/delete, so the count is adjusted by the rows the CTE
  // actually inserted/deleted, and favorited is what the request just made it.
  [S_FAV] = {"WITH x AS (SELECT id FROM articles WHERE slug = $2), "
             "i AS (INSERT INTO favorites (user_id, article_id) SELECT $1::bigint, x.id FROM x ON CONFLICT DO NOTHING RETURNING 1) "
             "SELECT " ART_COLS_X("a.body, ", "(" FAVS_OF " + (SELECT count(*) FROM i))", "true", FOLL_OF("$1"))
             " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT id FROM x)", 2},
  [S_UNFAV] = {"WITH x AS (SELECT id FROM articles WHERE slug = $2), "
               "d AS (DELETE FROM favorites f USING x WHERE f.user_id = $1 AND f.article_id = x.id RETURNING 1) "
               "SELECT " ART_COLS_X("a.body, ", "(" FAVS_OF " - (SELECT count(*) FROM d))", "false", FOLL_OF("$1"))
               " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT id FROM x)", 2},
  [S_CMT_ADD] = {"WITH a AS (SELECT id FROM articles WHERE slug = $3), "
                 "c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $1::bigint, $2::text FROM a "
                 "RETURNING id, body, created_at, updated_at, author_id) "
                 "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image "
                 "FROM c JOIN users u ON u.id = c.author_id", 3},
  [S_CMT_DEL] = {"WITH c AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id "
                 "WHERE c.id = $2 AND a.slug = $3), "
                 "d AS (DELETE FROM comments x USING c WHERE x.id = c.id AND c.author_id = $1) "
                 "SELECT author_id FROM c", 3},
  [SB_ART] = {"WITH r AS MATERIALIZED (SELECT * FROM " UNNEST_VK "), "
               "a AS MATERIALIZED (" ENRICH("SELECT DISTINCT k FROM r", "a.body, ", "a.slug = d.k") ") "
               "SELECT r.i, a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.tags, "
               "a.favs, " FAVD_R ", a.username, a.bio, a.image, " FOLL_R " FROM r JOIN a ON a.slug = r.k ORDER BY r.i", 2},
  // following: the viewer's followees are read once per request (r.fl), not probed per comment
  [SB_CMT] = {"WITH r AS MATERIALIZED (SELECT r.*, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v) AS fl "
              "FROM " UNNEST_VK "), "
              "s AS MATERIALIZED (SELECT d.k, x.aid, c.* FROM (SELECT DISTINCT k FROM r) d CROSS JOIN LATERAL "
              "(SELECT a.id AS aid FROM articles a WHERE a.slug = d.k LIMIT 1) x LEFT JOIN LATERAL ("
              "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, c.author_id "
              "FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = x.aid "
              "ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true) "
              "SELECT r.i, s.aid, s.id, s.body, s.created_at, s.updated_at, s.username, s.bio, s.image, "
              "CASE WHEN s.id IS NOT NULL THEN s.author_id = ANY (r.fl) END FROM r JOIN s ON s.k = r.k "
              "ORDER BY r.i, s.created_at DESC, s.id DESC", 2},
  [SB_TAGS] = {"SELECT r.i, ARRAY(SELECT t.name FROM tags t WHERE r.i > 0 ORDER BY t.name) "
               "FROM generate_series(1::int8, $1::int8) AS r(i)", 1},
  [SB_TAGS1] = {"SELECT 1::int8, ARRAY(SELECT t.name FROM tags t ORDER BY t.name)", 0},
  [SB_PROF] = {"WITH r AS MATERIALIZED (SELECT * FROM " UNNEST_VK "), "
               "u AS MATERIALIZED (SELECT x.* FROM (SELECT DISTINCT k FROM r) d CROSS JOIN LATERAL ("
               "SELECT u.id, u.username, u.bio, u.image FROM users u WHERE u.username = d.k LIMIT 1) x) "
               "SELECT r.i, u.username, u.bio, u.image, (r.v > 0 AND EXISTS (SELECT 1 FROM follows fo "
               "WHERE fo.follower_id = r.v AND fo.followee_id = u.id)) FROM r JOIN u ON u.username = r.k ORDER BY r.i", 2},
  [SB_LALL] = {SLIST(UNNEST_L3, "1 AS z", "true", COUNT_CAP_BIG("SELECT 1 FROM articles a"), "l, o", PJOIN_LO,
                     "SELECT x.id FROM articles x ORDER BY x.id DESC", FOLL_R), 3},
  [SB_LTAG] = {SLIST(UNNEST_L4, "k", "c.k = r.k",
                     COUNT_CAP_BIG("SELECT 1 FROM article_tags at WHERE at.tag_id = " TAG_ID("d.k")), "l, o, k",
                     PJOIN_LO " AND p.k = r.k",
                     "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = " TAG_ID("d.k")
                     " ORDER BY at.article_id DESC", FOLL_R), 4},
  [SB_LAUTH] = {SLIST(UNNEST_L4, "k", "c.k = r.k",
                      COUNT_CAP("SELECT 1 FROM articles a WHERE a.author_id = " USER_ID("d.k")), "l, o, k",
                      PJOIN_LO " AND p.k = r.k",
                      "SELECT x.id FROM articles x WHERE x.author_id = " USER_ID("d.k") " ORDER BY x.id DESC", FOLL_R), 4},
  [SB_LFAV] = {SLIST(UNNEST_L4, "k", "c.k = r.k",
                     COUNT_CAP("SELECT 1 FROM favorites f WHERE f.user_id = " USER_ID("d.k")), "l, o, k",
                     PJOIN_LO " AND p.k = r.k",
                     "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = " USER_ID("d.k")
                     " ORDER BY f.article_id DESC", FOLL_R), 4},
  // every feed article's author is followed in this same snapshot, so `following` is true. Most feeds
  // reach the count cap (85% on the seed), hence COUNT_CAP_BIG; the followees go in as one array, so the
  // count is one index scan over articles_author_idx (idea from rust-epoll-WorriedArrow).
  [SB_FEED] = {SLIST(UNNEST_L3, "v", "c.v = r.v",
                     COUNT_CAP_BIG("SELECT 1 FROM articles a WHERE a.author_id = ANY (ARRAY(SELECT fo.followee_id FROM follows fo "
                                   "WHERE fo.follower_id = d.v)) ORDER BY a.author_id, a.id DESC"),
                     "v, l, o", PJOIN_LO " AND p.v = r.v",
                     "SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 "
                     "WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT (d.l + d.o)) x "
                     "WHERE fo.follower_id = d.v ORDER BY x.id DESC", "true"), 3},
};
const int NSTMTS = S_COUNT;

const bkind_t BKINDS[] = {
  [B_ART] = {SB_ART, "it"},   [B_CMT] = {SB_CMT, "it"},     [B_TAGS] = {SB_TAGS, "", SB_TAGS1},
  [B_PROF] = {SB_PROF, "it"}, [B_LALL] = {SB_LALL, "iii"},  [B_LTAG] = {SB_LTAG, "iiit"},
  [B_LAUTH] = {SB_LAUTH, "iiit"}, [B_LFAV] = {SB_LFAV, "iiit"}, [B_FEED] = {SB_FEED, "iii"},
};

// ---- helpers ----

static inline int64_t be64(const char *p) {
  uint64_t v;
  memcpy(&v, p, 8);
  return (int64_t)__builtin_bswap64(v);
}
static inline int32_t be32(const char *p) {
  uint32_t v;
  memcpy(&v, p, 4);
  return (int32_t)__builtin_bswap32(v);
}

#define GV(r, i, c) PQgetvalue(r, i, c)
#define GL(r, i, c) PQgetlength(r, i, c)
#define GN(r, i, c) PQgetisnull(r, i, c)

static const char *fmt_i64(char *b, int64_t v) {
  snprintf(b, 24, "%lld", (long long)v);
  return b;
}

static bool res_ok(PGresult *r) { return r && PQresultStatus(r) == PGRES_TUPLES_OK; }

static void fail(job_t *j, PGresult *r) {
  fprintf(stderr, "postgres error: %s", r ? PQresultErrorMessage(r) : "no result\n");
  job_error(j, 500, "internal error");
}

static bool unique_violation(PGresult *r) {
  const char *s = r ? PQresultErrorField(r, PG_DIAG_SQLSTATE) : NULL;
  return s && !strcmp(s, "23505");
}

// all results OK (tuples or command)?
static PGresult *first_bad(job_t *j) {
  for (int i = 0; i < j->nres; i++) {
    ExecStatusType st = PQresultStatus(j->res[i]);
    if (st != PGRES_TUPLES_OK && st != PGRES_COMMAND_OK) return j->res[i];
  }
  return NULL;
}

static void put_text(buf_t *b, PGresult *r, int i, int c) {
  if (GN(r, i, c)) buf_lit(b, "null");
  else json_str(b, GV(r, i, c), GL(r, i, c));
}

static void put_bool(buf_t *b, PGresult *r, int i, int c) {
  if (GV(r, i, c)[0]) buf_lit(b, "true");
  else buf_lit(b, "false");
}

static void put_ts(buf_t *b, PGresult *r, int i, int c) { json_ts(b, be64(GV(r, i, c))); }

static void put_text_array(buf_t *b, PGresult *r, int i, int c) {
  const char *p = GV(r, i, c);
  buf_putc(b, '[');
  int ndim = be32(p);
  if (ndim > 0) {
    int n = be32(p + 12);
    const char *q = p + 12 + 8 * ndim;
    for (int k = 0; k < n; k++) {
      int len = be32(q);
      q += 4;
      if (k) buf_putc(b, ',');
      if (len < 0) {
        buf_lit(b, "null");
      } else {
        json_str(b, q, len);
        q += len;
      }
    }
  }
  buf_putc(b, ']');
}

// "author"/"profile" object from columns username, bio, image (+ following column or a fixed value)
static void put_profile(buf_t *b, PGresult *r, int i, int c, int following) {
  buf_lit(b, "{\"username\":");
  put_text(b, r, i, c);
  buf_lit(b, ",\"bio\":");
  put_text(b, r, i, c + 1);
  buf_lit(b, ",\"image\":");
  put_text(b, r, i, c + 2);
  buf_lit(b, ",\"following\":");
  if (following < 0) put_bool(b, r, i, c + 3);
  else if (following) buf_lit(b, "true");
  else buf_lit(b, "false");
  buf_putc(b, '}');
}

// Article from ART_COLS starting at column c0 (with the body when full)
static void put_article(buf_t *b, PGresult *r, int i, int c0, bool full) {
  int c = c0 + (full ? 1 : 0);
  buf_lit(b, "{\"slug\":");
  put_text(b, r, i, c0 + 1);
  buf_lit(b, ",\"title\":");
  put_text(b, r, i, c0 + 2);
  buf_lit(b, ",\"description\":");
  put_text(b, r, i, c0 + 3);
  if (full) {
    buf_lit(b, ",\"body\":");
    put_text(b, r, i, c0 + 4);
  }
  buf_lit(b, ",\"tagList\":");
  put_text_array(b, r, i, 6 + c);
  buf_lit(b, ",\"createdAt\":");
  put_ts(b, r, i, 4 + c);
  buf_lit(b, ",\"updatedAt\":");
  put_ts(b, r, i, 5 + c);
  buf_lit(b, ",\"favorited\":");
  put_bool(b, r, i, 8 + c);
  buf_lit(b, ",\"favoritesCount\":");
  buf_i64(b, be64(GV(r, i, 7 + c)));
  buf_lit(b, ",\"author\":");
  put_profile(b, r, i, 9 + c, -1);
  buf_putc(b, '}');
}

// {"user": ...} from columns id, username, email, bio, image
static void reply_user(job_t *j, PGresult *r, int status, bool fresh_token) {
  buf_t *b = &j->L->body;
  b->len = 0;
  buf_lit(b, "{\"user\":{\"email\":");
  put_text(b, r, 0, 2);
  buf_lit(b, ",\"token\":\"");
  if (fresh_token) {
    char *o = buf_room(b, 256);
    b->len += jwt_issue(o, be64(GV(r, 0, 0)));
  } else {
    buf_put(b, j->token.p, j->token.n);
  }
  buf_lit(b, "\",\"username\":");
  put_text(b, r, 0, 1);
  buf_lit(b, ",\"bio\":");
  put_text(b, r, 0, 3);
  buf_lit(b, ",\"image\":");
  put_text(b, r, 0, 4);
  buf_lit(b, "}}");
  job_reply(j, status);
}

// {"article": ...} from row i of r, article columns starting at c0; no row -> 404
static void reply_article_at(job_t *j, PGresult *r, int i, int c0, bool found, int status) {
  if (!res_ok(r)) return fail(j, r);
  if (!found) return job_error(j, 404, "article not found");
  buf_t *b = &j->L->body;
  b->len = 0;
  buf_lit(b, "{\"article\":");
  put_article(b, r, i, c0, true);
  buf_putc(b, '}');
  job_reply(j, status);
}

static void reply_article(job_t *j, PGresult *r, int status) {
  reply_article_at(j, r, 0, 0, res_ok(r) && PQntuples(r) > 0, status);
}

// ---- handlers ----

static void r_tags(job_t *j) {
  if (!j->R || j->rn != 1) return fail(j, j->R);
  buf_t *b = &j->L->body;
  b->len = 0;
  buf_lit(b, "{\"tags\":");
  put_text_array(b, j->R, j->r0, 1);
  buf_putc(b, '}');
  job_reply(j, 200);
}

static void h_tags(job_t *j) { pg_read(j, B_TAGS, r_tags); }

// POST /api/users
static void r_register(job_t *j) {
  PGresult *r = j->res[0];
  if (unique_violation(r)) return job_error(j, 422, "username or email is already taken");
  if (!res_ok(r) || PQntuples(r) != 1) return fail(j, r);
  reply_user(j, r, 201, true);
}

static void b_register(job_t *j) {
  const char *v[3] = {j->f[0].p, j->f[1].p, j->hash};
  pg_begin_w(j);
  pg_q(j, S_REGISTER, v, NULL);
  pg_end(j, r_register);
}

static void h_register(job_t *j, const char *body, size_t blen) {
  static const char *const keys[] = {"username", "email", "password"};
  if (!json_wrapper(body, blen, "user", keys, 3, j->f, &j->sbuf, NULL, NULL, NULL))
    return job_error(j, 422, "invalid body");
  for (int i = 0; i < 3; i++)
    if (j->f[i].n <= 0) return job_error(j, 422, "username, email and password are required");
  if (j->f[2].n > 72) return job_error(j, 422, "password is too long");
  bcrypt_hash(j, j->f[2], b_register);
}

// POST /api/users/login
static void b_login(job_t *j) {
  if (!j->ok) return job_error(j, 401, "invalid email or password");
  reply_user(j, j->res[0], 200, true);
}

static void r_login(job_t *j) {
  PGresult *r = j->res[0];
  if (!res_ok(r)) return fail(j, r);
  if (PQntuples(r) == 0 || j->f[1].n > 72) return job_error(j, 401, "invalid email or password");
  char *h = malloc(GL(r, 0, 5) + 1);
  memcpy(h, GV(r, 0, 5), GL(r, 0, 5));
  h[GL(r, 0, 5)] = 0;
  bcrypt_check(j, j->f[1], h, b_login);
  free(h);
}

static void h_login(job_t *j, const char *body, size_t blen) {
  static const char *const keys[] = {"email", "password"};
  if (!json_wrapper(body, blen, "user", keys, 2, j->f, &j->sbuf, NULL, NULL, NULL))
    return job_error(j, 422, "invalid body");
  if (j->f[0].n <= 0 || j->f[1].n <= 0) return job_error(j, 422, "email and password are required");
  const char *v[1] = {j->f[0].p};
  pg_begin(j);
  pg_q(j, S_LOGIN, v, NULL);
  pg_end(j, r_login);
}

// GET /api/user
static void r_user(job_t *j) {
  PGresult *r = j->res[0];
  if (unique_violation(r)) return job_error(j, 422, "username or email is already taken");
  if (!res_ok(r)) return fail(j, r);
  if (PQntuples(r) == 0) return job_error(j, 401, "unauthorized");
  reply_user(j, r, 200, false);
}

static void h_user(job_t *j) {
  const char *v[1] = {fmt_i64(j->nb[0], j->viewer)};
  pg_begin(j);
  pg_q(j, S_USER, v, NULL);
  pg_end(j, r_user);
}

// PUT /api/user
static void b_upd_user(job_t *j) {
  const char *v[6] = {fmt_i64(j->nb[0], j->viewer), j->f[0].p, j->f[1].p, j->hash, j->f[3].p, j->f[4].p};
  pg_begin_w(j);
  pg_q(j, S_UPD_USER, v, NULL);
  pg_end(j, r_user);
}

static void h_upd_user(job_t *j, const char *body, size_t blen) {
  static const char *const keys[] = {"email", "username", "password", "bio", "image"};
  if (!json_wrapper(body, blen, "user", keys, 5, j->f, &j->sbuf, NULL, NULL, NULL))
    return job_error(j, 422, "invalid body");
  for (int i = 0; i < 5; i++) {
    if (j->f[i].n == JSON_BAD || (i < 3 && j->f[i].n == 0)) return job_error(j, 422, "invalid user fields");
  }
  if (j->f[2].n > 72) return job_error(j, 422, "password is too long");
  if (j->f[2].n > 0) return bcrypt_hash(j, j->f[2], b_upd_user);
  b_upd_user(j);
}

// GET /api/profiles/:username
static void reply_profile(job_t *j, PGresult *r, int i, int c0, bool found, int following) {
  if (!r) return fail(j, r);
  if (!found) return job_error(j, 404, "profile not found");
  buf_t *b = &j->L->body;
  b->len = 0;
  buf_lit(b, "{\"profile\":");
  put_profile(b, r, i, c0, following);
  buf_putc(b, '}');
  job_reply(j, 200);
}

static void r_profile(job_t *j) { reply_profile(j, j->R, j->r0, 1, j->rn > 0, -1); }

static void r_follow(job_t *j) {
  PGresult *r = j->res[0];
  if (!res_ok(r)) return fail(j, r);
  reply_profile(j, r, 0, 0, PQntuples(r) > 0, (int)j->num[0]);
}

static void h_profile(job_t *j) {
  j->bv[0] = fmt_i64(j->nb[0], j->viewer);
  j->bv[1] = j->seg[1].p;
  pg_read(j, B_PROF, r_profile);
}

static void h_follow(job_t *j, bool on) {
  const char *v[2] = {fmt_i64(j->nb[0], j->viewer), j->seg[1].p};
  j->num[0] = on;
  pg_begin_w(j);
  pg_q(j, on ? S_FOLLOW : S_UNFOLLOW, v, NULL);
  pg_end(j, r_follow);
}

// GET /api/articles, /api/articles/feed
static void r_list(job_t *j) {
  PGresult *r = j->R;
  if (!r || j->rn < 1) return fail(j, r);
  buf_t *b = &j->L->body;
  b->len = 0;
  buf_lit(b, "{\"articles\":[");
  bool first = true;
  for (int i = j->r0; i < j->r0 + j->rn; i++) {
    if (GN(r, i, 2)) continue;  // empty page
    if (!first) buf_putc(b, ',');
    first = false;
    put_article(b, r, i, 2, false);
  }
  buf_lit(b, "],\"articlesCount\":");
  buf_i64(b, be64(GV(r, j->r0, 1)));
  buf_putc(b, '}');
  job_reply(j, 200);
}

// Query string: decode in place. Returns false if a limit/offset is invalid.
static int pct(int c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// decode s[0..n) in place (plus: '+' is a space); NUL-terminates; returns the new length or -1
static int unpct(char *s, int n, bool plus) {
  int o = 0;
  for (int i = 0; i < n; i++) {
    char ch = s[i];
    if (ch == '%') {
      if (i + 2 >= n) return -1;
      int h = pct((unsigned char)s[i + 1]), l = pct((unsigned char)s[i + 2]);
      if (h < 0 || l < 0) return -1;
      s[o++] = h << 4 | l;
      i += 2;
    } else if (ch == '+' && plus) {
      s[o++] = ' ';
    } else {
      s[o++] = ch;
    }
  }
  s[o] = 0;
  return o;
}

static bool parse_uint(const char *s, int n, int64_t *out) {
  if (n <= 0) return false;
  uint64_t v = 0;
  for (int i = 0; i < n; i++) {
    if (s[i] < '0' || s[i] > '9') return false;
    if (v > (uint64_t)INT64_MAX / 10) return false;
    v = v * 10 + (s[i] - '0');
    if (v > (uint64_t)INT64_MAX) return false;
  }
  *out = (int64_t)v;
  return true;
}

// names: limit, offset, tag, author, favorited -> j->f[0..4] (first occurrence; n = -1 if absent)
static void parse_query(job_t *j, char *q, int qlen) {
  static const char *const names[] = {"limit", "offset", "tag", "author", "favorited"};
  for (int i = 0; i < 5; i++) j->f[i] = STR_NONE;
  if (!q) return;
  char *e = q + qlen;
  char *p = q;
  while (p < e) {
    char *amp = memchr(p, '&', e - p);
    char *pe = amp ? amp : e;
    char *next = amp ? amp + 1 : e;
    if (pe == p || memchr(p, ';', pe - p)) {
      p = next;
      continue;
    }
    char *eq = memchr(p, '=', pe - p);
    char *ke = eq ? eq : pe;
    char *v = eq ? eq + 1 : pe;
    int kn = unpct(p, ke - p, true);
    int vn = unpct(v, pe - v, true);
    if (kn >= 0 && vn >= 0) {
      for (int i = 0; i < 5; i++)
        if (j->f[i].n < 0 && (int)strlen(names[i]) == kn && !memcmp(names[i], p, kn)) j->f[i] = (str_t){v, vn};
    }
    p = next;
  }
}

static bool limit_offset(job_t *j) {
  j->num[0] = 20;
  j->num[1] = 0;
  if (j->f[0].n >= 0) {
    if (!parse_uint(j->f[0].p, j->f[0].n, &j->num[0]) || j->num[0] < 1 || j->num[0] > 100) return false;
  }
  if (j->f[1].n >= 0) {
    if (!parse_uint(j->f[1].p, j->f[1].n, &j->num[1])) return false;
  }
  fmt_i64(j->nb[0], j->viewer);
  fmt_i64(j->nb[1], j->num[0]);
  fmt_i64(j->nb[2], j->num[1]);
  return true;
}

static void h_list(job_t *j, char *q, int qlen, bool feed) {
  parse_query(j, q, qlen);
  if (!limit_offset(j)) return job_error(j, 422, "limit must be 1-100 and offset >= 0");
  j->bv[0] = j->nb[0];
  j->bv[1] = j->nb[1];
  j->bv[2] = j->nb[2];
  int kind = B_LALL;
  if (feed) {
    kind = B_FEED;
  } else {
    for (int i = 2; i < 5; i++) {
      if (j->f[i].n > 0) {
        j->bv[3] = j->f[i].p;
        kind = i == 2 ? B_LTAG : i == 3 ? B_LAUTH : B_LFAV;
        break;
      }
    }
  }
  pg_read(j, kind, r_list);
}

// GET /api/articles/:slug
static void r_article(job_t *j) {
  if (!j->R) return fail(j, NULL);
  reply_article_at(j, j->R, j->r0, 1, j->rn > 0, 200);
}

static void h_article(job_t *j) {
  j->bv[0] = fmt_i64(j->nb[0], j->viewer);
  j->bv[1] = j->seg[1].p;
  pg_read(j, B_ART, r_article);
}

// POST /api/articles
static void r_create(job_t *j) {
  PGresult *bad = first_bad(j);
  if (bad) return fail(j, bad);
  reply_article(j, j->res[j->nres - 1], 201);
}

static void h_create(job_t *j, const char *body, size_t blen) {
  static const char *const keys[] = {"title", "description", "body"};
  bool tags_bad = false;
  if (!json_wrapper(body, blen, "article", keys, 3, j->f, &j->sbuf, "tagList", &j->tags, &tags_bad))
    return job_error(j, 422, "invalid body");
  for (int i = 0; i < 3; i++)
    if (j->f[i].n <= 0) return job_error(j, 422, "title, description and body are required");
  if (tags_bad) return job_error(j, 422, "tagList must be an array of non-empty strings");
  const char *v[4] = {fmt_i64(j->nb[0], j->viewer), j->f[0].p, j->f[1].p, j->f[2].p};
  pg_begin_w(j);
  pg_q(j, S_INS_ART, v, NULL);
  if (j->tags) {
    const char *t[1] = {j->tags};
    pg_q(j, S_INS_TAGS, t, NULL);
    pg_q(j, S_INS_ATAGS, t, NULL);
  }
  pg_q(j, S_ART_CUR, v, NULL);
  pg_end(j, r_create);
}

// PUT /api/articles/:slug: look up and check the author, then update and read back
static void r_update2(job_t *j) {
  PGresult *bad = first_bad(j);
  if (bad) return fail(j, bad);
  reply_article(j, j->res[1], 200);
}

static void r_update1(job_t *j) {
  PGresult *r = j->res[0];
  if (!res_ok(r)) return fail(j, r);
  if (PQntuples(r) == 0) return job_error(j, 404, "article not found");
  if (be64(GV(r, 0, 1)) != j->viewer) return job_error(j, 403, "not the author");
  fmt_i64(j->nb[1], be64(GV(r, 0, 0)));
  const char *v[4] = {j->nb[1], j->f[0].p, j->f[1].p, j->f[2].p};
  const char *w[2] = {j->nb[0], j->nb[1]};
  pg_begin_w(j);
  pg_q(j, S_UPD_ART, v, NULL);
  pg_q(j, S_ART_ID, w, NULL);
  pg_end(j, r_update2);
}

static void h_update(job_t *j, const char *body, size_t blen) {
  static const char *const keys[] = {"title", "description", "body"};
  if (!json_wrapper(body, blen, "article", keys, 3, j->f, &j->sbuf, NULL, NULL, NULL))
    return job_error(j, 422, "invalid body");
  for (int i = 0; i < 3; i++)
    if (j->f[i].n == JSON_BAD || j->f[i].n == 0)
      return job_error(j, 422, "title, description and body must be non-empty strings");
  fmt_i64(j->nb[0], j->viewer);
  const char *v[1] = {j->seg[1].p};
  pg_begin(j);
  pg_q(j, S_OWN, v, NULL);
  pg_end(j, r_update1);
}

// DELETE /api/articles/:slug and /api/articles/:slug/comments/:id
static void r_delete(job_t *j) {
  PGresult *r = j->res[0];
  if (!res_ok(r)) return fail(j, r);
  if (PQntuples(r) == 0) return job_error(j, 404, "not found");
  if (be64(GV(r, 0, 0)) != j->viewer) return job_error(j, 403, "not the author");
  j->L->body.len = 0;
  job_reply(j, 204);
}

static void h_delete(job_t *j) {
  const char *v[2] = {fmt_i64(j->nb[0], j->viewer), j->seg[1].p};
  pg_begin_w(j);
  pg_q(j, S_DEL_ART, v, NULL);
  pg_end(j, r_delete);
}

static void h_del_comment(job_t *j) {
  int64_t id;
  if (!parse_uint(j->seg[3].p, j->seg[3].n, &id)) return job_error(j, 404, "comment not found");
  const char *v[3] = {fmt_i64(j->nb[0], j->viewer), fmt_i64(j->nb[1], id), j->seg[1].p};
  pg_begin_w(j);
  pg_q(j, S_CMT_DEL, v, NULL);
  pg_end(j, r_delete);
}

// POST/DELETE /api/articles/:slug/favorite
static void r_favorite(job_t *j) { reply_article(j, j->res[0], 200); }

static void h_favorite(job_t *j, bool on) {
  const char *v[2] = {fmt_i64(j->nb[0], j->viewer), j->seg[1].p};
  pg_begin_w(j);
  pg_q(j, on ? S_FAV : S_UNFAV, v, NULL);
  pg_end(j, r_favorite);
}

// GET /api/articles/:slug/comments
static void put_comment(buf_t *b, PGresult *r, int i, int c0, int following) {
  buf_lit(b, "{\"id\":");
  buf_i64(b, be64(GV(r, i, c0)));
  buf_lit(b, ",\"createdAt\":");
  put_ts(b, r, i, c0 + 2);
  buf_lit(b, ",\"updatedAt\":");
  put_ts(b, r, i, c0 + 3);
  buf_lit(b, ",\"body\":");
  put_text(b, r, i, c0 + 1);
  buf_lit(b, ",\"author\":");
  put_profile(b, r, i, c0 + 4, following);
  buf_putc(b, '}');
}

static void r_comments(job_t *j) {
  PGresult *r = j->R;
  if (!r) return fail(j, r);
  if (j->rn == 0) return job_error(j, 404, "article not found");
  buf_t *b = &j->L->body;
  b->len = 0;
  buf_lit(b, "{\"comments\":[");
  bool first = true;
  for (int i = j->r0; i < j->r0 + j->rn; i++) {
    if (GN(r, i, 2)) continue;  // no comments
    if (!first) buf_putc(b, ',');
    first = false;
    put_comment(b, r, i, 2, -1);
  }
  buf_lit(b, "]}");
  job_reply(j, 200);
}

static void h_comments(job_t *j) {
  j->bv[0] = fmt_i64(j->nb[0], j->viewer);
  j->bv[1] = j->seg[1].p;
  pg_read(j, B_CMT, r_comments);
}

// POST /api/articles/:slug/comments
static void r_add_comment(job_t *j) {
  PGresult *r = j->res[0];
  if (!res_ok(r)) return fail(j, r);
  if (PQntuples(r) == 0) return job_error(j, 404, "article not found");
  buf_t *b = &j->L->body;
  b->len = 0;
  buf_lit(b, "{\"comment\":");
  put_comment(b, r, 0, 0, 0);
  buf_putc(b, '}');
  job_reply(j, 201);
}

static void h_add_comment(job_t *j, const char *body, size_t blen) {
  static const char *const keys[] = {"body"};
  if (!json_wrapper(body, blen, "comment", keys, 1, j->f, &j->sbuf, NULL, NULL, NULL))
    return job_error(j, 422, "invalid body");
  if (j->f[0].n <= 0) return job_error(j, 422, "body is required");
  const char *v[3] = {fmt_i64(j->nb[0], j->viewer), j->f[0].p, j->seg[1].p};
  pg_begin_w(j);
  pg_q(j, S_CMT_ADD, v, NULL);
  pg_end(j, r_add_comment);
}

// ---- routing ----

enum { A_NONE, A_OPTIONAL, A_REQUIRED };

// Authorization header -> j->viewer / j->token. false: respond 401.
static bool authenticate(job_t *j, str_t auth, int mode) {
  j->viewer = 0;
  if (mode == A_NONE) return true;
  if (auth.n <= 0) return mode == A_OPTIONAL;
  if (auth.n < 6 || memcmp(auth.p, "Token ", 6) != 0) return false;
  j->token = (str_t){auth.p + 6, auth.n - 6};
  int64_t uid;
  if (!jwt_verify(j->token.p, j->token.n, &uid)) return false;
  j->viewer = uid;
  return true;
}

#define IS(s, lit) ((s).n == (int)sizeof(lit) - 1 && !memcmp((s).p, lit, sizeof(lit) - 1))

void route(job_t *j, const char *method, int mlen, const char *path, int plen, const char *query, int qlen,
           const char *body, size_t blen, str_t auth) {
  enum { GET, POST, PUT, DEL, OTHER } m = OTHER;
  if (mlen == 3 && !memcmp(method, "GET", 3)) m = GET;
  else if (mlen == 4 && !memcmp(method, "POST", 4)) m = POST;
  else if (mlen == 3 && !memcmp(method, "PUT", 3)) m = PUT;
  else if (mlen == 6 && !memcmp(method, "DELETE", 6)) m = DEL;

  if (plen < 5 || memcmp(path, "/api/", 5) != 0) return job_error(j, 404, "not found");
  // split into segments, then decode each in place (the request copy is ours)
  char *p = (char *)path + 5, *e = (char *)path + plen;
  int ns = 0;
  str_t raw[6];
  for (;;) {
    char *sl = memchr(p, '/', e - p);
    char *se = sl ? sl : e;
    if (ns == 6 || se == p) return job_error(j, 404, "not found");
    raw[ns++] = (str_t){p, (int)(se - p)};
    if (!sl) break;
    p = sl + 1;
  }
  if (query) ((char *)query)[-1] = 0;  // the '?' (segments end there)
  for (int i = 0; i < ns; i++) {
    int n = unpct((char *)raw[i].p, raw[i].n, false);
    if (n < 0) return job_error(j, 400, "bad path");
    j->seg[i] = (str_t){raw[i].p, n};
  }
  j->nseg = ns;
  str_t *s = j->seg;
  char *q = (char *)query;

#define NEED(mode)                                                    \
  do {                                                                \
    if (!authenticate(j, auth, mode)) return job_error(j, 401, "unauthorized"); \
  } while (0)

  if (IS(s[0], "articles")) {
    if (ns == 1) {
      if (m == GET) { NEED(A_OPTIONAL); return h_list(j, q, qlen, false); }
      if (m == POST) { NEED(A_REQUIRED); return h_create(j, body, blen); }
    } else if (ns == 2) {
      if (m == GET && IS(s[1], "feed")) { NEED(A_REQUIRED); return h_list(j, q, qlen, true); }
      if (m == GET) { NEED(A_OPTIONAL); return h_article(j); }
      if (m == PUT) { NEED(A_REQUIRED); return h_update(j, body, blen); }
      if (m == DEL) { NEED(A_REQUIRED); return h_delete(j); }
    } else if (ns == 3 && IS(s[2], "favorite")) {
      if (m == POST || m == DEL) { NEED(A_REQUIRED); return h_favorite(j, m == POST); }
    } else if (ns == 3 && IS(s[2], "comments")) {
      if (m == GET) { NEED(A_OPTIONAL); return h_comments(j); }
      if (m == POST) { NEED(A_REQUIRED); return h_add_comment(j, body, blen); }
    } else if (ns == 4 && IS(s[2], "comments")) {
      if (m == DEL) { NEED(A_REQUIRED); return h_del_comment(j); }
    }
  } else if (IS(s[0], "tags")) {
    if (ns == 1 && m == GET) return h_tags(j);
  } else if (IS(s[0], "profiles")) {
    if (ns == 2 && m == GET) { NEED(A_OPTIONAL); return h_profile(j); }
    if (ns == 3 && IS(s[2], "follow") && (m == POST || m == DEL)) {
      NEED(A_REQUIRED);
      return h_follow(j, m == POST);
    }
  } else if (IS(s[0], "user")) {
    if (ns == 1 && m == GET) { NEED(A_REQUIRED); return h_user(j); }
    if (ns == 1 && m == PUT) { NEED(A_REQUIRED); return h_upd_user(j, body, blen); }
  } else if (IS(s[0], "users")) {
    if (ns == 1 && m == POST) return h_register(j, body, blen);
    if (ns == 2 && m == POST && IS(s[1], "login")) return h_login(j, body, blen);
  }
  job_error(j, 404, "not found");
}
