/* Routing and the 19 endpoints. Each handler validates synchronously (auth 401, body 422), copies what it needs
 * later, then runs as a small state machine driven by Postgres rows, ReadyForQuery and bcrypt completions.
 * Responses are rendered straight from binary DataRows into the response buffer. */
#include "json_in.h"
#include "json_out.h"
#include "plan.h"
#include "util.h"
#include "worker.h"

/* ---- request data ---- */

/* Copies n bytes into the request's own storage (sized at dispatch, so earlier copies never move). */
static const char *keep(struct req *r, const char *s, size_t n) {
    if (r->data_cap - r->data_len < n) die("request storage overflow");
    char *d = r->data + r->data_len;
    memcpy(d, s, n);
    r->data_len += (uint32_t)n;
    return d;
}

static void keep_slot(struct req *r, int slot, const char *s, size_t n) {
    r->s[slot] = s ? keep(r, s, n) : NULL;
    r->sl[slot] = (uint32_t)n;
}

/* ---- statements ---- */

static void unit_begin(struct req *r) {
    r->q.len = 0;
    r->nexec = 0;
    r->rows = 0;
}

static struct req *bind_req;  /* the request whose unit bind_exec is extending */

static void bind_begin(struct req *r, struct pg_bind *pb, enum stmt s) {
    bind_req = r;
    pg_bind_begin(pb, &r->q, stmt_names[s]);
}

static void bind_exec(struct pg_bind *pb) {
    pg_bind_end(pb);
    pg_execute(pb->b);
    bind_req->nexec++;
}

static void bind_opt_text(struct pg_bind *pb, const char *s, uint32_t n) {
    if (s) pg_bind_text(pb, s, n);
    else pg_bind_null(pb);
}

/* ---- rows ---- */

struct cols {
    const uint8_t *v[SQL_MAX_COLS];
    int32_t n[SQL_MAX_COLS];
};

/* Splits a DataRow into columns; a malformed row fails the request with 500. */
static bool row_cols(struct req *r, const struct pg_msg *m, struct cols *c, int want) {
    struct pg_row row;
    if (!pg_row_init(&row, m) || row.ncols != want) goto bad;
    for (int i = 0; i < want; i++) {
        c->n[i] = pg_col(&row, &c->v[i]);
        if (c->n[i] == -2) goto bad;
    }
    return true;
bad:
    r->pg_error = true;
    memcpy(r->sqlstate, "XXROW", 6);
    return false;
}

static void put_text(struct buf *b, const struct cols *c, int i) {
    if (c->n[i] < 0) buf_lit(b, "null");
    else json_str(b, (const char *)c->v[i], (size_t)c->n[i]);
}

static void put_bool(struct buf *b, const struct cols *c, int i) {
    if (c->n[i] == 1 && c->v[i][0]) buf_lit(b, "true");
    else buf_lit(b, "false");
}

static int64_t col_i64(const struct cols *c, int i) { return c->n[i] == 8 ? pg_i64(c->v[i]) : 0; }

static void put_ts(struct buf *b, const struct cols *c, int i) {
    if (c->n[i] == 8) json_ts(b, pg_i64(c->v[i]));
    else buf_lit(b, "null");
}

/* {"email","token","username","bio","image"} from (id, username, email, bio, image). */
static void put_user(struct buf *b, const struct cols *c, const char *tok, size_t toklen) {
    buf_lit(b, "{\"user\":{\"email\":");
    put_text(b, c, 2);
    buf_lit(b, ",\"token\":");
    json_str(b, tok, toklen);
    buf_lit(b, ",\"username\":");
    put_text(b, c, 1);
    buf_lit(b, ",\"bio\":");
    put_text(b, c, 3);
    buf_lit(b, ",\"image\":");
    put_text(b, c, 4);
    buf_lit(b, "}}");
}

static void put_author(struct buf *b, const struct cols *c, int at, bool has_following, bool following) {
    buf_lit(b, "{\"username\":");
    put_text(b, c, at);
    buf_lit(b, ",\"bio\":");
    put_text(b, c, at + 1);
    buf_lit(b, ",\"image\":");
    put_text(b, c, at + 2);
    buf_lit(b, ",\"following\":");
    if (has_following) put_bool(b, c, at + 3);
    else if (following) buf_lit(b, "true");
    else buf_lit(b, "false");
    buf_putc(b, '}');
}

/* An article from ARTICLE_LIST_SELECT (13 columns) or ARTICLE_FULL_SELECT (14, body at 4). */
static bool put_article(struct req *r, const struct pg_msg *m, bool full) {
    struct cols c;
    if (!row_cols(r, m, &c, full ? 14 : 13)) return false;
    struct buf *b = &r->resp;
    int o = full ? 1 : 0;
    buf_lit(b, "{\"slug\":");
    put_text(b, &c, 1);
    buf_lit(b, ",\"title\":");
    put_text(b, &c, 2);
    buf_lit(b, ",\"description\":");
    put_text(b, &c, 3);
    if (full) {
        buf_lit(b, ",\"body\":");
        put_text(b, &c, 4);
    }
    buf_lit(b, ",\"tagList\":[");
    struct pg_array arr;
    if (c.n[6 + o] >= 0) {
        if (!pg_array_init(&arr, c.v[6 + o], c.n[6 + o])) goto bad;
        for (uint32_t i = 0; i < arr.n; i++) {
            const uint8_t *v;
            int32_t n = pg_array_next(&arr, &v);
            if (n < 0) goto bad;
            if (i) buf_putc(b, ',');
            json_str(b, (const char *)v, (size_t)n);
        }
    }
    buf_lit(b, "],\"createdAt\":");
    put_ts(b, &c, 4 + o);
    buf_lit(b, ",\"updatedAt\":");
    put_ts(b, &c, 5 + o);
    buf_lit(b, ",\"favorited\":");
    put_bool(b, &c, 8 + o);
    buf_lit(b, ",\"favoritesCount\":");
    buf_put_i64(b, col_i64(&c, 7 + o));
    buf_lit(b, ",\"author\":");
    put_author(b, &c, 9 + o, true, false);
    buf_putc(b, '}');
    return true;
bad:
    r->pg_error = true;
    memcpy(r->sqlstate, "XXROW", 6);
    return false;
}

/* A comment from (id, body, created_at, updated_at, username, bio, image[, following]). */
static bool put_comment(struct req *r, const struct pg_msg *m, bool has_following) {
    struct cols c;
    if (!row_cols(r, m, &c, has_following ? 8 : 7)) return false;
    struct buf *b = &r->resp;
    buf_lit(b, "{\"id\":");
    buf_put_i64(b, col_i64(&c, 0));
    buf_lit(b, ",\"createdAt\":");
    put_ts(b, &c, 2);
    buf_lit(b, ",\"updatedAt\":");
    put_ts(b, &c, 3);
    buf_lit(b, ",\"body\":");
    put_text(b, &c, 1);
    buf_lit(b, ",\"author\":");
    put_author(b, &c, 4, has_following, false);
    buf_putc(b, '}');
    return true;
}

/* A failed unit: a unique violation is the client's fault (422), anything else is ours (500). */
static void pg_failed(struct req *r) {
    if (strcmp(r->sqlstate, "23505") == 0) req_error(r, 422, "username or email is already taken");
    else req_error(r, 500, "internal error");
}

/* ---- request bodies ---- */

static const struct jval *body_wrapper(struct req *r, const struct http_req *hr, const char *key, size_t klen) {
    const struct jval *root = json_parse(&r->w->scratch, hr->body, hr->body_len);
    if (!root || root->type != J_OBJ) return NULL;
    const struct jval *inner = json_get(root, key, klen);
    return inner && inner->type == J_OBJ ? inner : NULL;
}

enum { FIELD_ABSENT, FIELD_OK, FIELD_BAD };

/* Absent or null: FIELD_ABSENT. A string (non-empty if required, without NUL): FIELD_OK. Anything else: FIELD_BAD. */
static int opt_str(const struct jval *obj, const char *key, bool non_empty, const char **s, uint32_t *n) {
    const struct jval *v = json_get(obj, key, strlen(key));
    *s = NULL;
    *n = 0;
    if (!v || v->type == J_NULL) return FIELD_ABSENT;
    if (v->type != J_STR || (v->flags & JF_NUL) || (non_empty && v->len == 0)) return FIELD_BAD;
    *s = v->s;
    *n = v->len;
    return FIELD_OK;
}

static bool req_str(const struct jval *obj, const char *key, const char **s, uint32_t *n) {
    return opt_str(obj, key, true, s, n) == FIELD_OK;
}

/* ---- auth ---- */

enum { AUTH_NONE, AUTH_OK, AUTH_BAD };

/* Checks the Authorization header; with keep_token, the token is kept in slot 5 (GET/PUT /api/user echo it). */
static int authenticate(struct req *r, const struct http_req *hr, bool keep_token) {
    if (!hr->has_auth || hr->auth_len == 0) return AUTH_NONE;
    if (hr->auth_len < 6 || memcmp(hr->auth, "Token ", 6) != 0) return AUTH_BAD;
    const char *tok = hr->auth + 6;
    size_t n = hr->auth_len - 6;
    if (!jwt_verify(&r->w->scratch, tok, n, r->w->now, &r->viewer)) return AUTH_BAD;
    if (keep_token) keep_slot(r, 5, tok, n);
    return AUTH_OK;
}

/* ---- GET /api/tags ---- */

static void h_tags(struct req *r, int ev, const struct pg_msg *m) {
    struct cols c;
    if (ev == EV_ROW) {
        if (!row_cols(r, m, &c, 1)) return;
        if (r->rows++) buf_putc(&r->resp, ',');
        put_text(&r->resp, &c, 0);
    } else if (r->pg_error) {
        pg_failed(r);
    } else {
        buf_lit(&r->resp, "]}");
        req_respond(r, 200);
    }
}

static void start_tags(struct req *r) {
    struct pg_bind pb;
    if (cfg.planner) return plan_submit(r, PK_TAGS, PF_NONE, 0, 0, NULL, 0);
    r->fn = h_tags;
    unit_begin(r);
    bind_begin(r, &pb, S_TAGS);
    bind_exec(&pb);
    http_begin(&r->resp);
    buf_lit(&r->resp, "{\"tags\":[");
    unit_submit(r, false);
}

/* ---- users ---- */

/* POST /api/users: s0 username, s1 email; bcrypt hash, then INSERT. */
static void h_register(struct req *r, int ev, const struct pg_msg *m) {
    struct cols c;
    struct pg_bind pb;
    switch (ev) {
    case EV_HASHED:
        unit_begin(r);
        bind_begin(r, &pb, S_USER_INSERT);
        pg_bind_text(&pb, r->s[0], r->sl[0]);
        pg_bind_text(&pb, r->s[1], r->sl[1]);
        pg_bind_text(&pb, r->bc.hash, BCRYPT_LEN);
        bind_exec(&pb);
        http_begin(&r->resp);
        r->solo = true;  /* may fail on a taken name; must not take other writes down with it */
        unit_submit(r, true);
        break;
    case EV_ROW: {
        if (!row_cols(r, m, &c, 5)) return;
        char tok[JWT_MAX];
        size_t n = jwt_sign(tok, col_i64(&c, 0), (int64_t)r->w->now);
        put_user(&r->resp, &c, tok, n);
        r->rows++;
        break;
    }
    case EV_READY:
        if (r->pg_error) pg_failed(r);
        else if (!r->rows) req_error(r, 500, "internal error");
        else req_respond(r, 201);
        break;
    }
}

static void start_register(struct req *r, const struct http_req *hr) {
    const struct jval *u = body_wrapper(r, hr, LIT("user"));
    const char *name, *email, *pw;
    uint32_t nl, el, pl;
    if (!u) return req_error(r, 422, "invalid body");
    if (!req_str(u, "username", &name, &nl) | !req_str(u, "email", &email, &el) | !req_str(u, "password", &pw, &pl))
        return req_error(r, 422, "username, email and password are required");
    if (pl > BCRYPT_MAX_PW) return req_error(r, 422, "password is too long");
    keep_slot(r, 0, name, nl);
    keep_slot(r, 1, email, el);
    r->bc.kind = BC_HASH;
    r->bc.pwlen = (uint8_t)pl;
    memcpy(r->bc.pw, pw, pl);
    r->fn = h_register;
    bcrypt_submit(r);
}

/* POST /api/users/login: SELECT by email, keep the row, verify the password, answer with a fresh token. */
static void h_login(struct req *r, int ev, const struct pg_msg *m) {
    struct cols c;
    struct pg_msg saved = {'D', r->saved_len, (const uint8_t *)r->saved};
    switch (ev) {
    case EV_ROW:
        if (r->saved) return;
        r->saved = xmalloc(m->len);
        memcpy(r->saved, m->body, m->len);
        r->saved_len = m->len;
        r->rows++;
        break;
    case EV_READY:
        if (r->pg_error) return pg_failed(r);
        if (!r->rows || r->n[0]) return req_error(r, 401, "invalid email or password");
        if (!row_cols(r, &saved, &c, 6) || c.n[5] < 0 || c.n[5] > BCRYPT_LEN)
            return req_error(r, 401, "invalid email or password");
        memcpy(r->bc.hash, c.v[5], (size_t)c.n[5]);
        r->bc.hash[c.n[5]] = 0;
        r->bc.kind = BC_VERIFY;
        bcrypt_submit(r);
        break;
    case EV_HASHED: {
        if (!r->bc.ok) return req_error(r, 401, "invalid email or password");
        if (!row_cols(r, &saved, &c, 6)) return req_error(r, 500, "internal error");
        char tok[JWT_MAX];
        size_t n = jwt_sign(tok, col_i64(&c, 0), (int64_t)r->w->now);
        http_begin(&r->resp);
        put_user(&r->resp, &c, tok, n);
        req_respond(r, 200);
        break;
    }
    }
}

static void start_login(struct req *r, const struct http_req *hr) {
    const struct jval *u = body_wrapper(r, hr, LIT("user"));
    const char *email, *pw;
    uint32_t el, pl;
    struct pg_bind pb;
    if (!u) return req_error(r, 422, "invalid body");
    if (!req_str(u, "email", &email, &el) | !req_str(u, "password", &pw, &pl))
        return req_error(r, 422, "email and password are required");
    if (pl > BCRYPT_MAX_PW) r->n[0] = 1;  /* can never match; still answered 401 after the lookup */
    else memcpy(r->bc.pw, pw, pl), r->bc.pwlen = (uint8_t)pl;
    r->fn = h_login;
    unit_begin(r);
    bind_begin(r, &pb, S_USER_BY_EMAIL);
    pg_bind_text(&pb, email, el);
    bind_exec(&pb);
    unit_submit(r, false);
}

/* GET /api/user and PUT /api/user: the row comes back with the token that was presented (slot 5). */
static void h_user(struct req *r, int ev, const struct pg_msg *m) {
    struct cols c;
    struct pg_bind pb;
    switch (ev) {
    case EV_HASHED:  /* PUT with a new password: now run the UPDATE */
        unit_begin(r);
        bind_begin(r, &pb, S_USER_UPDATE);
        pg_bind_i64(&pb, r->viewer);
        bind_opt_text(&pb, r->s[0], r->sl[0]);
        bind_opt_text(&pb, r->s[1], r->sl[1]);
        pg_bind_text(&pb, r->bc.hash, BCRYPT_LEN);
        bind_opt_text(&pb, r->s[3], r->sl[3]);
        bind_opt_text(&pb, r->s[4], r->sl[4]);
        bind_exec(&pb);
        http_begin(&r->resp);
        r->solo = true;
        unit_submit(r, true);
        break;
    case EV_ROW:
        if (!row_cols(r, m, &c, 5)) return;
        put_user(&r->resp, &c, r->s[5], r->sl[5]);
        r->rows++;
        break;
    case EV_READY:
        if (r->pg_error) pg_failed(r);
        else if (!r->rows) req_error(r, 401, "unauthorized");
        else req_respond(r, 200);
        break;
    }
}

static void start_get_user(struct req *r) {
    struct pg_bind pb;
    r->fn = h_user;
    unit_begin(r);
    bind_begin(r, &pb, S_USER_BY_ID);
    pg_bind_i64(&pb, r->viewer);
    bind_exec(&pb);
    http_begin(&r->resp);
    unit_submit(r, false);
}

/* Slots: 0 email, 1 username, 2 password, 3 bio, 4 image, 5 token. */
static void start_put_user(struct req *r, const struct http_req *hr) {
    static const char *const fields[5] = {"email", "username", "password", "bio", "image"};
    const struct jval *u = body_wrapper(r, hr, LIT("user"));
    const char *s[5];
    uint32_t n[5];
    struct pg_bind pb;
    if (!u) return req_error(r, 422, "invalid body");
    bool bad = false;
    for (int i = 0; i < 5; i++) bad |= opt_str(u, fields[i], i < 3, &s[i], &n[i]) == FIELD_BAD;
    if (bad) return req_error(r, 422, "invalid user fields");
    if (s[2] && n[2] > BCRYPT_MAX_PW) return req_error(r, 422, "password is too long");
    for (int i = 0; i < 5; i++)
        if (i != 2) keep_slot(r, i, s[i], n[i]);
    r->fn = h_user;
    if (s[2]) {
        r->bc.kind = BC_HASH;
        r->bc.pwlen = (uint8_t)n[2];
        memcpy(r->bc.pw, s[2], n[2]);
        bcrypt_submit(r);
        return;
    }
    unit_begin(r);
    bind_begin(r, &pb, S_USER_UPDATE);
    pg_bind_i64(&pb, r->viewer);
    for (int i = 0; i < 5; i++) bind_opt_text(&pb, r->s[i], r->sl[i]);
    bind_exec(&pb);
    http_begin(&r->resp);
    r->solo = true;
    unit_submit(r, true);
}

/* ---- profiles ---- */

static void h_profile(struct req *r, int ev, const struct pg_msg *m) {
    struct cols c;
    if (ev == EV_ROW) {
        if (!row_cols(r, m, &c, 5)) return;
        buf_lit(&r->resp, "{\"profile\":");
        put_author(&r->resp, &c, 1, true, false);
        buf_putc(&r->resp, '}');
        r->rows++;
    } else if (r->pg_error) {
        pg_failed(r);
    } else if (!r->rows) {
        req_error(r, 404, "profile not found");
    } else {
        req_respond(r, 200);
    }
}

static void start_profile(struct req *r, const char *name, size_t nl) {
    struct pg_bind pb;
    if (cfg.planner) return plan_submit(r, PK_PROFILE, PF_NONE, 0, 0, name, (uint32_t)nl);
    r->fn = h_profile;
    unit_begin(r);
    bind_begin(r, &pb, S_PROFILE);
    pg_bind_i64(&pb, r->viewer);
    pg_bind_text(&pb, name, nl);
    bind_exec(&pb);
    http_begin(&r->resp);
    unit_submit(r, false);
}

/* POST/DELETE /api/profiles/:username/follow: the lookup and the write are one statement; it returns the
 * profile, or no row (404). n[0]: follow? */
static void h_follow(struct req *r, int ev, const struct pg_msg *m) {
    struct cols c;
    if (ev == EV_ROW) {
        if (!row_cols(r, m, &c, 3)) return;
        buf_lit(&r->resp, "{\"profile\":");
        put_author(&r->resp, &c, 0, false, r->n[0]);
        buf_putc(&r->resp, '}');
        r->rows++;
        return;
    }
    if (r->pg_error) return pg_failed(r);
    if (!r->rows) return req_error(r, 404, "profile not found");
    req_respond(r, 200);
}

static void start_follow(struct req *r, const char *name, size_t nl, bool follow) {
    struct pg_bind pb;
    r->fn = h_follow;
    r->n[0] = follow;
    unit_begin(r);
    bind_begin(r, &pb, follow ? S_FOLLOW_NAME : S_UNFOLLOW_NAME);
    pg_bind_i64(&pb, r->viewer);
    pg_bind_text(&pb, name, nl);
    bind_exec(&pb);
    http_begin(&r->resp);
    unit_submit(r, true);
}

/* ---- article lists ---- */

/* Statement 0 is the page, statement 1 the capped count. */
static void h_list(struct req *r, int ev, const struct pg_msg *m) {
    if (ev == EV_ROW) {
        if (r->stmt == 0) {
            if (r->rows++) buf_putc(&r->resp, ',');
            put_article(r, m, false);
        } else {
            struct cols c;
            if (row_cols(r, m, &c, 1)) r->n[0] = col_i64(&c, 0);
        }
        return;
    }
    if (r->pg_error) return pg_failed(r);
    buf_lit(&r->resp, "],\"articlesCount\":");
    buf_put_i64(&r->resp, r->n[0]);
    buf_putc(&r->resp, '}');
    req_respond(r, 200);
}

struct list_query {
    int64_t limit, offset;
    const char *filter[3];  /* tag, author, favorited (decoded, in the scratch arena) */
    uint32_t flen[3];
};

/* limit (1-100, default 20) and offset (>= 0, default 0): present but invalid is 422. The first value of each
 * key counts; a pair with a malformed escape is skipped, as Go's url.Query does. */
static bool parse_list_query(struct req *r, const struct http_req *hr, struct list_query *lq) {
    static const char *const keys[5] = {"limit", "offset", "tag", "author", "favorited"};
    bool seen[5] = {0};
    lq->limit = 20;
    lq->offset = 0;
    memset(lq->filter, 0, sizeof lq->filter);
    memset(lq->flen, 0, sizeof lq->flen);
    const char *p = hr->query, *end = hr->query + hr->query_len;
    while (p && p < end) {
        const char *amp = memchr(p, '&', (size_t)(end - p));
        const char *pe = amp ? amp : end;
        const char *eq = memchr(p, '=', (size_t)(pe - p));
        const char *ke = eq ? eq : pe;
        if (pe > p && !memchr(p, ';', (size_t)(pe - p))) {
            char *k = arena_alloc(&r->w->scratch, (size_t)(ke - p) + 1);
            ptrdiff_t kl = pct_decode(k, p, (size_t)(ke - p), true);
            const char *vs = eq ? eq + 1 : pe;
            char *v = arena_alloc(&r->w->scratch, (size_t)(pe - vs) + 1);
            ptrdiff_t vl = pct_decode(v, vs, (size_t)(pe - vs), true);
            if (kl >= 0 && vl >= 0) {
                for (int i = 0; i < 5; i++) {
                    if (seen[i] || (size_t)kl != strlen(keys[i]) || memcmp(k, keys[i], (size_t)kl) != 0) continue;
                    seen[i] = true;
                    if (i == 0) {
                        if (!parse_uint(v, (size_t)vl, &lq->limit) || lq->limit < 1 || lq->limit > 100) return false;
                    } else if (i == 1) {
                        if (!parse_uint(v, (size_t)vl, &lq->offset)) return false;
                    } else {
                        lq->filter[i - 2] = v;
                        lq->flen[i - 2] = (uint32_t)vl;
                    }
                }
            }
        }
        p = amp ? amp + 1 : NULL;
    }
    return true;
}

static void start_list(struct req *r, const struct http_req *hr, bool feed) {
    struct list_query lq;
    struct pg_bind pb;
    if (!parse_list_query(r, hr, &lq)) return req_error(r, 422, "limit must be 1-100 and offset >= 0");
    if (cfg.planner) {
        if (feed) return plan_submit(r, PK_FEED, PF_NONE, lq.limit, lq.offset, NULL, 0);
        for (int i = 0; i < 3; i++)  /* the first non-empty filter, in the order tag, author, favorited */
            if (lq.flen[i]) return plan_submit(r, PK_LIST, PF_TAG + i, lq.limit, lq.offset, lq.filter[i], lq.flen[i]);
        return plan_submit(r, PK_LIST, PF_NONE, lq.limit, lq.offset, NULL, 0);
    }
    r->fn = h_list;
    unit_begin(r);

    /* The first non-empty filter applies, in the order tag, author, favorited. */
    static const enum stmt lists[3] = {S_LIST_TAG, S_LIST_AUTHOR, S_LIST_FAVORITED};
    static const enum stmt counts[3] = {S_COUNT_TAG, S_COUNT_AUTHOR, S_COUNT_FAVORITED};
    int f = -1;
    if (!feed)
        for (int i = 0; i < 3 && f < 0; i++)
            if (lq.flen[i]) f = i;

    bind_begin(r, &pb, feed ? S_FEED : f < 0 ? S_LIST_ALL : lists[f]);
    pg_bind_i64(&pb, r->viewer);
    pg_bind_i64(&pb, lq.limit);
    pg_bind_i64(&pb, lq.offset);
    if (f >= 0) pg_bind_text(&pb, lq.filter[f], lq.flen[f]);
    bind_exec(&pb);

    bind_begin(r, &pb, feed ? S_COUNT_FEED : f < 0 ? S_COUNT_ALL : counts[f]);
    if (feed) pg_bind_i64(&pb, r->viewer);
    else if (f >= 0) pg_bind_text(&pb, lq.filter[f], lq.flen[f]);
    bind_exec(&pb);

    http_begin(&r->resp);
    buf_lit(&r->resp, "{\"articles\":[");
    unit_submit(r, false);
}

/* ---- single articles ---- */

/* Renders {"article": ...} from the statement at index n[3]; no row is 404. status in n[2]. */
static void h_article(struct req *r, int ev, const struct pg_msg *m) {
    if (ev == EV_ROW) {
        if (r->stmt != r->n[3] || r->rows) return;
        buf_lit(&r->resp, "{\"article\":");
        if (put_article(r, m, true)) buf_putc(&r->resp, '}');
        r->rows++;
        return;
    }
    if (r->pg_error) return pg_failed(r);
    if (!r->rows) return req_error(r, 404, "article not found");
    req_respond(r, (int)r->n[2]);
}

static void start_get_article(struct req *r, const char *slug, size_t sl) {
    struct pg_bind pb;
    if (cfg.planner) return plan_submit(r, PK_ARTICLE, PF_NONE, 0, 0, slug, (uint32_t)sl);
    r->fn = h_article;
    r->n[2] = 200;
    unit_begin(r);
    bind_begin(r, &pb, S_ARTICLE_BY_SLUG);
    pg_bind_i64(&pb, r->viewer);
    pg_bind_text(&pb, slug, sl);
    bind_exec(&pb);
    http_begin(&r->resp);
    unit_submit(r, false);
}

/* POST /api/articles: insert, tags, article_tags and the read-back in one unit (one transaction). */
static void start_create_article(struct req *r, const struct http_req *hr) {
    const struct jval *a = body_wrapper(r, hr, LIT("article"));
    const char *title, *desc, *body;
    uint32_t tl, dl, bl;
    struct pg_bind pb;
    if (!a) return req_error(r, 422, "invalid body");
    if (!req_str(a, "title", &title, &tl) | !req_str(a, "description", &desc, &dl) | !req_str(a, "body", &body, &bl))
        return req_error(r, 422, "title, description and body are required");
    const struct jval *tags = json_getl(a, "tagList");
    if (tags && tags->type != J_NULL) {
        if (tags->type != J_ARR) return req_error(r, 422, "tagList must be an array of non-empty strings");
        for (const struct jval *t = tags->child; t; t = t->next)
            if (t->type != J_STR || t->len == 0 || (t->flags & JF_NUL))
                return req_error(r, 422, "tagList must be an array of non-empty strings");
    }
    bool have_tags = tags && tags->type == J_ARR && tags->len > 0;

    r->fn = h_article;
    r->n[2] = 201;
    r->n[3] = have_tags ? 3 : 1;  /* index of the read-back statement */
    unit_begin(r);
    bind_begin(r, &pb, S_ARTICLE_INSERT);
    pg_bind_i64(&pb, r->viewer);
    pg_bind_text(&pb, title, tl);
    pg_bind_text(&pb, desc, dl);
    pg_bind_text(&pb, body, bl);
    bind_exec(&pb);
    if (have_tags) {
        for (int s = 0; s < 2; s++) {
            size_t at;
            bind_begin(r, &pb, s == 0 ? S_TAGS_INSERT : S_ARTICLE_TAGS_INSERT);
            pg_bind_array_begin(&pb, OID_TEXT, &at);
            for (const struct jval *t = tags->child; t; t = t->next) pg_bind_array_text(&pb, t->s, t->len);
            pg_bind_array_end(&pb, at, tags->len, false);
            bind_exec(&pb);
        }
    }
    bind_begin(r, &pb, S_ARTICLE_BY_CURRVAL);
    pg_bind_i64(&pb, r->viewer);
    bind_exec(&pb);
    http_begin(&r->resp);
    unit_submit(r, true);
}

/* Owner check for PUT/DELETE of an article: step 0 looks it up (n[0] id, n[1] author). */
static bool owner_step(struct req *r, int ev, const struct pg_msg *m) {
    struct cols c;
    if (ev == EV_ROW) {
        if (row_cols(r, m, &c, 2)) r->n[0] = col_i64(&c, 0), r->n[1] = col_i64(&c, 1), r->rows++;
        return false;
    }
    if (r->pg_error) {
        pg_failed(r);
        return false;
    }
    if (!r->rows) {
        req_error(r, 404, "article not found");
        return false;
    }
    if (r->n[1] != r->viewer) {
        req_error(r, 403, "not the author");
        return false;
    }
    return true;
}

/* PUT /api/articles/:slug. Slots 0-2: title, description, body (NULL when unchanged). */
static void h_update_article(struct req *r, int ev, const struct pg_msg *m) {
    struct pg_bind pb;
    if (r->step == 1) return h_article(r, ev, m);
    if (!owner_step(r, ev, m)) return;
    r->step = 1;
    r->fn = h_article;
    r->n[2] = 200;
    r->n[3] = 1;
    unit_begin(r);
    bind_begin(r, &pb, S_ARTICLE_UPDATE);
    pg_bind_i64(&pb, r->n[0]);
    for (int i = 0; i < 3; i++) bind_opt_text(&pb, r->s[i], r->sl[i]);
    bind_exec(&pb);
    bind_begin(r, &pb, S_ARTICLE_BY_ID);
    pg_bind_i64(&pb, r->viewer);
    pg_bind_i64(&pb, r->n[0]);
    bind_exec(&pb);
    http_begin(&r->resp);
    unit_submit(r, true);
}

static void start_update_article(struct req *r, const struct http_req *hr, const char *slug, size_t sl) {
    static const char *const fields[3] = {"title", "description", "body"};
    const struct jval *a = body_wrapper(r, hr, LIT("article"));
    struct pg_bind pb;
    if (!a) return req_error(r, 422, "invalid body");
    const char *s[3];
    uint32_t n[3];
    bool bad = false;
    for (int i = 0; i < 3; i++) bad |= opt_str(a, fields[i], true, &s[i], &n[i]) == FIELD_BAD;
    if (bad) return req_error(r, 422, "title, description and body must be non-empty strings");
    for (int i = 0; i < 3; i++) keep_slot(r, i, s[i], n[i]);
    r->fn = h_update_article;
    unit_begin(r);
    bind_begin(r, &pb, S_ARTICLE_OWNER);
    pg_bind_text(&pb, slug, sl);
    bind_exec(&pb);
    unit_submit(r, false);
}

/* DELETE /api/articles/:slug */
static void h_delete_article(struct req *r, int ev, const struct pg_msg *m) {
    struct pg_bind pb;
    if (r->step == 1) {
        if (ev != EV_READY) return;
        if (r->pg_error) return pg_failed(r);
        http_begin(&r->resp);
        return req_respond(r, 204);
    }
    if (!owner_step(r, ev, m)) return;
    r->step = 1;
    unit_begin(r);
    bind_begin(r, &pb, S_ARTICLE_DELETE);
    pg_bind_i64(&pb, r->n[0]);
    bind_exec(&pb);
    unit_submit(r, true);
}

static void start_delete_article(struct req *r, const char *slug, size_t sl) {
    struct pg_bind pb;
    r->fn = h_delete_article;
    unit_begin(r);
    bind_begin(r, &pb, S_ARTICLE_OWNER);
    pg_bind_text(&pb, slug, sl);
    bind_exec(&pb);
    unit_submit(r, false);
}

/* POST/DELETE /api/articles/:slug/favorite: the write finds the article by slug, and the read-back in the same
 * transaction sees it; no row from the read-back is 404. */
static void start_favorite(struct req *r, const char *slug, size_t sl, bool fav) {
    struct pg_bind pb;
    r->fn = h_article;
    r->n[2] = 200;
    r->n[3] = 1;
    unit_begin(r);
    bind_begin(r, &pb, fav ? S_FAVORITE_SLUG : S_UNFAVORITE_SLUG);
    pg_bind_i64(&pb, r->viewer);
    pg_bind_text(&pb, slug, sl);
    bind_exec(&pb);
    bind_begin(r, &pb, S_ARTICLE_BY_SLUG);
    pg_bind_i64(&pb, r->viewer);
    pg_bind_text(&pb, slug, sl);
    bind_exec(&pb);
    http_begin(&r->resp);
    unit_submit(r, true);
}

/* ---- comments ---- */

/* GET: statement 0 proves the article exists, statement 1 lists its comments. */
static void h_comments(struct req *r, int ev, const struct pg_msg *m) {
    if (ev == EV_ROW) {
        if (r->stmt == 0) {
            r->n[0] = 1;
        } else {
            if (r->rows++) buf_putc(&r->resp, ',');
            put_comment(r, m, true);
        }
        return;
    }
    if (r->pg_error) return pg_failed(r);
    if (!r->n[0]) return req_error(r, 404, "article not found");
    buf_lit(&r->resp, "]}");
    req_respond(r, 200);
}

static void start_comments(struct req *r, const char *slug, size_t sl) {
    struct pg_bind pb;
    if (cfg.planner) return plan_submit(r, PK_COMMENTS, PF_NONE, 0, 0, slug, (uint32_t)sl);
    r->fn = h_comments;
    unit_begin(r);
    bind_begin(r, &pb, S_ARTICLE_ID);
    pg_bind_text(&pb, slug, sl);
    bind_exec(&pb);
    bind_begin(r, &pb, S_COMMENTS_BY_SLUG);
    pg_bind_i64(&pb, r->viewer);
    pg_bind_text(&pb, slug, sl);
    bind_exec(&pb);
    http_begin(&r->resp);
    buf_lit(&r->resp, "{\"comments\":[");
    unit_submit(r, false);
}

static void h_create_comment(struct req *r, int ev, const struct pg_msg *m) {
    if (ev == EV_ROW) {
        if (r->rows++) return;
        buf_lit(&r->resp, "{\"comment\":");
        if (put_comment(r, m, false)) buf_putc(&r->resp, '}');
        return;
    }
    if (r->pg_error) return pg_failed(r);
    if (!r->rows) return req_error(r, 404, "article not found");
    req_respond(r, 201);
}

static void start_create_comment(struct req *r, const struct http_req *hr, const char *slug, size_t sl) {
    const struct jval *c = body_wrapper(r, hr, LIT("comment"));
    const char *body;
    uint32_t bl;
    struct pg_bind pb;
    if (!c) return req_error(r, 422, "invalid body");
    if (!req_str(c, "body", &body, &bl)) return req_error(r, 422, "body is required");
    r->fn = h_create_comment;
    unit_begin(r);
    bind_begin(r, &pb, S_COMMENT_INSERT);
    pg_bind_text(&pb, slug, sl);
    pg_bind_i64(&pb, r->viewer);
    pg_bind_text(&pb, body, bl);
    bind_exec(&pb);
    http_begin(&r->resp);
    unit_submit(r, true);
}

/* DELETE /api/articles/:slug/comments/:id. n[0]: comment id, n[1]: its author. */
static void h_delete_comment(struct req *r, int ev, const struct pg_msg *m) {
    struct cols c;
    struct pg_bind pb;
    if (r->step == 1) {
        if (ev != EV_READY) return;
        if (r->pg_error) return pg_failed(r);
        http_begin(&r->resp);
        return req_respond(r, 204);
    }
    if (ev == EV_ROW) {
        if (row_cols(r, m, &c, 1)) r->n[1] = col_i64(&c, 0), r->rows++;
        return;
    }
    if (r->pg_error) return pg_failed(r);
    if (!r->rows) return req_error(r, 404, "comment not found");
    if (r->n[1] != r->viewer) return req_error(r, 403, "not the author");
    r->step = 1;
    unit_begin(r);
    bind_begin(r, &pb, S_COMMENT_DELETE);
    pg_bind_i64(&pb, r->n[0]);
    bind_exec(&pb);
    unit_submit(r, true);
}

static void start_delete_comment(struct req *r, const char *slug, size_t sl, const char *id, size_t il) {
    struct pg_bind pb;
    if (!parse_uint(id, il, &r->n[0])) return req_error(r, 404, "comment not found");
    r->fn = h_delete_comment;
    unit_begin(r);
    bind_begin(r, &pb, S_COMMENT_OWNER);
    pg_bind_i64(&pb, r->n[0]);
    pg_bind_text(&pb, slug, sl);
    bind_exec(&pb);
    unit_submit(r, false);
}

/* ---- routing ---- */

#define MAX_SEGS 5

static bool seg_is(const char *s, uint32_t n, const char *lit) { return n == strlen(lit) && memcmp(s, lit, n) == 0; }

void dispatch(struct worker *w, int fd, uint32_t gen, const struct http_req *hr) {
    struct req *r = req_alloc(w, fd, gen);
    r->keep_alive = hr->keep_alive;
    /* Room for every string a handler may keep: decoded body strings grow at most 3x (U+FFFD for bad bytes). */
    r->data_cap = hr->path_len + hr->auth_len + 3 * hr->body_len + 64;
    r->data = xmalloc(r->data_cap);

    /* Split "/api/<seg>/<seg>..." and percent-decode each segment; an empty segment matches nothing. */
    const char *seg[MAX_SEGS];
    uint32_t sl[MAX_SEGS];
    int nseg = 0;
    if (hr->path_len < 5 || memcmp(hr->path, "/api/", 5) != 0) goto not_found;
    const char *p = hr->path + 5, *end = hr->path + hr->path_len;
    for (;;) {
        const char *slash = memchr(p, '/', (size_t)(end - p));
        const char *se = slash ? slash : end;
        if (se == p || nseg == MAX_SEGS) goto not_found;
        char *d = arena_alloc(&w->scratch, (size_t)(se - p) + 1);
        ptrdiff_t dl = pct_decode(d, p, (size_t)(se - p), false);
        if (dl < 0) goto not_found;
        seg[nseg] = d;
        sl[nseg++] = (uint32_t)dl;
        if (!slash) break;
        p = slash + 1;
    }

    int method = hr->method;
    int auth;
#define REQUIRED(keep_token)                                                  \
    do {                                                                      \
        if (authenticate(r, hr, keep_token) != AUTH_OK) goto unauthorized;    \
    } while (0)
#define OPTIONAL()                                                            \
    do {                                                                      \
        if ((auth = authenticate(r, hr, false)) == AUTH_BAD) goto unauthorized; \
    } while (0)

    if (seg_is(seg[0], sl[0], "articles")) {
        if (nseg == 1) {
            if (method == M_GET) { OPTIONAL(); return start_list(r, hr, false); }
            if (method == M_POST) { REQUIRED(false); return start_create_article(r, hr); }
        } else if (nseg == 2) {
            if (method == M_GET && seg_is(seg[1], sl[1], "feed")) { REQUIRED(false); return start_list(r, hr, true); }
            if (method == M_GET) { OPTIONAL(); return start_get_article(r, seg[1], sl[1]); }
            if (method == M_PUT) { REQUIRED(false); return start_update_article(r, hr, seg[1], sl[1]); }
            if (method == M_DELETE) { REQUIRED(false); return start_delete_article(r, seg[1], sl[1]); }
        } else if (nseg == 3 && seg_is(seg[2], sl[2], "favorite")) {
            if (method == M_POST || method == M_DELETE) {
                REQUIRED(false);
                return start_favorite(r, seg[1], sl[1], method == M_POST);
            }
        } else if (nseg == 3 && seg_is(seg[2], sl[2], "comments")) {
            if (method == M_GET) { OPTIONAL(); return start_comments(r, seg[1], sl[1]); }
            if (method == M_POST) { REQUIRED(false); return start_create_comment(r, hr, seg[1], sl[1]); }
        } else if (nseg == 4 && seg_is(seg[2], sl[2], "comments") && method == M_DELETE) {
            REQUIRED(false);
            return start_delete_comment(r, seg[1], sl[1], seg[3], sl[3]);
        }
    } else if (seg_is(seg[0], sl[0], "tags")) {
        if (nseg == 1 && method == M_GET) return start_tags(r);
    } else if (seg_is(seg[0], sl[0], "profiles")) {
        if (nseg == 2 && method == M_GET) { OPTIONAL(); return start_profile(r, seg[1], sl[1]); }
        if (nseg == 3 && seg_is(seg[2], sl[2], "follow") && (method == M_POST || method == M_DELETE)) {
            REQUIRED(false);
            return start_follow(r, seg[1], sl[1], method == M_POST);
        }
    } else if (seg_is(seg[0], sl[0], "user")) {
        if (nseg == 1 && method == M_GET) { REQUIRED(true); return start_get_user(r); }
        if (nseg == 1 && method == M_PUT) { REQUIRED(true); return start_put_user(r, hr); }
    } else if (seg_is(seg[0], sl[0], "users")) {
        if (nseg == 1 && method == M_POST) return start_register(r, hr);
        if (nseg == 2 && seg_is(seg[1], sl[1], "login") && method == M_POST) return start_login(r, hr);
    }
#undef REQUIRED
#undef OPTIONAL
    (void)auth;
not_found:
    return req_error(r, 404, "not found");
unauthorized:
    return req_error(r, 401, "unauthorized");
}
