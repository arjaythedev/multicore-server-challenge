#ifndef CONDUIT_H
#define CONDUIT_H

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <liburing.h>
#include <pthread.h>
#include <stdalign.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct worker worker_t;
typedef struct req req_t;
typedef struct pgconn pgconn_t;
typedef struct pgbatch pgbatch_t;
typedef struct job job_t;

static inline void die(const char *m) {
    perror(m);
    exit(1);
}

// ---------- slices, buffers, per-request bump arena ----------

typedef struct {
    const char *p;
    size_t n; // SIZE_MAX means SQL NULL
} str_t;

#define STR_NULL ((str_t){NULL, SIZE_MAX})
#define S(lit) ((str_t){"" lit, sizeof(lit) - 1})

static inline bool str_eq_fn(str_t a, const char *s) {
    size_t n = strlen(s);
    return a.n == n && memcmp(a.p, s, n) == 0;
}

#define str_eq(a, lit) \
    (__builtin_constant_p(lit) \
        ? ((a).n == (sizeof(lit) - 1) && memcmp((a).p, "" lit, sizeof(lit) - 1) == 0) \
        : str_eq_fn((a), (lit)))

typedef struct {
    char *p;
    size_t len, cap;
} buf_t;

void buf_grow(buf_t *b, size_t add);
void buf_free(buf_t *b);

static inline void buf_reserve(buf_t *b, size_t add) {
    if (__builtin_expect(b->len + add > b->cap, 0)) buf_grow(b, add);
}
static inline void buf_put(buf_t *b, const void *s, size_t n) {
    buf_reserve(b, n);
    memcpy(b->p + b->len, s, n);
    b->len += n;
}
static inline void buf_putc(buf_t *b, char c) {
    buf_reserve(b, 1);
    b->p[b->len++] = c;
}
#define buf_lit(b, lit) buf_put((b), "" lit, sizeof(lit) - 1)

void buf_i64(buf_t *b, int64_t v);
void buf_json_str(buf_t *b, const char *s, size_t n);

typedef struct arena_blk {
    struct arena_blk *next;
    size_t used, cap;
    char data[];
} arena_blk_t;

typedef struct {
    char inline_buf[3072];
    size_t used;
    arena_blk_t *head;
} arena_t;

void *arena_alloc(arena_t *a, size_t n);
char *arena_strdup(arena_t *a, const char *s, size_t n);
str_t arena_i64(arena_t *a, int64_t v);
void arena_reset(arena_t *a);

// ---------- JSON (strict RFC 8259) ----------

enum { J_NULL, J_BOOL, J_NUM, J_STR, J_ARR, J_OBJ };

typedef struct jv {
    uint8_t type;
    bool b;
    double num;
    str_t s, raw, key;
    struct jv *next, *child;
} jv_t;

jv_t *json_parse(arena_t *a, const char *src, size_t len);
jv_t *json_get(const jv_t *obj, const char *key);

// ---------- crypto / util ----------

typedef struct {
    uint32_t h[8];
    uint64_t bits;
    uint8_t buf[64];
    size_t n;
} sha256_t;

typedef struct {
    sha256_t in, out;
} hmac_key_t;

void sha256_init(sha256_t *s);
void sha256_update(sha256_t *s, const void *data, size_t len);
void sha256_final(sha256_t *s, uint8_t out[32]);
void hmac_key_init(hmac_key_t *k, const void *key, size_t klen);
void hmac_sha256_k(const hmac_key_t *k, const void *msg, size_t n, uint8_t out[32]);
void hmac_sha256(const void *key, size_t klen, const void *msg, size_t n, uint8_t out[32]);

size_t b64_enc(char *out, const uint8_t *in, size_t n);
long b64_dec(uint8_t *out, const char *in, size_t n);

int count_cpus(void);
void jwt_init(const char *secret);
size_t jwt_issue(char *out, int64_t user_id);
bool jwt_verify(arena_t *a, const char *tok, size_t len, int64_t *user_id);

bool parse_i64(const char *s, size_t n, int64_t *out);
bool parse_uint(const char *s, size_t n, int64_t *out);
int url_decode(char *dst, const char *src, size_t n);

// ---------- bcrypt worker pool ----------

struct job {
    job_t *next, *done_next;
    req_t *r;
    bool hash, ok;
    const char *pw, *setting;
    char out[64];
    void (*cb)(req_t *r, job_t *j);
    uint64_t t_enq;
};

void bcrypt_pool_init(int nthreads);
int bcrypt_selftest(void);
void submit_job(job_t *j);

// ---------- PostgreSQL wire v3 client ----------

typedef struct {
    const char *name, *sql;
    int nparams;
} stmt_def_t;

extern const stmt_def_t STMTS[];
extern const int N_STMTS;

typedef struct {
    const char *p;
    int32_t n; // -1 for SQL NULL
} pgf_t;

typedef struct {
    int ncols, nrows, cap;
    pgf_t *f; // nrows * ncols, pointers into pgbatch_t.arena
} pgst_t;

typedef void (*pg_cb)(req_t *r, pgbatch_t *b);

struct pgbatch {
    pgbatch_t *next;
    req_t *r;
    pg_cb cb;
    buf_t wire;
    arena_t arena;
    pgst_t st[16];
    int nst, cur;
    bool failed, is_write, behind_w;
    char sqlstate[6], errmsg[128];
    uint64_t t_enq;
};

static inline pgf_t pg_get(const pgst_t *s, int row, int col) { return s->f[(size_t)row * (size_t)s->ncols + (size_t)col]; }

struct pgconn {
    worker_t *w;
    int fd, id;
    bool is_write_conn;
    bool sending, recv_armed, ready;
    buf_t in, out;
    size_t in_rp, out_sp;
    pgbatch_t *head, *tail;
    int inflight, pend_w;
    uint64_t lat_sum, lat_n;
};

void pg_parse_url(const char *url);
void pg_worker_init(worker_t *w, int npg_r, int npg_w);
pgbatch_t *pg_begin_ex(worker_t *w, req_t *r, pg_cb cb, bool is_write);
void pg_stmt(pgbatch_t *b, int stmt, const str_t *params);
void pg_end(pgbatch_t *b);
void pg_end_on(pgconn_t *c, pgbatch_t *b);
pgconn_t *pg_pick_idle_read(worker_t *w);
void pg_send_done(pgconn_t *c, int res);
void pg_readable(pgconn_t *c, int res);

// ---------- HTTP / io_uring worker ----------

enum { M_GET, M_POST, M_PUT, M_DELETE, M_OTHER };

// Read coalescing queue kinds (11 read endpoints in SPEC.md)
enum {
    RQ_TAGS = 0,
    RQ_LIST_ALL,
    RQ_LIST_TAG,
    RQ_LIST_AUTHOR,
    RQ_LIST_FAV,
    RQ_FEED,
    RQ_ARTICLE,
    RQ_COMMENTS,
    RQ_PROFILE,
    RQ_USER,
    RQ_LOGIN,
    RQ_COUNT
};

struct req {
    worker_t *w;
    int fd;
    bool keep_alive, busy, closing, poll_armed;
    buf_t in; // non-empty only when partial HTTP bytes span reads
    char hdr_Out[256];
    buf_t out;
    size_t out_sp;

    int method;
    str_t path, query, auth, body, token;
    int64_t viewer, limit, offset;
    int nseg;
    str_t seg[5];

    arena_t arena;
    int kind;
    str_t s[6];
    void *ctx;
    job_t job;
    req_t *rq_next;
    uint64_t t_start;
};

typedef struct stats stats_t;

struct worker {
    alignas(64) int id;
    int lfd, evfd;
    struct io_uring ring;
    pgconn_t *pg;
    int npg, npg_r, npg_w;
    // Write overflow queue
    pgbatch_t *wq_head, *wq_tail;
    int wq_n;
    // Read coalescing queues (1 per read endpoint family)
    req_t *rq_head[RQ_COUNT];
    req_t *rq_tail[RQ_COUNT];
    int rq_len[RQ_COUNT];
    int rq_rr;

    alignas(64) pthread_mutex_t done_mu;
    job_t *done_head;
    req_t *free_req;
    pgbatch_t *free_batch;
    buf_t body; // scratch response-body buffer reused across every reply on this thread
    buf_t scratch[4]; // scratch buffers for coalesced array parameter formatting
    char *rx_scratch;
    stats_t *stats;
};

// Optional STATS=1 instrumentation
extern bool STATS_ON;
uint64_t stats_now(void);
void stats_init(worker_t *w);
void stats_conn(worker_t *w, int d);
void stats_req_done(worker_t *w, uint64_t t0);
void stats_pg_enq(pgconn_t *c, pgbatch_t *b);
void stats_pg_done(pgconn_t *c, pgbatch_t *b);
void stats_bc_done(worker_t *w, uint64_t t0);
void stats_loop(worker_t *w, uint64_t t0, unsigned n);
bool stmt_is_write(int stmt);

void api_dispatch(req_t *r);
void api_flush_coalesced(worker_t *w);
void reply(req_t *r, int status, const buf_t *body);
void reply_err(req_t *r, int status, const char *msg);

#endif
