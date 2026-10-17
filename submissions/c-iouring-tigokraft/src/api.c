// Routing, auth, validation and the 19 endpoints. Each request is one Postgres round trip (one pipelined
// batch); only login/register/password change add a bcrypt step. The SQL is SPEC.md's, folded so that the
// "look up, then act" pairs travel in one batch; the answers come out the same.
#include "conduit.h"
#include <math.h>
#include <time.h>

#define INT8 20
#define TEXT 25
#define TEXTARR 1009

enum {
    S_TAGS, S_USER_BY_ID, S_LOGIN, S_REGISTER, S_UPDATE_USER,
    S_PROFILE, S_FOLLOW, S_UNFOLLOW, S_USER_BY_NAME,
    S_LIST_ALL, S_LIST_TAG, S_LIST_AUTHOR, S_LIST_FAV, S_FEED,
    S_ARTICLE_BY_SLUG, S_ARTICLE_LAST, S_INSERT_ARTICLE, S_INSERT_TAGS, S_INSERT_ARTICLE_TAGS,
    S_ARTICLE_AUTHOR, S_UPDATE_ARTICLE, S_DELETE_ARTICLE, S_FAVORITE, S_UNFAVORITE,
    S_COMMENTS, S_CREATE_COMMENT, S_COMMENT_AUTHOR, S_DELETE_COMMENT,
    S__COUNT
};

#define SLUGIFY(x) "trim(both '-' from lower(regexp_replace(" x ", '[^A-Za-z0-9]+', '-', 'g')))"
// Columns after the article's own: tag_list, favorites_count, favorited, username, bio, image, following.
// Tag names are looked up per tag by primary key: as a join, the generic plan hashes all 200 tags per article.
#define ART_TAIL(A)                                                                                            \
    "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at "                    \
    "WHERE at.article_id = " A ".id ORDER BY 1), (SELECT count(*) FROM favorites f WHERE f.article_id = " A ".id), " \
    "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = " A ".id AND f.user_id = $1), "                    \
    "u.username, u.bio, u.image, "                                                                             \
    "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = " A ".author_id)"
#define FULL_SELECT "SELECT a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, " ART_TAIL("a") \
                    " FROM articles a JOIN users u ON u.id = a.author_id"
// One statement per list: the capped count, then the page. The page's ids are picked first (LIMIT/OFFSET on
// the bare index walk) and the per-article subqueries run only for the rows returned, never for the rows
// OFFSET skips. Row layout: count, then slug ... following; a page with no rows is one row with a NULL slug.
// $1 viewer, $2 limit, $3 offset, $4 filter.
#define PAGE_COLS "a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id"
#define LIST_Q(COUNT, PAGE)                                                                                    \
    "SELECT cnt.n, p.slug, p.title, p.description, p.created_at, p.updated_at, " ART_TAIL("p")                \
    " FROM (SELECT count(*) AS n FROM (" COUNT " LIMIT 1000) s) cnt LEFT JOIN LATERAL (" PAGE ") p ON true "  \
    "LEFT JOIN users u ON u.id = p.author_id ORDER BY p.id DESC"
#define LAST_ID "(SELECT currval(pg_get_serial_sequence('articles', 'id')))"

const stmt_def_t STMTS[] = {
    [S_TAGS] = {"SELECT name FROM tags ORDER BY name", 0, {0}},
    [S_USER_BY_ID] = {"SELECT username, email, bio, image FROM users WHERE id = $1", 1, {INT8}},
    [S_LOGIN] = {"SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1", 1, {TEXT}},
    [S_REGISTER] = {"INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) "
                    "RETURNING id, username, email, bio, image", 3, {TEXT, TEXT, TEXT}},
    [S_UPDATE_USER] = {"UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), "
                       "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) "
                       "WHERE id = $1 RETURNING id, username, email, bio, image", 6, {INT8, TEXT, TEXT, TEXT, TEXT, TEXT}},
    [S_PROFILE] = {"SELECT u.username, u.bio, u.image, "
                   "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) "
                   "FROM users u WHERE u.username = $2", 2, {INT8, TEXT}},
    [S_FOLLOW] = {"INSERT INTO follows (follower_id, followee_id) SELECT $1, u.id FROM users u WHERE u.username = $2 "
                  "ON CONFLICT DO NOTHING", 2, {INT8, TEXT}},
    [S_UNFOLLOW] = {"DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT u.id FROM users u WHERE u.username = $2)",
                    2, {INT8, TEXT}},
    [S_USER_BY_NAME] = {"SELECT username, bio, image FROM users WHERE username = $1", 1, {TEXT}},

    // limit is validated to 1-100, so OFFSET $3 LIMIT 100 inside and LIMIT $2 outside return the same rows as
    // LIMIT $2 OFFSET $3. A bare LIMIT $2 makes the generic plan assume 10% of the table, which picks a Memoize
    // node for the users join that zeroes a huge hash table on every execution.
    [S_LIST_ALL] = {LIST_Q("SELECT 1 FROM articles a",
                           "SELECT " PAGE_COLS " FROM (SELECT " PAGE_COLS " FROM articles a ORDER BY a.id DESC "
                           "OFFSET $3 LIMIT 100) a LIMIT $2"),
                    3, {INT8, INT8, INT8}},
    [S_LIST_TAG] = {LIST_Q("SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4)",
                           "SELECT " PAGE_COLS " FROM articles a WHERE a.id IN (SELECT at.article_id FROM article_tags at "
                           "WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) "
                           "ORDER BY at.article_id DESC LIMIT $2 OFFSET $3)"),
                    4, {INT8, INT8, INT8, TEXT}},
    [S_LIST_AUTHOR] = {LIST_Q("SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4)",
                              "SELECT " PAGE_COLS " FROM articles a WHERE a.author_id = "
                              "(SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a.id DESC LIMIT $2 OFFSET $3"),
                       4, {INT8, INT8, INT8, TEXT}},
    [S_LIST_FAV] = {LIST_Q("SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4)",
                           "SELECT " PAGE_COLS " FROM articles a WHERE a.id IN (SELECT f.article_id FROM favorites f "
                           "WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) "
                           "ORDER BY f.article_id DESC LIMIT $2 OFFSET $3)"),
                    4, {INT8, INT8, INT8, TEXT}},
    [S_FEED] = {LIST_Q("SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)",
                       "SELECT " PAGE_COLS " FROM articles a WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL "
                       "(SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC "
                       "LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3)"),
                3, {INT8, INT8, INT8}},

    [S_ARTICLE_BY_SLUG] = {FULL_SELECT " WHERE a.slug = $2", 2, {INT8, TEXT}},
    [S_ARTICLE_LAST] = {FULL_SELECT " WHERE a.id = " LAST_ID, 1, {INT8}},
    [S_INSERT_ARTICLE] = {"INSERT INTO articles (id, slug, author_id, title, description, body) "
                          "SELECT n.id, " SLUGIFY("$2") " || '-' || n.id, $1, $2, $3, $4 "
                          "FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id",
                          4, {INT8, TEXT, TEXT, TEXT}},
    [S_INSERT_TAGS] = {"INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING", 1, {TEXTARR}},
    [S_INSERT_ARTICLE_TAGS] = {"INSERT INTO article_tags (article_id, tag_id) SELECT " LAST_ID ", t.id FROM tags t "
                               "WHERE t.name = ANY($1::text[])", 1, {TEXTARR}},
    [S_ARTICLE_AUTHOR] = {"SELECT author_id FROM articles WHERE slug = $1", 1, {TEXT}},
    // The UPDATE and the read of its result in one statement: the article row comes from RETURNING, and the
    // tables the read joins (tags, favorites, follows, users) aren't touched by the UPDATE.
    [S_UPDATE_ARTICLE] = {"WITH upd AS (UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description), "
                          "body = COALESCE($5, body), slug = CASE WHEN $3::text IS NULL THEN slug ELSE " SLUGIFY("$3")
                          " || '-' || id END, updated_at = now() WHERE slug = $2 AND author_id = $1 "
                          "RETURNING id, slug, title, description, body, created_at, updated_at, author_id) "
                          "SELECT upd.slug, upd.title, upd.description, upd.body, upd.created_at, upd.updated_at, " ART_TAIL("upd")
                          " FROM upd JOIN users u ON u.id = upd.author_id", 5, {INT8, TEXT, TEXT, TEXT, TEXT}},
    [S_DELETE_ARTICLE] = {"DELETE FROM articles WHERE slug = $1 AND author_id = $2", 2, {TEXT, INT8}},
    [S_FAVORITE] = {"INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2 "
                    "ON CONFLICT DO NOTHING", 2, {INT8, TEXT}},
    [S_UNFAVORITE] = {"DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT a.id FROM articles a WHERE a.slug = $2)",
                      2, {INT8, TEXT}},
    // No row: no such article. One row with a NULL id: an article without comments.
    [S_COMMENTS] = {"SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, "
                    "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) "
                    "FROM articles a LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id "
                    "FROM comments c WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true "
                    "LEFT JOIN users u ON u.id = c.author_id WHERE a.slug = $2 "
                    "ORDER BY c.created_at DESC, c.id DESC", 2, {INT8, TEXT}},
    [S_CREATE_COMMENT] = {"WITH c AS (INSERT INTO comments (article_id, author_id, body) "
                          "SELECT a.id, $1, $3 FROM articles a WHERE a.slug = $2 "
                          "RETURNING id, body, created_at, updated_at, author_id) "
                          "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image "
                          "FROM c JOIN users u ON u.id = c.author_id", 3, {INT8, TEXT, TEXT}},
    [S_COMMENT_AUTHOR] = {"SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id "
                          "WHERE c.id = $1 AND a.slug = $2", 2, {INT8, TEXT}},
    [S_DELETE_COMMENT] = {"DELETE FROM comments c USING articles a WHERE c.id = $1 AND a.id = c.article_id "
                          "AND a.slug = $2 AND c.author_id = $3", 3, {INT8, TEXT, INT8}},
};
const int NSTMTS = S__COUNT;

// ---------- JWT (HS256) ----------

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static bool type_ok(const jv_t *v, int t) { return !v || v->type == J_NULL || v->type == t; }

// golang-jwt v5 semantics: alg must be HS256, signature valid, exp required and in the future (whole seconds),
// nbf (if present) not in the future, registered claims of the right JSON types, sub a positive integer string.
bool jwt_verify(arena_t *a, const char *tok, size_t n, int64_t *sub) {
    if (n > 4096) return false;
    const char *d1 = memchr(tok, '.', n);
    if (!d1) return false;
    const char *d2 = memchr(d1 + 1, '.', tok + n - d1 - 1);
    if (!d2 || memchr(d2 + 1, '.', tok + n - d2 - 1)) return false;
    uint8_t *buf = arena_alloc(a, n);
    long hl = b64url_dec(buf, tok, d1 - tok);
    if (hl < 0) return false;
    jv_t *h = json_parse(a, (char *)buf, hl);
    jv_t *alg = json_get(h, "alg");
    if (!h || h->type != J_OBJ || !alg || alg->type != J_STR || !str_eq(alg->s, "HS256")) return false;
    uint8_t sig[48], mac[32];
    if (tok + n - d2 - 1 > 64 || b64url_dec(sig, d2 + 1, tok + n - d2 - 1) != 32) return false;
    hmac_sha256_k(&CFG.jwt_key, tok, d2 - tok, mac);
    uint8_t diff = 0;
    for (int i = 0; i < 32; i++) diff |= sig[i] ^ mac[i];
    if (diff) return false;
    buf = arena_alloc(a, n);
    long pl = b64url_dec(buf, d1 + 1, d2 - d1 - 1);
    if (pl < 0) return false;
    jv_t *c = json_parse(a, (char *)buf, pl);
    if (!c || c->type != J_OBJ) return false;
    jv_t *exp = json_get(c, "exp"), *nbf = json_get(c, "nbf"), *iat = json_get(c, "iat");
    jv_t *s = json_get(c, "sub"), *iss = json_get(c, "iss"), *jti = json_get(c, "jti"), *aud = json_get(c, "aud");
    if (!type_ok(nbf, J_NUM) || !type_ok(iat, J_NUM) || !type_ok(iss, J_STR) || !type_ok(jti, J_STR)) return false;
    if (aud && aud->type != J_NULL && aud->type != J_STR) {
        if (aud->type != J_ARR) return false;
        for (jv_t *e = aud->child; e; e = e->next)
            if (e->type != J_STR) return false;
    }
    if (!exp || exp->type != J_NUM) return false;
    double now = now_s();
    if (!(now < floor(strtod(arena_strdup(a, exp->s.p, exp->s.n), NULL)))) return false;
    if (nbf && nbf->type == J_NUM && now < floor(strtod(arena_strdup(a, nbf->s.p, nbf->s.n), NULL))) return false;
    if (!s || s->type != J_STR) return false;
    int64_t id;
    if (!parse_uint(s->s.p, s->s.n, &id) || id <= 0) return false;
    *sub = id;
    return true;
}

size_t jwt_issue(char *out, int64_t id) {
    static const char H[] = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"; // {"alg":"HS256","typ":"JWT"}
    long long now = (long long)time(NULL);
    char payload[96];
    int pl = snprintf(payload, sizeof payload, "{\"sub\":\"%lld\",\"iat\":%lld,\"exp\":%lld}", (long long)id, now,
                      now + 30LL * 24 * 3600);
    size_t n = sizeof H - 1;
    memcpy(out, H, n);
    out[n++] = '.';
    n += b64url_enc(out + n, (const uint8_t *)payload, pl);
    uint8_t sig[32];
    hmac_sha256_k(&CFG.jwt_key, out, n, sig);
    out[n++] = '.';
    n += b64url_enc(out + n, sig, 32);
    return n;
}

// ---------- request helpers ----------

static bool qs_unescape(arena_t *a, const char *p, size_t n, str_t *out) {
    char *o = arena_alloc(a, n + 1);
    size_t k = 0;
    for (size_t i = 0; i < n; i++) {
        char c = p[i];
        if (c == '+') c = ' ';
        else if (c == '%') {
            if (i + 2 >= n) return false;
            char h = p[i + 1] | 0x20, l = p[i + 2] | 0x20;
            int hv = h >= '0' && h <= '9' ? h - '0' : h >= 'a' && h <= 'f' ? h - 'a' + 10 : -1;
            int lv = l >= '0' && l <= '9' ? l - '0' : l >= 'a' && l <= 'f' ? l - 'a' + 10 : -1;
            if (hv < 0 || lv < 0 || !((p[i + 1] >= '0' && p[i + 1] <= '9') || hv >= 10) ||
                !((p[i + 2] >= '0' && p[i + 2] <= '9') || lv >= 10))
                return false;
            c = hv << 4 | lv;
            i += 2;
        }
        o[k++] = c;
    }
    *out = (str_t){o, k};
    return true;
}

// The first value of key in the query string (Go url.ParseQuery + Values.Get semantics); false if absent.
static bool query_get(req_t *r, const char *key, str_t *val) {
    const char *p = r->query.p, *e = p + r->query.n;
    if (!p) return false;
    size_t kl = strlen(key);
    while (p < e) {
        const char *amp = memchr(p, '&', e - p);
        const char *pe = amp ? amp : e;
        if (pe > p && !memchr(p, ';', pe - p)) {
            const char *eq = memchr(p, '=', pe - p);
            const char *ke = eq ? eq : pe;
            str_t k;
            if (qs_unescape(&r->arena, p, ke - p, &k) && k.n == kl && memcmp(k.p, key, kl) == 0) {
                str_t v = {"", 0};
                if (!eq || qs_unescape(&r->arena, eq + 1, pe - eq - 1, &v)) {
                    *val = v;
                    return true;
                }
            }
        }
        p = amp ? amp + 1 : e;
    }
    return false;
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

// Absent or null: *out = STR_NULL. A string: *out = it (non-empty if nonempty). Anything else: false.
static bool opt_str(const jv_t *m, const char *k, bool nonempty, str_t *out) {
    jv_t *v = json_get(m, k);
    *out = STR_NULL;
    if (!v || v->type == J_NULL) return true;
    if (v->type != J_STR || (nonempty && v->s.n == 0)) return false;
    *out = v->s;
    return true;
}

static bool req_str(const jv_t *m, const char *k, str_t *out) { return opt_str(m, k, true, out) && out->p; }

static int64_t fld_i64(pgf_t f) {
    int64_t v = 0;
    return f.n > 0 && parse_uint(f.p, f.n, &v) ? v : -1;
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

// ---------- JSON output ----------

static void emit_ts(buf_t *b, pgf_t f) { // "2025-04-01 12:00:00.123456+00" -> "2025-04-01T12:00:00.123Z"
    if (f.n < 19) { buf_lit(b, "null"); return; }
    char o[26];
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
    buf_put(b, o, 26);
}

static void emit_bool(buf_t *b, pgf_t f) {
    if (f.n > 0 && f.p[0] == 't') buf_lit(b, "true");
    else buf_lit(b, "false");
}

static void emit_str(buf_t *b, pgf_t f) {
    if (f.n < 0) buf_lit(b, "null");
    else buf_json_str(b, f.p, f.n);
}

// A Postgres text[] in text form ({a,"b c"}) as a JSON array.
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
                buf_json_str(b, s, p - s);
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

// Row layout: slug, title, description, [body,] created_at, updated_at, tag_list, favorites_count, favorited,
// username, bio, image, following.
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
    buf_put(b, f[k + 3].p, f[k + 3].n > 0 ? f[k + 3].n : 0);
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
    pgbatch_t *b = pg_begin(r, register_done);
    str_t p[3] = {r->s[0], r->s[1], {j->out, strlen(j->out)}};
    pg_stmt(b, S_REGISTER, p);
    pg_end(b);
}

static void h_register(req_t *r) {
    jv_t *m = wrapper(r, "user");
    if (!m) { reply_err(r, 422, "invalid body"); return; }
    str_t pw;
    if (!req_str(m, "username", &r->s[0]) || !req_str(m, "email", &r->s[1]) || !req_str(m, "password", &pw)) {
        reply_err(r, 422, "username, email and password are required");
        return;
    }
    if (!pw_ok(pw)) { reply_err(r, 422, "password is too long"); return; }
    start_bcrypt(r, true, pw, NULL, register_hashed);
}

static void login_verified(req_t *r, job_t *j) {
    if (!j->ok) { reply_err(r, 401, "invalid email or password"); return; }
    const pgst_t *st = &((pgbatch_t *)r->ctx)->st[0];
    char tok[256];
    size_t tn = jwt_issue(tok, fld_i64(pg_get(st, 0, 0)));
    reply_user(r, 200, pg_get(st, 0, 2), tok, tn, pg_get(st, 0, 1), pg_get(st, 0, 3), pg_get(st, 0, 4));
}

static void login_found(req_t *r, pgbatch_t *b) {
    if (!batch_ok(r, b)) return;
    const pgst_t *st = &b->st[0];
    if (st->nrows == 0 || !pw_ok(r->s[0])) { reply_err(r, 401, "invalid email or password"); return; }
    pgf_t h = pg_get(st, 0, 5);
    r->ctx = b;
    start_bcrypt(r, false, r->s[0], arena_strdup(&r->arena, h.p, h.n > 0 ? h.n : 0), login_verified);
}

static void h_login(req_t *r) {
    jv_t *m = wrapper(r, "user");
    if (!m) { reply_err(r, 422, "invalid body"); return; }
    str_t email;
    if (!req_str(m, "email", &email) || !req_str(m, "password", &r->s[0])) {
        reply_err(r, 422, "email and password are required");
        return;
    }
    pgbatch_t *b = pg_begin(r, login_found);
    pg_stmt(b, S_LOGIN, &email);
    pg_end(b);
}

static void get_user_done(req_t *r, pgbatch_t *b) {
    if (!batch_ok(r, b)) return;
    const pgst_t *st = &b->st[0];
    if (st->nrows == 0) { reply_err(r, 401, "unauthorized"); return; }
    reply_user(r, 200, pg_get(st, 0, 1), r->token.p, r->token.n, pg_get(st, 0, 0), pg_get(st, 0, 2), pg_get(st, 0, 3));
}

static void h_get_user(req_t *r) {
    pgbatch_t *b = pg_begin(r, get_user_done);
    str_t p[1] = {viewer_str(r)};
    pg_stmt(b, S_USER_BY_ID, p);
    pg_end(b);
}

static void update_user_done(req_t *r, pgbatch_t *b) {
    if (b->failed && !strcmp(b->sqlstate, "23505")) { reply_err(r, 422, "username or email is already taken"); return; }
    if (!batch_ok(r, b)) return;
    const pgst_t *st = &b->st[0];
    if (st->nrows == 0) { reply_err(r, 401, "unauthorized"); return; }
    reply_user(r, 200, pg_get(st, 0, 2), r->token.p, r->token.n, pg_get(st, 0, 1), pg_get(st, 0, 3), pg_get(st, 0, 4));
}

// r->s: 0 email, 1 username, 2 password hash, 3 bio, 4 image
static void update_user_run(req_t *r) {
    pgbatch_t *b = pg_begin(r, update_user_done);
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
    if (!opt_str(m, "email", true, &r->s[0]) || !opt_str(m, "username", true, &r->s[1]) ||
        !opt_str(m, "password", true, &pw) || !opt_str(m, "bio", false, &r->s[3]) || !opt_str(m, "image", false, &r->s[4])) {
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
    pgbatch_t *b = pg_begin(r, profile_done);
    str_t p[2] = {viewer_str(r), r->seg[1]};
    pg_stmt(b, S_PROFILE, p);
    pg_end(b);
}

static void follow_done(req_t *r, pgbatch_t *b) {
    if (!batch_ok(r, b)) return;
    const pgst_t *st = &b->st[1];
    if (st->nrows == 0) { reply_err(r, 404, "profile not found"); return; }
    reply_profile(r, pg_get(st, 0, 0), pg_get(st, 0, 1), pg_get(st, 0, 2), r->kind);
}

static void h_follow(req_t *r, bool follow) {
    r->kind = follow;
    pgbatch_t *b = pg_begin(r, follow_done);
    str_t p[2] = {viewer_str(r), r->seg[1]};
    pg_stmt(b, follow ? S_FOLLOW : S_UNFOLLOW, p);
    pg_stmt(b, S_USER_BY_NAME, &r->seg[1]);
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
        const pgf_t *f = st->f + (size_t)i * st->ncols;
        if (f[1].n < 0) continue; // empty page
        if (k++) buf_putc(o, ',');
        emit_article(o, f + 1, false);
    }
    buf_lit(o, "],\"articlesCount\":");
    pgf_t n = pg_get(st, 0, 0);
    buf_put(o, n.p, n.n > 0 ? n.n : 0);
    buf_putc(o, '}');
    reply(r, 200, o);
}

static void h_list(req_t *r) {
    if (!limit_offset(r)) { reply_err(r, 422, "limit must be 1-100 and offset >= 0"); return; }
    str_t p[4] = {viewer_str(r), arena_i64(&r->arena, r->limit), arena_i64(&r->arena, r->offset), STR_NULL};
    int ls = S_LIST_ALL;
    if (query_get(r, "tag", &p[3]) && p[3].n) ls = S_LIST_TAG;
    else if (query_get(r, "author", &p[3]) && p[3].n) ls = S_LIST_AUTHOR;
    else if (query_get(r, "favorited", &p[3]) && p[3].n) ls = S_LIST_FAV;
    pgbatch_t *b = pg_begin(r, list_done);
    pg_stmt(b, ls, p);
    pg_end(b);
}

static void h_feed(req_t *r) {
    if (!limit_offset(r)) { reply_err(r, 422, "limit must be 1-100 and offset >= 0"); return; }
    str_t p[3] = {viewer_str(r), arena_i64(&r->arena, r->limit), arena_i64(&r->arena, r->offset)};
    pgbatch_t *b = pg_begin(r, list_done);
    pg_stmt(b, S_FEED, p);
    pg_end(b);
}

static void article_done(req_t *r, pgbatch_t *b) {
    if (!batch_ok(r, b)) return;
    reply_article(r, r->kind ? r->kind : 200, &b->st[b->nst - 1]);
}

static void h_get_article(req_t *r) {
    pgbatch_t *b = pg_begin(r, article_done);
    str_t p[2] = {viewer_str(r), r->seg[1]};
    pg_stmt(b, S_ARTICLE_BY_SLUG, p);
    pg_end(b);
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
    if (!req_str(m, "title", &title) || !req_str(m, "description", &desc) || !req_str(m, "body", &body)) {
        reply_err(r, 422, "title, description and body are required");
        return;
    }
    jv_t *tl = json_get(m, "tagList");
    buf_t arr = {0};
    int ntags = 0;
    if (tl && tl->type != J_NULL) {
        if (tl->type != J_ARR) { reply_err(r, 422, "tagList must be an array of non-empty strings"); return; }
        for (jv_t *e = tl->child; e; e = e->next) {
            if (e->type != J_STR || e->s.n == 0) {
                buf_free(&arr);
                reply_err(r, 422, "tagList must be an array of non-empty strings");
                return;
            }
            buf_putc(&arr, ntags++ ? ',' : '{');
            buf_putc(&arr, '"');
            for (size_t i = 0; i < e->s.n; i++) {
                if (e->s.p[i] == '"' || e->s.p[i] == '\\') buf_putc(&arr, '\\');
                buf_putc(&arr, e->s.p[i]);
            }
            buf_putc(&arr, '"');
        }
        if (ntags) buf_putc(&arr, '}');
    }
    str_t v = viewer_str(r);
    pgbatch_t *b = pg_begin(r, create_article_done);
    str_t p[4] = {v, title, desc, body};
    pg_stmt(b, S_INSERT_ARTICLE, p);
    if (ntags) {
        str_t a = {arr.p, arr.len};
        pg_stmt(b, S_INSERT_TAGS, &a);
        pg_stmt(b, S_INSERT_ARTICLE_TAGS, &a);
    }
    pg_stmt(b, S_ARTICLE_LAST, &v);
    pg_end(b);
    buf_free(&arr);
}

// st[0] is "SELECT author_id ... WHERE slug": 404 if missing, 403 if the viewer isn't the author.
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
    str_t p[5] = {viewer_str(r), r->seg[1]};
    if (!opt_str(m, "title", true, &p[2]) || !opt_str(m, "description", true, &p[3]) || !opt_str(m, "body", true, &p[4])) {
        reply_err(r, 422, "title, description and body must be non-empty strings");
        return;
    }
    pgbatch_t *b = pg_begin(r, update_article_done);
    pg_stmt(b, S_ARTICLE_AUTHOR, &r->seg[1]);
    pg_stmt(b, S_UPDATE_ARTICLE, p);
    pg_end(b);
}

static void delete_done(req_t *r, pgbatch_t *b) {
    if (!own_check(r, b, r->kind ? "comment not found" : "article not found")) return;
    reply(r, 204, NULL);
}

static void h_delete_article(req_t *r) {
    pgbatch_t *b = pg_begin(r, delete_done);
    str_t p[2] = {r->seg[1], viewer_str(r)};
    pg_stmt(b, S_ARTICLE_AUTHOR, &r->seg[1]);
    pg_stmt(b, S_DELETE_ARTICLE, p);
    pg_end(b);
}

static void h_favorite(req_t *r, bool fav) {
    pgbatch_t *b = pg_begin(r, article_done);
    str_t p[2] = {viewer_str(r), r->seg[1]};
    pg_stmt(b, fav ? S_FAVORITE : S_UNFAVORITE, p);
    pg_stmt(b, S_ARTICLE_BY_SLUG, p);
    pg_end(b);
}

// ---------- comments ----------

static void emit_comment(buf_t *o, const pgst_t *st, int i, bool has_following) {
    const pgf_t *f = st->f + (size_t)i * st->ncols;
    buf_lit(o, "{\"id\":");
    buf_put(o, f[0].p, f[0].n > 0 ? f[0].n : 0);
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
        if (pg_get(st, i, 0).n < 0) continue; // article without comments
        if (k++) buf_putc(o, ',');
        emit_comment(o, st, i, true);
    }
    buf_lit(o, "]}");
    reply(r, 200, o);
}

static void h_comments(req_t *r) {
    pgbatch_t *b = pg_begin(r, comments_done);
    str_t p[2] = {viewer_str(r), r->seg[1]};
    pg_stmt(b, S_COMMENTS, p);
    pg_end(b);
}

static void create_comment_done(req_t *r, pgbatch_t *b) {
    if (!batch_ok(r, b)) return;
    const pgst_t *st = &b->st[0];
    if (st->nrows == 0) { reply_err(r, 404, "article not found"); return; }
    buf_t *o = body_start(r);
    buf_lit(o, "{\"comment\":");
    emit_comment(o, st, 0, false);
    buf_putc(o, '}');
    reply(r, 201, o);
}

static void h_create_comment(req_t *r) {
    jv_t *m = wrapper(r, "comment");
    str_t body;
    if (!m || !req_str(m, "body", &body)) { reply_err(r, 422, "body is required"); return; }
    pgbatch_t *b = pg_begin(r, create_comment_done);
    str_t p[3] = {viewer_str(r), r->seg[1], body};
    pg_stmt(b, S_CREATE_COMMENT, p);
    pg_end(b);
}

static void h_delete_comment(req_t *r) {
    int64_t id;
    if (!parse_uint(r->seg[3].p, r->seg[3].n, &id)) { reply_err(r, 404, "comment not found"); return; }
    r->kind = 1;
    str_t ids = arena_i64(&r->arena, id);
    pgbatch_t *b = pg_begin(r, delete_done);
    str_t p[3] = {ids, r->seg[1], viewer_str(r)};
    pg_stmt(b, S_COMMENT_AUTHOR, p);
    pg_stmt(b, S_DELETE_COMMENT, p);
    pg_end(b);
}

// ---------- tags ----------

static void tags_done(req_t *r, pgbatch_t *b) {
    if (!batch_ok(r, b)) return;
    const pgst_t *st = &b->st[0];
    buf_t *o = body_start(r);
    buf_lit(o, "{\"tags\":[");
    for (int i = 0; i < st->nrows; i++) {
        if (i) buf_putc(o, ',');
        emit_str(o, pg_get(st, i, 0));
    }
    buf_lit(o, "]}");
    reply(r, 200, o);
}

static void h_tags(req_t *r) {
    pgbatch_t *b = pg_begin(r, tags_done);
    pg_stmt(b, S_TAGS, NULL);
    pg_end(b);
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

// 0: no header, 1: valid token, -1: header present but invalid.
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
    }
}
