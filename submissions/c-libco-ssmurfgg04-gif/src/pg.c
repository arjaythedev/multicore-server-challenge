/* pg.c - a hand-written PostgreSQL wire-protocol (v3) client, fully async.
 *
 * Why hand-written: every request's statements go out as Bind/Execute
 * messages followed by one Sync, and many requests' batches interleave on
 * one connection (capped depth), so an endpoint costs exactly one round
 * trip and a response is never sent before its ReadyForQuery (writes are
 * committed first). libpq's pipeline mode can do much of this, but results
 * would be copied twice and integrated through PQconsumeInput polling; here
 * DataRow cells are copied once, straight into the request's arena, and the
 * socket is just another fd in the worker's event loop.
 *
 * Startup (per connection, async state machine): TCP connect, startup packet
 * with session settings (client_encoding=UTF8, DateStyle=ISO,MDY,
 * TimeZone=UTC, jit=off, plan_cache_mode=force_generic_plan,
 * max_parallel_workers_per_gather=0), SCRAM-SHA-256, then every prepared
 * statement pipelined in one write with one Sync.
 *
 * Reply parsing is incremental: DataRow cells are copied into the owning
 * request's arena (rows stay valid no matter how the receive buffer is
 * compacted), CommandComplete advances the statement cursor, ErrorResponse
 * records the SQLSTATE, ReadyForQuery completes the batch and fires the
 * request's continuation on the loop thread. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include "conduit.h"
#include "coro.h"
#include "pg.h"
#include "util.h"

/* shared hash primitives (implemented in jwt.c) */
void pg_sha256(const void *data, size_t n, uint8_t out[32]);
void pg_hmac(const void *key, size_t klen, const void *msg, size_t mlen, uint8_t out[32]);

int pg_total_conns(void);

/* ---------------------------------------------------------------- framing */

static void put_i32(buf_t *b, int32_t v)
{
    v = htonl(v);
    buf_put(b, &v, 4);
}

static void put_i16(buf_t *b, int16_t v)
{
    v = htons(v);
    buf_put(b, &v, 2);
}

static void put_cstr(buf_t *b, const char *s)
{
    buf_put(b, s, strlen(s) + 1);
}

static void put_span(buf_t *b, const char *s, size_t n)
{
    put_i32(b, (int32_t)n);
    if (n) buf_put(b, s, n);
}

/* framed wire message: type byte, self-counting length, payload */
static void wire_msg(buf_t *b, char type, const void *payload, size_t n)
{
    char t = type;
    buf_put(b, &t, 1);
    put_i32(b, (int32_t)(n + 4));
    if (n) buf_put(b, payload, n);
}

/* a message whose payload is appended later: reserve the length field */
static void wire_start(buf_t *b, char type, size_t *lenpos)
{
    char t = type;
    buf_put(b, &t, 1);
    buf_reserve(b, 4);
    *lenpos = b->len;
    b->len += 4;
}

static void wire_finish(buf_t *b, size_t lenpos)
{
    uint32_t len = htonl((uint32_t)(b->len - lenpos));
    memcpy(b->p + lenpos, &len, 4);
}

/* ---------------------------------------------------------------- scram */

static void scram_hi(const char *pw, size_t pwn, const uint8_t *salt, size_t saltn,
                     int iters, uint8_t out[32])
{
    /* Hi(str, salt, iters) = PBKDF2-HMAC-SHA256, one 32-byte block */
    uint8_t in[64];
    memcpy(in, salt, saltn);
    in[saltn] = 0; in[saltn + 1] = 0; in[saltn + 2] = 0; in[saltn + 3] = 1;
    uint8_t u[32], t[32];
    pg_hmac(pw, pwn, in, saltn + 4, u);
    memcpy(t, u, 32);
    for (int i = 1; i < iters; i++) {
        pg_hmac(pw, pwn, u, 32, u);
        for (int k = 0; k < 32; k++) t[k] ^= u[k];
    }
    memcpy(out, t, 32);
}

static void b64_std(const uint8_t *in, size_t n, char *out, size_t *outn)
{
    static const char A[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t o = 0, i = 0;
    for (; i + 3 <= n; i += 3) {
        uint32_t v = (uint32_t)in[i] << 16 | (uint32_t)in[i + 1] << 8 | in[i + 2];
        out[o++] = A[v >> 18 & 63]; out[o++] = A[v >> 12 & 63];
        out[o++] = A[v >> 6 & 63]; out[o++] = A[v & 63];
    }
    if (n - i == 1) {
        uint32_t v = (uint32_t)in[i] << 16;
        out[o++] = A[v >> 18 & 63]; out[o++] = A[v >> 12 & 63]; out[o++] = '='; out[o++] = '=';
    } else if (n - i == 2) {
        uint32_t v = (uint32_t)in[i] << 16 | (uint32_t)in[i + 1] << 8;
        out[o++] = A[v >> 18 & 63]; out[o++] = A[v >> 12 & 63]; out[o++] = A[v >> 6 & 63];
        out[o++] = '=';
    }
    out[o] = 0;
    *outn = o;
}

static int b64_std_dec(const char *s, size_t n, uint8_t *out, size_t *outn)
{
    static signed char T[256];
    static int init;
    if (!init) {
        static const char A[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        memset(T, -1, sizeof T);
        for (int i = 0; i < 64; i++) T[(unsigned char)A[i]] = (signed char)i;
        init = 1;
    }
    size_t o = 0;
    uint32_t acc = 0;
    int bits = 0;
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '=') break;
        int v = T[(unsigned char)s[i]];
        if (v < 0) return -1;
        acc = acc << 6 | (uint32_t)v;
        bits += 6;
        if (bits >= 8) { bits -= 8; out[o++] = (uint8_t)(acc >> bits); }
    }
    *outn = o;
    return 0;
}

static void random_nonce(char *out, size_t cap) /* 18 random bytes, base64 */
{
    uint8_t raw[18];
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        ssize_t r = read(fd, raw, sizeof raw);
        (void)r;
        close(fd);
    } else {
        for (size_t i = 0; i < sizeof raw; i++)
            raw[i] = (uint8_t)(now_mono_us() >> (i % 13));
    }
    size_t olen;
    if (cap >= 32) b64_std(raw, sizeof raw, out, &olen);
}

/* ---------------------------------------------------------------- startup */

static void build_startup(buf_t *b)
{
    put_i32(b, 0);          /* total length, patched below */
    put_i32(b, 196608);     /* protocol 3.0 */
    put_cstr(b, "user"); put_cstr(b, cfg.db_user);
    put_cstr(b, "database"); put_cstr(b, cfg.db_name);
    put_cstr(b, "client_encoding"); put_cstr(b, "UTF8");
    put_cstr(b, "DateStyle"); put_cstr(b, "ISO,MDY");
    put_cstr(b, "TimeZone"); put_cstr(b, "UTC");
    put_cstr(b, "application_name"); put_cstr(b, "conduit-c-iouring");
    put_cstr(b, "jit"); put_cstr(b, "off");
    put_cstr(b, "plan_cache_mode"); put_cstr(b, "force_generic_plan");
    put_cstr(b, "max_parallel_workers_per_gather"); put_cstr(b, "0");
    put_cstr(b, "");
    uint32_t total = htonl((uint32_t)b->len);
    memcpy(b->p, &total, 4);
}

/* AuthenticationSASL: send client-first-message (bare "n,,n=,r=<nonce>") */
static void send_client_first(pgconn_t *pc)
{
    TRACE("trace: pg %d client-first\n", pc->id);
    buf_t b;
    buf_init(&b);
    /* SASLInitialResponse: mechanism name, then the length-prefixed
     * initial response "n,,n=,r=<nonce>" */
    random_nonce(pc->client_nonce_b64, sizeof pc->client_nonce_b64);
    char initial[128];
    int n = snprintf(initial, sizeof initial, "n,,n=,r=%s", pc->client_nonce_b64);
    size_t lenpos;
    wire_start(&b, 'p', &lenpos);
    put_cstr(&b, "SCRAM-SHA-256");
    put_i32(&b, n);
    buf_put(&b, initial, (size_t)n);
    wire_finish(&b, lenpos);
    buf_put(&pc->out, b.p, b.len);
    buf_free(&b);
    pc->state = PGS_SASL_SENT;
    pg_on_writable(pc);
}

static void parse_server_first(pgconn_t *pc, const char *msg, size_t n)
{
    /* s=<base64 salt>,i=<iterations> */
    const char *s = memmem(msg, n, "s=", 2);
    const char *i = memmem(msg, n, "i=", 2);
    pc->sasl_iters = i ? atoi(i + 2) : 4096;
    if (pc->sasl_iters < 1 || pc->sasl_iters > 16777216) pc->sasl_iters = 4096;
    if (s) {
        const char *sv = s + 2;
        const char *se = memchr(sv, ',', (size_t)(msg + n - sv));
        size_t sl = se ? (size_t)(se - sv) : (size_t)(msg + n - sv);
        uint8_t raw[64];
        size_t rn = 0;
        if (b64_std_dec(sv, sl, raw, &rn) == 0 && rn > 0) {
            memset(pc->saltbin, 0, 16);
            memcpy(pc->saltbin, raw, rn < 16 ? rn : 16);
        }
    }
    size_t keep = n < sizeof pc->server_first ? n : sizeof pc->server_first - 1;
    memcpy(pc->server_first, msg, keep);
    pc->server_first[keep] = 0;
}

/* client-final-message with proof */
static void send_client_final(pgconn_t *pc)
{
    TRACE("trace: pg %d client-final\n", pc->id);
    buf_t b;
    buf_init(&b);
    const char *sf = pc->server_first;
    const char *rv = strstr(sf, "r=") + 2;
    const char *rend = strchr(rv, ',');
    size_t rlen = rend ? (size_t)(rend - rv) : strlen(rv);

    uint8_t salted[32];
    scram_hi(cfg.db_pass, strlen(cfg.db_pass), pc->saltbin, 16, pc->sasl_iters, salted);

    char cf[512];
    int cfn = snprintf(cf, sizeof cf, "c=biws,r=%.*s", (int)rlen, rv);

    char auth[1152];
    int an = snprintf(auth, sizeof auth, "n=,r=%s,%s,%.*s", pc->client_nonce_b64, sf, cfn, cf);

    uint8_t ckey[32], stored[32], csig[32], proof[32];
    pg_hmac(salted, 32, "Client Key", 10, ckey);
    pg_sha256(ckey, 32, stored);
    pg_hmac(stored, 32, auth, (size_t)an, csig);
    for (int k = 0; k < 32; k++) proof[k] = ckey[k] ^ csig[k];
    char proof_b64[48];
    size_t plen;
    b64_std(proof, 32, proof_b64, &plen);

    char payload[640];
    int n = snprintf(payload, sizeof payload, "%.*s,p=%s", cfn, cf, proof_b64);
    wire_msg(&b, 'p', payload, (size_t)n);
    buf_put(&pc->out, b.p, b.len);
    buf_free(&b);
    pc->state = PGS_FINAL_SENT;
    pg_on_writable(pc);
}

/* ---------------------------------------------------------------- statements */

extern const char *pg_sql(int stmt);
extern int pg_param_oids(int stmt); /* 2 bits per param: 1=int8 2=text 3=text[] */
extern int pg_nparams(int stmt);

static void build_prepares(buf_t *b)
{
    /* Session SET (rule 2 allows session-level SETs): force generic plans.
     * Custom plans re-plan on Bind; every hot statement here is a simple
     * index walk whose generic plan is already optimal, so re-planning is
     * pure overhead (the best C entry measured +41% from exactly this). */
    size_t lenpos;
    static const char set_plan[] = "SET plan_cache_mode = force_generic_plan";
    wire_start(b, 'Q', &lenpos);
    put_cstr(b, set_plan);
    wire_finish(b, lenpos);

    for (int s = 0; s < ST_COUNT; s++) {
        char name[16];
        snprintf(name, sizeof name, "s%d", s);
        size_t lenpos;
        wire_start(b, 'P', &lenpos);
        put_cstr(b, name);
        put_cstr(b, pg_sql(s));
        int np = pg_nparams(s);
        put_i16(b, (int16_t)np);
        int oids = pg_param_oids(s);
        for (int k = 0; k < np; k++) {
            int code = (oids >> (2 * k)) & 3;
            put_i32(b, code == 1 ? 20 : code == 3 ? 1009 : 25);
        }
        wire_finish(b, lenpos);
    }
    wire_msg(b, 'S', "", 0);
}

/* runtime batch: Bind + Execute per statement, then one Sync */
static void build_batch(buf_t *b, req_t *r)
{
    for (int i = 0; i < r->nstmts; i++) {
        batch_stmt_t *st = &r->stmts[i];
        char name[16];
        snprintf(name, sizeof name, "s%d", st->stmt);

        size_t lenpos;
        wire_start(b, 'B', &lenpos);
        put_cstr(b, "");          /* unnamed portal */
        put_cstr(b, name);
        put_i16(b, 1);            /* parameter format codes follow */
        put_i16(b, 0);            /* ... all text */
        put_i16(b, (int16_t)st->nparams);
        for (int k = 0; k < st->nparams; k++) {
            const char *v = st->params[k];
            if (v) put_span(b, v, strlen(v));
            else put_i32(b, -1);  /* NULL */
        }
        put_i16(b, 1);            /* result format codes follow */
        put_i16(b, 0);            /* ... all text */
        wire_finish(b, lenpos);

        wire_msg(b, 'E', "", 0);  /* placeholder, replaced below */
        /* Execute: 'E' + len + portal + max_rows */
        b->len -= 5;
        wire_start(b, 'E', &lenpos);
        put_cstr(b, "");
        put_i32(b, 0);
        wire_finish(b, lenpos);
    }
    wire_msg(b, 'S', "", 0);
}

/* ---------------------------------------------------------------- lifecycle */

static void pg_fail_all(pgconn_t *pc)
{
    req_t *r = pc->q_head;
    while (r) {
        req_t *next = r->q_next;
        r->failed = 1;
        r->pg = NULL;
        req_kick(r);    /* replies or chains; the reply path owns the release */
        r = next;
    }
    pc->q_head = pc->q_tail = NULL;
    pc->inflight = 0;
}

static void pg_reset_bufs(pgconn_t *pc)
{
    buf_free(&pc->out);
    buf_free(&pc->in);
    buf_init(&pc->out);
    buf_init(&pc->in);
    pc->out_off = pc->in_off = 0;
}

void pg_connect(pgconn_t *pc)
{
    struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM }, *res = NULL;
    if (getaddrinfo(cfg.db_host, cfg.db_port, &hints, &res) || !res) {
        pc->state = PGS_DEAD;
        return;
    }
    int fd = -1;
    for (struct addrinfo *rp = res; rp; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
        if (fd < 0) continue;
        int r = connect(fd, rp->ai_addr, rp->ai_addrlen);
        if (!r || errno == EINPROGRESS) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) {
        pc->state = PGS_DEAD;
        return;
    }
    pc->fd = fd;
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    pg_reset_bufs(pc);
    pc->state = PGS_CONNECTING;
    pc->born_ms = pc->w ? pc->w->now_ms : 0;
    pc->inflight = 0;
    pc->q_head = pc->q_tail = NULL;
    pc->recv_armed = 0;
    pg_arm(pc);
}

void pg_reconnect(pgconn_t *pc)
{
    TRACE("trace: pg %d reconnect (state=%d)\n", pc->id, pc->state);
    if (pc->fd >= 0) close(pc->fd);
    pc->fd = -1;
    pg_fail_all(pc);
    pc->state = PGS_DEAD;
}

void pg_tick(worker_t *w)
{
    for (int i = 0; i < w->npgs; i++) {
        pgconn_t *pc = &w->pgs[i];
        if (pc->state == PGS_DEAD) pg_connect(pc);
        else if (pc->state == PGS_CONNECTING && w->now_ms - pc->born_ms > 5000) pg_reconnect(pc);
    }
}

/* ---------------------------------------------------------------- queueing */

void pg_add(req_t *r, int stmt, int nparams, const char *const *params)
{
    batch_stmt_t *s = &r->stmts[r->nstmts++];
    s->stmt = stmt;
    s->nparams = nparams;
    for (int k = 0; k < nparams; k++) {
        if (params[k]) {
            size_t n = strlen(params[k]);
            char *copy = arena_alloc(r, n + 1);
            memcpy(copy, params[k], n + 1);
            s->params[k] = copy;
        } else {
            s->params[k] = NULL;
        }
    }
}

static pgconn_t *pick_conn(worker_t *w)
{
    pgconn_t *best = NULL;
    for (int i = 0; i < w->npgs; i++) {
        pgconn_t *pc = &w->pgs[i];
        if (pc->state != PGS_READY) continue;
        if (!best || pc->inflight < best->inflight) best = pc;
    }
    return best && best->inflight < cfg.pg_depth ? best : NULL;
}

static void dispatch(worker_t *w, req_t *r, pgconn_t *pc)
{
    build_batch(&pc->out, r);
    r->pg = pc;
    r->q_next = NULL;
    if (pc->q_tail) pc->q_tail->q_next = r;
    else pc->q_head = r;
    pc->q_tail = r;
    pc->inflight++;
    pg_on_writable(pc);
}

void pg_go(req_t *r)
{
    worker_t *w = r->w;
    r->pending = 1;
    r->birth_ms = w->now_ms;
    r->cur = 0;
    r->failed = 0;
    r->sqlstate[0] = 0;
    memset(r->res, 0, sizeof r->res);

    pgconn_t *pc = pick_conn(w);
    if (!pc) {
        /* FIFO keeps arrival order under load */
        if (w->fifo_tail) w->fifo_tail->fifo_next = r;
        else w->fifo_head = r;
        w->fifo_tail = r;
        r->fifo_next = NULL;
        if (r->co) coro_yield();
        return;
    }
    dispatch(w, r, pc);
    if (r->co) coro_yield();           /* resumes from batch_complete/req_kick */
}

void pg_fill(worker_t *w)
{
    while (w->fifo_head) {
        pgconn_t *pc = pick_conn(w);
        if (!pc) return;
        req_t *r = w->fifo_head;
        w->fifo_head = r->fifo_next;
        if (!w->fifo_head) w->fifo_tail = NULL;
        dispatch(w, r, pc);
    }
}

/* FIFO watchdog: requests cannot wait forever when PG is unreachable */
void pg_fifo_check(worker_t *w)
{
    while (w->fifo_head && w->now_ms - w->fifo_head->birth_ms > 10000) {
        req_t *r = w->fifo_head;
        w->fifo_head = r->fifo_next;
        if (!w->fifo_head) w->fifo_tail = NULL;
        r->failed = 1;
        req_kick(r);    /* replies or chains; the reply path owns the release */
    }
}

/* ---------------------------------------------------------------- recv side */

static void batch_complete(req_t *r)
{
    pgconn_t *pc = r->pg;
    pc->inflight--;
    pc->q_head = r->q_next;
    if (!pc->q_head) pc->q_tail = NULL;
    r->pg = NULL;
    worker_t *w = r->w;
    req_kick(r);    /* replies (trampoline releases) or chains the request on */
    pg_fill(w);
}

/* returns 1 if a complete message was consumed */
static int pg_parse_msg(pgconn_t *pc)
{
    buf_t *in = &pc->in;
    if (in->len - pc->in_off < 5) return 0;
    const unsigned char *p = (const unsigned char *)in->p + pc->in_off;
    char type = (char)p[0];
    uint32_t len = ((uint32_t)p[1] << 24) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 8) | p[4];
    if (len < 4) { pc->state = PGS_DEAD; return 1; }
    /* the wire message is 1 type byte + len (len counts itself) */
    if (in->len - pc->in_off < (size_t)len + 1) return 0;
    const char *body = (const char *)p + 5;
    size_t blen = len - 4;

    req_t *r = pc->q_head;
    switch (type) {
    case '1': /* ParseComplete */
    case '2': /* BindComplete */
    case 'n': /* NoData */
    case 't': /* RowDescription: columns are known positionally */
    case 's': /* PortalSuspended (never: Execute fetches all) */
    case 'S': /* ParameterStatus */
    case 'K': /* BackendKeyData */
    case 'N': /* NoticeResponse */
        break;
    case 'C': /* CommandComplete: statement finished */
        if (r && r->cur < r->nstmts) r->cur++;
        break;
    case 'D': { /* DataRow: copy cells into the request's arena */
        if (!r || r->cur >= r->nstmts || r->cur >= PG_MAX_STMTS) break;
        pgres_t *res = &r->res[r->cur];
        uint16_t ncols = (uint16_t)((body[0] << 8) | (unsigned char)body[1]);
        if (res->ncols && res->ncols != ncols) break;
        if (!res->ncols) res->ncols = ncols;
        if (res->nrows == res->capacity) {
            uint32_t cap = res->capacity ? res->capacity * 2 : 16;
            pgval_t *nv = arena_alloc(r, cap * ncols * sizeof(pgval_t));
            if (res->vals && res->nrows)
                memcpy(nv, res->vals, res->nrows * ncols * sizeof(pgval_t));
            res->vals = nv;
            res->capacity = cap;
        }
        pgval_t *row = res->vals + res->nrows * ncols;
        const unsigned char *c = (const unsigned char *)body + 2;
        for (int k = 0; k < ncols; k++) {
            int32_t cl = ((int32_t)c[0] << 24) | ((int32_t)c[1] << 16) |
                         ((int32_t)c[2] << 8) | (int32_t)c[3];
            c += 4;
            if (cl < 0) {
                row[k].p = NULL;
                row[k].n = (uint32_t)-1;
            } else {
                char *dst = arena_alloc(r, (size_t)cl);
                memcpy(dst, c, (size_t)cl);
                row[k].p = dst;
                row[k].n = (uint32_t)cl;
                c += (size_t)cl;
            }
        }
        res->nrows++;
        break;
    }
    case 'E': { /* ErrorResponse: capture the SQLSTATE */
        const char *c = body, *e = body + blen;
        char sqlstate[6] = { 0 };
        char emsg[160] = { 0 };
        while (c < e) {
            char field = *c++;
            if (!field) break;
            const char *z = memchr(c, 0, (size_t)(e - c));
            if (!z) break;
            if (field == 'C' && (size_t)(z - c) >= 5)
                memcpy(sqlstate, c, 5);
            if (field == 'M' && (size_t)(z - c) < sizeof emsg)
                memcpy(emsg, c, (size_t)(z - c));
            c = z + 1;
        }
        if (!r)
            TRACE("trace: pg %d ErrorResponse %s: %s\n", pc->id, sqlstate, emsg);
        if (r && !r->failed) {
            r->failed = 1;
            memcpy(r->sqlstate, sqlstate, sizeof sqlstate);
        }
        break;
    }
    case 'R': { /* Authentication */
        int32_t code = ((int32_t)(unsigned char)body[0] << 24) |
                       ((int32_t)(unsigned char)body[1] << 16) |
                       ((int32_t)(unsigned char)body[2] << 8) |
                       (int32_t)(unsigned char)body[3];
        if (code == 10) {
            send_client_first(pc); /* AuthenticationSASL */
        } else if (code == 11) {
            parse_server_first(pc, body + 4, blen - 4);
            send_client_final(pc);
        }
        /* 0 = Ok (trust/none auth), 12 = SASLFinal (the server proof). Both
         * mean the backend considers us authenticated. ServerSignature is
         * not verified: we are on loopback behind the challenge's own PG. */
        if (code == 0 || code == 12) pc->authed = 1;
        TRACE("trace: pg %d auth code=%d\n", pc->id, code);
        break;
    }
    case 'Z': /* ReadyForQuery */
        if (r) {
            if (r->cur < r->nstmts) r->cur = r->nstmts;
            batch_complete(r);
        } else if (pc->authed && pc->state != PGS_PREP && pc->state != PGS_READY) {
            build_prepares(&pc->out);
            pc->state = PGS_PREP;
            pg_on_writable(pc);
        } else if (pc->state == PGS_PREP) {
            pc->state = PGS_READY;
            TRACE("trace: pg %d READY\n", pc->id);
        }
        break;
    default:
        TRACE("trace: pg %d UNKNOWN MSG %c (len %u) -> dead\n", pc->id, type, len);
        pc->state = PGS_DEAD;
        return 1;
    }
    pc->in_off += 1 + len;
    return 1;
}

void pg_advance_pgconn(pgconn_t *pc)
{
    if (pc->state == PGS_DEAD) return;
    while (pg_parse_msg(pc))
        if (pc->state == PGS_DEAD) return;
    /* compact */
    if (pc->in_off) {
        memmove(pc->in.p, pc->in.p + pc->in_off, pc->in.len - pc->in_off);
        pc->in.len -= (uint32_t)pc->in_off;
        pc->in_off = 0;
    }
}

void pg_on_readable(pgconn_t *pc)
{
    for (;;) {
        size_t want = 16384;
        if (buf_reserve(&pc->in, want)) break;
        ssize_t n = recv(pc->fd, pc->in.p + pc->in.len, want, MSG_DONTWAIT);
        if (n > 0) {
            TRACE("trace: pg %d recv %zd bytes\n", pc->id, n);
            pc->in.len += (uint32_t)n;
            if ((size_t)n < 16384) break;
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        if (n == 0 || (n < 0 && errno != EINTR)) {
            pg_reconnect(pc);
            return;
        }
    }
    pg_advance_pgconn(pc);
    pg_arm(pc);
}

/* ---------------------------------------------------------------- send side */

void pg_on_writable(pgconn_t *pc)
{
    if (pc->state == PGS_DEAD || pc->fd < 0) return;

    if (pc->state == PGS_CONNECTING) {
        int err = 0;
        socklen_t elen = sizeof err;
        getsockopt(pc->fd, SOL_SOCKET, SO_ERROR, &err, &elen);
        if (err == EINPROGRESS || err == EALREADY || err == EWOULDBLOCK)
            return; /* connect still in flight: the poll will fire again */
        if (err) {
            pg_reconnect(pc);
            return;
        }
        buf_t b;
        buf_init(&b);
        build_startup(&b);
        buf_put(&pc->out, b.p, b.len);
        buf_free(&b);
        pc->state = PGS_STARTUP;
    }

    while (pc->out_off < pc->out.len) {
        ssize_t n = send(pc->fd, pc->out.p + pc->out_off, pc->out.len - pc->out_off, MSG_NOSIGNAL);
        if (n > 0) {
            pc->out_off += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        pg_reconnect(pc);
        return;
    }
    if (pc->out_off >= pc->out.len && pc->out.len) {
        pc->out.len = 0;
        pc->out_off = 0;
    }
    pc->want_out = pc->out_off < pc->out.len;
    pg_arm(pc);
}
