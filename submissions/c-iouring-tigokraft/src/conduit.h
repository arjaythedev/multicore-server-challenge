// Conduit API server: C + io_uring, a hand-written Postgres wire client, bcrypt from libxcrypt.
#ifndef CONDUIT_H
#define CONDUIT_H
#define _GNU_SOURCE
#include <liburing.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LIKELY(x) __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)

void die(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));
void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// ---------- strings, buffers, arenas (util.c) ----------

typedef struct { const char *p; size_t n; } str_t; // p == NULL: absent / SQL NULL
#define STR_NULL ((str_t){NULL, 0})
#define STRL(s) ((str_t){(s), sizeof(s) - 1})
static inline bool str_eq(str_t a, const char *lit) {
    size_t n = strlen(lit);
    return a.p && a.n == n && memcmp(a.p, lit, n) == 0;
}

typedef struct { char *p; size_t len, cap; } buf_t;
void buf_grow(buf_t *b, size_t need);
void buf_free(buf_t *b);
static inline void buf_put(buf_t *b, const void *s, size_t n) {
    if (UNLIKELY(b->cap - b->len < n)) buf_grow(b, n);
    memcpy(b->p + b->len, s, n);
    b->len += n;
}
static inline void buf_putc(buf_t *b, char c) {
    if (UNLIKELY(b->cap == b->len)) buf_grow(b, 1);
    b->p[b->len++] = c;
}
#define buf_lit(b, s) buf_put((b), (s), sizeof(s) - 1)
void buf_i64(buf_t *b, int64_t v);
void buf_json_str(buf_t *b, const char *s, size_t n); // "..." with JSON escaping
void buf_json_nstr(buf_t *b, str_t s);               // string or null

typedef struct achunk { struct achunk *next; } achunk_t;
typedef struct { char *cur, *end; achunk_t *chunks; } arena_t;
void *arena_alloc(arena_t *a, size_t n);
char *arena_strdup(arena_t *a, const char *s, size_t n); // NUL-terminated copy
void arena_free(arena_t *a);

bool parse_uint(const char *s, size_t n, int64_t *out); // ASCII digits only, fits int64
size_t fmt_i64(char *out, int64_t v);
str_t arena_i64(arena_t *a, int64_t v);

// ---------- crypto (util.c) ----------

typedef struct { uint32_t h[8]; uint64_t len; uint8_t buf[64]; size_t blen; } sha256_t;
void sha256_init(sha256_t *s);
void sha256_update(sha256_t *s, const void *p, size_t n);
void sha256_final(sha256_t *s, uint8_t out[32]);
typedef struct { sha256_t in, out; } hmac_key_t; // pads absorbed once; per-message work is two finals
void hmac_key_init(hmac_key_t *k, const void *key, size_t klen);
void hmac_sha256_k(const hmac_key_t *k, const void *msg, size_t n, uint8_t out[32]);
void hmac_sha256(const void *key, size_t klen, const void *msg, size_t n, uint8_t out[32]);

size_t b64url_enc(char *out, const uint8_t *in, size_t n);  // no padding
long b64url_dec(uint8_t *out, const char *in, size_t n);    // -1 on error (Go RawURLEncoding)
size_t b64_enc(char *out, const uint8_t *in, size_t n);     // standard, padded
long b64_dec(uint8_t *out, const char *in, size_t n);

// ---------- JSON (json.c) ----------

enum { J_NULL, J_FALSE, J_TRUE, J_NUM, J_STR, J_ARR, J_OBJ };
typedef struct jv {
    int type;
    str_t s;          // decoded string, or the raw number text
    str_t key;        // member key when inside an object
    struct jv *child; // first element / member
    struct jv *next;
} jv_t;
jv_t *json_parse(arena_t *a, const char *p, size_t n); // NULL when not valid JSON
jv_t *json_get(const jv_t *obj, const char *key);      // last member with that key (Go map semantics)

// ---------- configuration ----------

typedef struct {
    char *db_host, *db_port, *db_user, *db_pass, *db_name;
    char *host, *port;
    char *pg_session; // extra session settings sent at startup: name=value,name=value
    int threads, db_conns, bcrypt_threads, bcrypt_lanes, bcrypt_wait_ms, pg_depth;
    hmac_key_t jwt_key;
} config_t;
extern config_t CFG;

// ---------- Postgres (pg.c) ----------

typedef struct { const char *p; int32_t n; } pgf_t; // n < 0: NULL
typedef struct { int nrows, ncols; size_t cap; pgf_t *f; } pgst_t;
static inline pgf_t pg_get(const pgst_t *st, int row, int col) { return st->f[row * st->ncols + col]; }
static inline str_t pgs(pgf_t f) { return f.n < 0 ? STR_NULL : (str_t){f.p, (size_t)f.n}; }

struct req;
struct pgconn;
#define PG_MAXST 6
typedef struct pgbatch {
    struct pgbatch *next;
    struct req *req;
    void (*cb)(struct req *, struct pgbatch *);
    struct pgconn *conn; // NULL while the batch waits in the worker's queue
    buf_t *buf, own;     // where its messages are built: the connection's output, or `own` while queued
    int nst, cur;
    bool failed, is_write, behind_w; // is_write/behind_w/t_enq: STATS=1 only
    uint64_t t_enq;
    char sqlstate[6];
    pgst_t st[PG_MAXST];
} pgbatch_t;

typedef struct pgconn {
    int fd;
    struct worker *w;
    buf_t out, sending;
    size_t sent;
    bool send_inflight;
    buf_t in;
    pgbatch_t *head, *tail;
    int inflight;
    int pend_w; // STATS=1: write batches in the pipeline
    uint64_t lat_sum, lat_n; // STATS=1: batch latency this second
} pgconn_t;

typedef struct { const char *sql; int nparams; uint32_t oids[8]; } stmt_def_t;
extern const stmt_def_t STMTS[];
extern const int NSTMTS;

void pg_connect(pgconn_t *c, struct worker *w); // blocking: startup, auth, prepare every statement
pgbatch_t *pg_begin(struct req *r, void (*cb)(struct req *, pgbatch_t *));
void pg_stmt(pgbatch_t *b, int stmt, const str_t *params);
void pg_end(pgbatch_t *b);
void pg_flush(pgconn_t *c);
void pg_on_send(pgconn_t *c, int res);
void pg_on_recv(pgconn_t *c, int res);
void pg_arm_recv(pgconn_t *c);

// ---------- optional diagnostics (stats.c), STATS=1 ----------

extern bool STATS_ON;
typedef struct stats stats_t;
uint64_t stats_now(void); // microseconds, monotonic
void stats_init(struct worker *w);
void stats_req_done(struct worker *w, uint64_t t0);
void stats_pg_enq(pgconn_t *c, pgbatch_t *b);
void stats_pg_done(pgconn_t *c, pgbatch_t *b);
void stats_bc_done(struct worker *w, uint64_t t0);
void stats_loop(struct worker *w, uint64_t t0, unsigned n);
void stats_conn(struct worker *w, int d);
bool stmt_is_write(int stmt);

// ---------- event loop (server.c) ----------

enum { UD_ACCEPT = 1, UD_RECV, UD_SEND, UD_PGRECV, UD_PGSEND, UD_EVENT };
#define UD(ptr, kind) ((uint64_t)(uintptr_t)(ptr) | (kind))

typedef struct job {
    struct job *next;
    struct req *r;
    bool hash; // true: hash pw; false: verify pw against setting
    const char *pw, *setting;
    char out[128];
    bool ok;
    uint64_t t0; // STATS=1: submit time
    void (*cb)(struct req *, struct job *);
} job_t;

typedef struct worker {
    int id;
    struct io_uring ring;
    int lfd;
    char *rbuf; // receive scratch: data is copied out at once, so idle connections own no buffer
    pgconn_t *pg;
    int npg;
    pgbatch_t *wq_head, *wq_tail; // batches waiting for a pipeline slot, oldest first
    int wq_n;
    int efd;
    uint64_t efd_val;
    pthread_mutex_t mu;
    job_t *done;
    buf_t body; // scratch for building a response body
    struct stats *stats; // STATS=1 only
    pthread_t th;
} worker_t;

typedef struct conn {
    worker_t *w;
    int fd;
    bool recv_armed, send_inflight, closing, peer_closed, processing;
    buf_t in, out, sending;
    size_t out_off;
    struct req *req;
} conn_t;

enum { M_GET, M_POST, M_PUT, M_DELETE, M_OTHER };

typedef struct req {
    conn_t *c;
    worker_t *w;
    arena_t arena;
    int method;
    bool keepalive;
    str_t path, query, auth, body;
    str_t seg[6];
    int nseg;
    int64_t viewer;
    str_t token;
    // handler scratch
    int kind;
    uint64_t t0; // STATS=1: arrival time
    int64_t limit, offset, id;
    str_t s[8];
    void *ctx;
    job_t job;
} req_t;

struct io_uring_sqe *get_sqe(worker_t *w);
void submit_job(job_t *j);
void reply(req_t *r, int status, const buf_t *body); // body NULL: empty (204)
void reply_err(req_t *r, int status, const char *msg);

// ---------- bcrypt (bcrypt.c) ----------

#define BC_LANES 4
bool bc_gensalt(char setting[30]);
int bc_cost(const char *setting); // -1 if not a $2a$/$2b$/$2y$ setting this implementation handles
void bc_hash_n(int n, const char *const *pw, const char *const *setting, char (*out)[64]);

// ---------- API (api.c) ----------

void api_dispatch(req_t *r);
bool jwt_verify(arena_t *a, const char *tok, size_t n, int64_t *sub);
size_t jwt_issue(char *out, int64_t id);

#endif
