// MIT License — fork of c-iouring-tigokraft (#10); ideas from c-iouring-gilnett (#58), rust-tokio-Scooter1337 (#7), csharp-sockets-jh-d (#22).
// rw: Original MIT code (c) challenge contributors; modifications (c) frobinson. See README Credits.

// rw: Conduit API server: C + io_uring, hand-written Postgres wire client, bcrypt (forked, substantially rewritten).

#ifndef APP_H
#define APP_H
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

// rw: ---------- strings, buffers, arenas (util.c) ----------


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

typedef struct achunk { struct achunk *next; size_t size; } achunk_t;
typedef struct { char *cur, *end; achunk_t *chunks; } arena_t;
void *arena_alloc(arena_t *a, size_t n);
char *arena_strdup(arena_t *a, const char *s, size_t n); // NUL-terminated copy
void arena_free(arena_t *a);

bool parse_uint(const char *s, size_t n, int64_t *out); // ASCII digits only, fits int64
size_t fmt_i64(char *out, int64_t v);
str_t arena_i64(arena_t *a, int64_t v);

// rw: ---------- crypto (util.c) ----------


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

// rw: ---------- JSON (json.c) ----------


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

// rw: ---------- configuration ----------


typedef struct {
    char *db_host, *db_port, *db_user, *db_pass, *db_name;
    char *host, *port;
    char *pg_session; // extra session settings sent at startup: name=value,name=value
    int threads, db_conns, db_read_conns, db_write_conns, bcrypt_threads, bcrypt_lanes, bcrypt_wait_ms, pg_depth;
    // rw: split pools: reads vs writes (own rewrite, ideas from #58/#7). Zero R-behind-W HOL.

    hmac_key_t jwt_key;
} config_t;
extern config_t CFG;

// rw: ---------- Postgres (pg.c) ----------


typedef struct { const char *p; int32_t n; } pgf_t; // n < 0: NULL
typedef struct { int nrows, ncols; size_t cap; pgf_t *f; } pgst_t;
static inline pgf_t pg_get(const pgst_t *st, int row, int col) { return st->f[row * st->ncols + col]; }
static inline str_t pgs(pgf_t f) { return f.n < 0 ? STR_NULL : (str_t){f.p, (size_t)f.n}; }

struct http_req;
struct pg_conn;
#define PG_MAXST 6
typedef struct pg_batch {
    struct pg_batch *next;
    struct http_req *req;
    void (*cb)(struct http_req *, struct pg_batch *);
    struct pg_conn *conn; // NULL while the batch waits in the worker's queue
    buf_t *buf, own;     // where its messages are built: the connection's output, or `own` while queued
    int nst, cur;
    bool failed, is_write, behind_w; // is_write/behind_w/t_enq: STATS=1 only
    uint64_t t_enq;
    char sqlstate[6];
    pgst_t st[PG_MAXST];
} pg_batch;

typedef struct pg_conn {
    int fd;
    struct ev_loop *ev;
    buf_t out, sending;
    size_t sent;
    bool send_inflight;
    buf_t in;
    pg_batch *head, *tail;
    int inflight;
    int pend_w; // STATS=1: write batches in the pipeline
    uint64_t lat_sum, lat_n; // STATS=1: batch latency this second
} pg_conn;

typedef struct { const char *sql; int nparams; uint32_t oids[8]; } stmt_def_t;
extern const stmt_def_t STMTS[];
extern const int NSTMTS;

void pg_conn_open(pg_conn *pc, struct ev_loop *ev); // blocking: startup, auth, prepare every statement
pg_batch *pg_batch_begin(struct http_req *rq, void (*cb)(struct http_req *, pg_batch *));
void pg_batch_add(pg_batch *batch, int stmt, const str_t *params);
void pg_batch_seal(pg_batch *batch);
void pg_conn_flush(pg_conn *pc);
void pg_conn_on_writable(pg_conn *pc, int res);
void pg_conn_on_readable(pg_conn *pc, int res);
void pg_conn_arm_read(pg_conn *pc);

// rw: ---------- optional diagnostics (stats.c), STATS=1 ----------


extern bool STATS_ON;
typedef struct stats stats_t;
uint64_t tm_now(void); // microseconds, monotonic
void tm_init(struct ev_loop *ev);
void tm_req_done(struct ev_loop *ev, uint64_t t0);
void tm_pg_enq(pg_conn *pc, pg_batch *batch);
void tm_pg_done(pg_conn *pc, pg_batch *batch);
void tm_bcrypt_done(struct ev_loop *ev, uint64_t t0);
void tm_tick(struct ev_loop *ev, uint64_t t0, unsigned n);
void tm_conn_track(struct ev_loop *ev, int d);
bool stmt_is_write(int stmt);

// rw: ---------- event loop (server.c) ----------


enum { UD_ACCEPT = 1, UD_RECV, UD_SEND, UD_PGRECV, UD_PGSEND, UD_EVENT, UD_ACCEPT_WAIT };
#define UD(ptr, kind) ((uint64_t)(uintptr_t)(ptr) | (kind))

typedef struct job {
    struct job *next;
    struct http_req *rq;
    bool hash; // true: hash pw; false: verify pw against setting
    const char *pw, *setting;
    char out[128];
    bool ok;
    uint64_t t0; // STATS=1: submit time
    void (*cb)(struct http_req *, struct job *);
} job_t;

typedef struct ev_loop {
    int id;
    int pin_cpu; // -1: no affinity pinning
    struct io_uring ring;
    int lfd;
    char *rbuf; // receive scratch: data is copied out at once, so idle connections own no buffer
    pg_conn *pg; // legacy combined (kept for stats compat)
    int npg;
    pg_conn *pg_read; // read pool: least-inflight routing, no WAL stall
    int nread;
    pg_conn *pg_write; // write pool: coalesced flush, group-commit ready
    int nwrite;
    // rw: Hot: completion delivery (bcrypt -> loop). Own 64B line: mutex + queue head.

    pthread_mutex_t mu __attribute__((aligned(64)));
    job_t *done;
    // rw: Hot: eventfd read target (written by the kernel). Own 64B line.

    uint64_t efd_val __attribute__((aligned(64)));
    // rw: Hot: Postgres pipeline queue. One 64B line: head/tail/count.

    pg_batch *wq_head __attribute__((aligned(64)));
    pg_batch *wq_tail;
    int wq_n;
    // rw: Stable after init.

    int efd;
    struct __kernel_timespec accept_retry_ts; // stable storage for the accept-backoff timeout SQE
    uint64_t accept_err_last_log;             // monotonic ms of the last accept-exhaustion log
    // rw: Cold: response scratch (capacity retained across requests) and stats.

    buf_t body;
    struct stats *stats; // STATS=1 only
    // rw: Cold: arena chunk cache (bounded high-water reuse, RSS-capped).

    achunk_t *spare;
    size_t spare_bytes;
    pthread_t th;
} ev_loop;

typedef struct http_conn {
    ev_loop *ev;
    int fd;
    bool recv_armed, send_inflight, closing, peer_closed, processing;
    buf_t in, out, sending;
    size_t out_off;
    struct http_req *req;
} http_conn;

enum { M_GET, M_POST, M_PUT, M_DELETE, M_OTHER };

typedef struct http_req {
    http_conn *pc;
    ev_loop *ev;
    arena_t arena;
    int method;
    bool keepalive;
    str_t path, query, auth, body;
    str_t seg[6];
    int nseg;
    int64_t viewer;
    str_t token;
    // rw: handler scratch

    int kind;
    uint64_t t0; // STATS=1: arrival time
    int64_t limit, offset, id;
    str_t s[8];
    void *ctx;
    job_t job;
} http_req;

struct io_uring_sqe *ev_next_sqe(ev_loop *ev);
void submit_job(job_t *j);
void http_reply(http_req *rq, int status, const buf_t *body); // body NULL: empty (204)
void http_reply_err(http_req *rq, int status, const char *msg);

// rw: Per-worker arena high-water reuse (util.c): freed chunks are retained on the

// rw: worker up to ARENA_SPARE_CAP instead of freed, and the next request reseeds

// rw: from that cache. Bounds RSS while avoiding malloc/free per request.

#define ARENA_SPARE_CAP (64 * 1024)
void arena_seed(struct ev_loop *ev, arena_t *a);
void arena_recycle(struct ev_loop *ev, arena_t *a);

// rw: ---------- bcrypt (bcrypt.c) ----------


#define BC_LANES 4
bool bc_gensalt(char setting[30]);
int bc_cost(const char *setting); // -1 if not a $2a$/$2b$/$2y$ setting this implementation handles
void bc_hash_n(int n, const char *const *pw, const char *const *setting, char (*out)[64]);

// rw: ---------- API (api.c) ----------


void route_request(http_req *rq);
bool jwt_verify(arena_t *a, const char *tok, size_t n, int64_t *sub);
size_t jwt_issue(char *out, int64_t id);

#endif
