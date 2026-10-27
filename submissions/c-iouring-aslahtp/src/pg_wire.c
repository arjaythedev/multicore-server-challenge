#include "pg_wire.h"

#include "base64.h"
#include "hmac.h"
#include "util.h"

/* ---- building frontend messages ---- */

static inline void put_i16(struct buf *b, uint16_t v) {
    store_be16(buf_reserve(b, 2), v);
    b->len += 2;
}
static inline void put_i32(struct buf *b, uint32_t v) {
    store_be32(buf_reserve(b, 4), v);
    b->len += 4;
}
static inline void put_cstr(struct buf *b, const char *s) { buf_put(b, s, strlen(s) + 1); }

/* Writes the type byte and a length placeholder; returns where the length goes. */
static size_t msg_begin(struct buf *b, char type) {
    buf_putc(b, type);
    size_t at = b->len;
    put_i32(b, 0);
    return at;
}
static void msg_end(struct buf *b, size_t at) { store_be32(b->p + at, (uint32_t)(b->len - at)); }

void pg_startup(struct buf *b, const char *user, const char *database) {
    size_t at = b->len;
    put_i32(b, 0);
    put_i32(b, 196608);  /* protocol 3.0 */
    put_cstr(b, "user"), put_cstr(b, user);
    put_cstr(b, "database"), put_cstr(b, database);
    put_cstr(b, "client_encoding"), put_cstr(b, "UTF8");
    put_cstr(b, "application_name"), put_cstr(b, "conduit-c-iouring");
    buf_putc(b, 0);
    store_be32(b->p + at, (uint32_t)(b->len - at));
}

void pg_query(struct buf *b, const char *sql) {
    size_t at = msg_begin(b, 'Q');
    put_cstr(b, sql);
    msg_end(b, at);
}

void pg_parse(struct buf *b, const char *name, const char *sql, uint16_t nparams, const uint32_t *oids) {
    size_t at = msg_begin(b, 'P');
    put_cstr(b, name);
    put_cstr(b, sql);
    put_i16(b, nparams);
    for (uint16_t i = 0; i < nparams; i++) put_i32(b, oids[i]);
    msg_end(b, at);
}

void pg_describe_stmt(struct buf *b, const char *name) {
    size_t at = msg_begin(b, 'D');
    buf_putc(b, 'S');
    put_cstr(b, name);
    msg_end(b, at);
}

void pg_execute(struct buf *b) {
    /* 'E', length 9, unnamed portal, no row limit: fixed bytes. */
    static const char msg[10] = {'E', 0, 0, 0, 9, 0, 0, 0, 0, 0};
    buf_put(b, msg, sizeof msg);
}

void pg_sync(struct buf *b) {
    static const char msg[5] = {'S', 0, 0, 0, 4};
    buf_put(b, msg, sizeof msg);
}

void pg_terminate(struct buf *b) {
    static const char msg[5] = {'X', 0, 0, 0, 4};
    buf_put(b, msg, sizeof msg);
}

void pg_bind_begin(struct pg_bind *pb, struct buf *b, const char *stmt) {
    pb->b = b;
    pb->n = 0;
    pb->msg_at = msg_begin(b, 'B');
    buf_putc(b, 0);  /* unnamed portal */
    put_cstr(b, stmt);
    put_i16(b, 1);   /* one parameter format code for all ... */
    put_i16(b, 1);   /* ... binary */
    pb->count_at = b->len;
    put_i16(b, 0);   /* parameter count, patched in pg_bind_end */
}

void pg_bind_null(struct pg_bind *pb) {
    put_i32(pb->b, 0xffffffff);
    pb->n++;
}

void pg_bind_i64(struct pg_bind *pb, int64_t v) {
    char *d = buf_reserve(pb->b, 12);
    store_be32(d, 8);
    store_be64(d + 4, (uint64_t)v);
    pb->b->len += 12;
    pb->n++;
}

void pg_bind_i32(struct pg_bind *pb, int32_t v) {
    char *d = buf_reserve(pb->b, 8);
    store_be32(d, 4);
    store_be32(d + 4, (uint32_t)v);
    pb->b->len += 8;
    pb->n++;
}

void pg_bind_bool(struct pg_bind *pb, bool v) {
    char *d = buf_reserve(pb->b, 5);
    store_be32(d, 1);
    d[4] = v;
    pb->b->len += 5;
    pb->n++;
}

void pg_bind_text(struct pg_bind *pb, const char *s, size_t n) {
    put_i32(pb->b, (uint32_t)n);
    buf_put(pb->b, s, n);
    pb->n++;
}

void pg_bind_array_begin(struct pg_bind *pb, uint32_t elem_oid, size_t *at) {
    /* length, ndim, has-null flag, element type, size of dimension 1, its lower bound */
    *at = pb->b->len;
    char *d = buf_reserve(pb->b, 24);
    memset(d, 0, 24);
    store_be32(d + 12, elem_oid);
    store_be32(d + 20, 1);
    pb->b->len += 24;
}

void pg_bind_array_i64(struct pg_bind *pb, int64_t v) {
    char *d = buf_reserve(pb->b, 12);
    store_be32(d, 8);
    store_be64(d + 4, (uint64_t)v);
    pb->b->len += 12;
}

void pg_bind_array_i32(struct pg_bind *pb, int32_t v) {
    char *d = buf_reserve(pb->b, 8);
    store_be32(d, 4);
    store_be32(d + 4, (uint32_t)v);
    pb->b->len += 8;
}

void pg_bind_array_text(struct pg_bind *pb, const char *s, size_t n) {
    put_i32(pb->b, (uint32_t)n);
    buf_put(pb->b, s, n);
}

void pg_bind_array_null(struct pg_bind *pb) { put_i32(pb->b, 0xffffffff); }

void pg_bind_array_end(struct pg_bind *pb, size_t at, uint32_t count, bool has_null) {
    char *d = pb->b->p + at;
    store_be32(d, (uint32_t)(pb->b->len - at - 4));
    if (count == 0) {
        /* An empty array has no dimensions: drop the dimension header (8 bytes, no elements follow). */
        store_be32(d, 12);
        store_be32(d + 4, 0);
        pb->b->len = at + 16;
    } else {
        store_be32(d + 4, 1);
        store_be32(d + 8, has_null);
        store_be32(d + 16, count);
    }
    pb->n++;
}

void pg_bind_i64_array(struct pg_bind *pb, const int64_t *v, uint32_t n) {
    size_t at;
    pg_bind_array_begin(pb, OID_INT8, &at);
    for (uint32_t i = 0; i < n; i++) pg_bind_array_i64(pb, v[i]);
    pg_bind_array_end(pb, at, n, false);
}

void pg_bind_text_array(struct pg_bind *pb, const char *const *s, const uint32_t *lens, uint32_t n) {
    size_t at;
    pg_bind_array_begin(pb, OID_TEXT, &at);
    for (uint32_t i = 0; i < n; i++) pg_bind_array_text(pb, s[i], lens[i]);
    pg_bind_array_end(pb, at, n, false);
}

void pg_bind_end(struct pg_bind *pb) {
    put_i16(pb->b, 1);  /* one result format code for all ... */
    put_i16(pb->b, 1);  /* ... binary */
    store_be16(pb->b->p + pb->count_at, pb->n);
    msg_end(pb->b, pb->msg_at);
}

/* ---- reading backend messages ---- */

ptrdiff_t pg_next(const uint8_t *p, size_t n, struct pg_msg *m) {
    if (n < 5) return 0;
    uint32_t len = load_be32(p + 1);
    if (len < 4 || len > (1u << 30)) return -1;
    if (n - 1 < len) return 0;
    m->type = (char)p[0];
    m->len = len - 4;
    m->body = p + 5;
    return (ptrdiff_t)len + 1;
}

void pg_parse_error(const struct pg_msg *m, struct pg_error *e) {
    const char *p = (const char *)m->body, *end = p + m->len;
    memcpy(e->sqlstate, "XX000", 6);
    e->message = "";
    while (p < end && *p) {
        char field = *p++;
        const char *val = p;
        size_t n = strnlen(val, (size_t)(end - val));
        if (n == (size_t)(end - val)) break;  /* unterminated */
        if (field == 'C' && n == 5) memcpy(e->sqlstate, val, 6);
        else if (field == 'M') e->message = val;
        p = val + n + 1;
    }
}

bool pg_row_init(struct pg_row *r, const struct pg_msg *m) {
    if (m->len < 2) return false;
    r->ncols = load_be16(m->body);
    r->p = m->body + 2;
    r->end = m->body + m->len;
    return true;
}

bool pg_array_init(struct pg_array *a, const uint8_t *v, int32_t len) {
    if (len < 12) return false;
    uint32_t ndim = load_be32(v);
    a->elem_oid = load_be32(v + 8);
    a->end = v + len;
    if (ndim == 0) {
        a->n = 0;
        a->p = v + 12;
        return true;
    }
    if (ndim != 1 || len < 20) return false;
    a->n = load_be32(v + 12);
    a->p = v + 20;
    return true;
}

/* ---- startup and SCRAM-SHA-256 ---- */

enum { ST_START, ST_SASL_SENT, ST_SASL_FINAL, ST_AUTHED };

void pg_auth_init(struct pg_auth *a, const char *user, const char *password, const uint8_t nonce_random[18]) {
    memset(a, 0, sizeof *a);
    a->user = user;
    a->password = password;
    a->state = ST_START;
    b64_encode(a->client_nonce, nonce_random, 18);  /* 24 characters, no ',' in the alphabet */
}

static int fail(struct pg_auth *a, const char *why) {
    snprintf(a->error, sizeof a->error, "%s", why);
    return PG_AUTH_FAILED;
}

/* The value of attribute "<k>=" in a SCRAM message, or NULL. */
static const char *scram_attr(const char *msg, size_t n, char k, size_t *vlen) {
    const char *p = msg, *end = msg + n;
    while (p < end) {
        const char *comma = memchr(p, ',', (size_t)(end - p));
        const char *stop = comma ? comma : end;
        if (stop - p >= 2 && p[0] == k && p[1] == '=') {
            *vlen = (size_t)(stop - p - 2);
            return p + 2;
        }
        p = stop + 1;
    }
    return NULL;
}

static int sasl_start(struct pg_auth *a, const struct pg_msg *m, struct buf *out) {
    /* The body after the auth code lists mechanisms, each NUL-terminated, ending with an empty one. */
    const char *p = (const char *)m->body + 4, *end = (const char *)m->body + m->len;
    bool have = false;
    while (p < end && *p) {
        size_t n = strnlen(p, (size_t)(end - p));
        if (n == 13 && memcmp(p, "SCRAM-SHA-256", 13) == 0) have = true;
        p += n + 1;
    }
    if (!have) return fail(a, "server offers no SCRAM-SHA-256");

    a->cfb_len = (size_t)snprintf(a->client_first_bare, sizeof a->client_first_bare, "n=,r=%s", a->client_nonce);
    size_t at = msg_begin(out, 'p');
    put_cstr(out, "SCRAM-SHA-256");
    put_i32(out, (uint32_t)(3 + a->cfb_len));
    buf_put(out, "n,,", 3);
    buf_put(out, a->client_first_bare, a->cfb_len);
    msg_end(out, at);
    a->state = ST_SASL_SENT;
    return PG_AUTH_MORE;
}

static int sasl_continue(struct pg_auth *a, const struct pg_msg *m, struct buf *out) {
    const char *sf = (const char *)m->body + 4;
    size_t sflen = m->len - 4, rlen = 0, slen = 0, ilen = 0;
    const char *r = scram_attr(sf, sflen, 'r', &rlen), *s = scram_attr(sf, sflen, 's', &slen);
    const char *it = scram_attr(sf, sflen, 'i', &ilen);
    size_t cnl = strlen(a->client_nonce);
    int64_t iters;
    if (!r || !s || !it || rlen <= cnl || memcmp(r, a->client_nonce, cnl) != 0) return fail(a, "bad SCRAM server-first");
    if (!parse_uint(it, ilen, &iters) || iters < 1 || iters > 10000000) return fail(a, "bad SCRAM iteration count");
    uint8_t salt[128];
    ptrdiff_t saltlen = slen <= 160 ? b64_decode(salt, s, slen) : -1;
    if (saltlen <= 0) return fail(a, "bad SCRAM salt");

    uint8_t salted[32], client_key[32], stored_key[32], server_key[32], client_sig[32], proof[32];
    pbkdf2_sha256(a->password, strlen(a->password), salt, (size_t)saltlen, (uint32_t)iters, salted);
    hmac_sha256(salted, 32, LIT("Client Key"), client_key);
    sha256(client_key, 32, stored_key);
    hmac_sha256(salted, 32, LIT("Server Key"), server_key);

    /* AuthMessage = client-first-bare "," server-first "," client-final-without-proof */
    struct buf auth_msg, final;
    buf_init(&auth_msg, 512);
    buf_init(&final, 256);
    buf_lit(&final, "c=biws,r=");
    buf_put(&final, r, rlen);
    buf_put(&auth_msg, a->client_first_bare, a->cfb_len);
    buf_putc(&auth_msg, ',');
    buf_put(&auth_msg, sf, sflen);
    buf_putc(&auth_msg, ',');
    buf_put(&auth_msg, final.p, final.len);

    hmac_sha256(stored_key, 32, auth_msg.p, auth_msg.len, client_sig);
    for (int i = 0; i < 32; i++) proof[i] = client_key[i] ^ client_sig[i];
    hmac_sha256(server_key, 32, auth_msg.p, auth_msg.len, a->server_signature);

    buf_lit(&final, ",p=");
    final.len += b64_encode(buf_reserve(&final, 48), proof, 32);

    size_t at = msg_begin(out, 'p');
    buf_put(out, final.p, final.len);
    msg_end(out, at);
    buf_free(&auth_msg);
    buf_free(&final);
    a->state = ST_SASL_FINAL;
    return PG_AUTH_MORE;
}

static int sasl_final(struct pg_auth *a, const struct pg_msg *m) {
    size_t vlen;
    const char *v = scram_attr((const char *)m->body + 4, m->len - 4, 'v', &vlen);
    uint8_t sig[48];
    if (!v || vlen > 64 || b64_decode(sig, v, vlen) != 32 || !ct_equal(sig, a->server_signature, 32))
        return fail(a, "SCRAM server signature mismatch");
    return PG_AUTH_MORE;
}

int pg_auth_step(struct pg_auth *a, const struct pg_msg *m, struct buf *out) {
    switch (m->type) {
    case 'R': {
        if (m->len < 4) return fail(a, "short authentication message");
        uint32_t code = load_be32(m->body);
        switch (code) {
        case 0:  /* AuthenticationOk */
            a->state = ST_AUTHED;
            return PG_AUTH_MORE;
        case 3: {  /* cleartext password */
            size_t at = msg_begin(out, 'p');
            put_cstr(out, a->password);
            msg_end(out, at);
            return PG_AUTH_MORE;
        }
        case 10:
            if (a->state != ST_START) return fail(a, "unexpected SASL request");
            return sasl_start(a, m, out);
        case 11:
            if (a->state != ST_SASL_SENT) return fail(a, "unexpected SASL continue");
            return sasl_continue(a, m, out);
        case 12:
            if (a->state != ST_SASL_FINAL) return fail(a, "unexpected SASL final");
            return sasl_final(a, m);
        default:
            return fail(a, "unsupported authentication method (use scram-sha-256)");
        }
    }
    case 'E': {
        struct pg_error e;
        pg_parse_error(m, &e);
        snprintf(a->error, sizeof a->error, "%s: %s", e.sqlstate, e.message);
        return PG_AUTH_FAILED;
    }
    case 'Z':
        return a->state == ST_AUTHED ? PG_AUTH_READY : fail(a, "ready before authentication");
    default:  /* ParameterStatus, BackendKeyData, NoticeResponse */
        return PG_AUTH_MORE;
    }
}

/* ---- connection strings ---- */

static bool copy_part(char *dst, size_t cap, const char *s, size_t n, bool decode) {
    if (n >= cap) return false;
    if (decode) {
        ptrdiff_t d = pct_decode(dst, s, n, false);
        if (d < 0) return false;
        n = (size_t)d;
    } else {
        memcpy(dst, s, n);
    }
    dst[n] = 0;
    return true;
}

bool pg_url_parse(const char *url, struct pg_url *u) {
    const char *p;
    memset(u, 0, sizeof *u);
    if (strncmp(url, "postgres://", 11) == 0) p = url + 11;
    else if (strncmp(url, "postgresql://", 13) == 0) p = url + 13;
    else return false;

    const char *end = p + strcspn(p, "/?");
    const char *at = NULL;
    for (const char *q = p; q < end; q++)
        if (*q == '@') at = q;
    if (at) {
        const char *colon = memchr(p, ':', (size_t)(at - p));
        const char *uend = colon ? colon : at;
        if (!copy_part(u->user, sizeof u->user, p, (size_t)(uend - p), true)) return false;
        if (colon && !copy_part(u->password, sizeof u->password, colon + 1, (size_t)(at - colon - 1), true))
            return false;
        p = at + 1;
    }
    const char *colon = memchr(p, ':', (size_t)(end - p));
    const char *hend = colon ? colon : end;
    if (!copy_part(u->host, sizeof u->host, p, (size_t)(hend - p), false)) return false;
    if (colon && !copy_part(u->port, sizeof u->port, colon + 1, (size_t)(end - colon - 1), false)) return false;
    if (*end == '/') {
        const char *db = end + 1, *dend = db + strcspn(db, "?");
        if (!copy_part(u->dbname, sizeof u->dbname, db, (size_t)(dend - db), true)) return false;
    }
    if (!u->host[0]) strcpy(u->host, "localhost");
    if (!u->port[0]) strcpy(u->port, "5432");
    if (!u->user[0]) strcpy(u->user, "postgres");
    if (!u->dbname[0]) strcpy(u->dbname, u->user);
    return true;
}
