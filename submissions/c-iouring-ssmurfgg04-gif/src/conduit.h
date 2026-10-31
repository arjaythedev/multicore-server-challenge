/* conduit.h - shared types and cross-module API for the C io_uring server */
#pragma once
#include <liburing.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "bcrypt.h"
#include "util.h"

/* ---------------------------------------------------------------- config */

typedef struct {
    int threads;            /* event loops (SO_REUSEPORT workers) */
    int db_reads, db_writes;/* PG connections per worker */
    int pg_depth;           /* max in-flight batches per PG connection */
    int bcrypt_threads, bcrypt_lanes, bcrypt_wait_ms;
    const char *listen_host, *listen_port;
    const char *db_host, *db_port, *db_user, *db_pass, *db_name;
    const char *jwt_secret;
} cfg_t;

extern cfg_t cfg;

/* limits and sizes */
#define RING_ENTRIES 4096
#define CQ_ENTRIES 32768
#define SCRATCH_SZ 65536        /* per-worker recv drain buffer */
#define MAX_HEADER 16384
#define MAX_BODY (1 << 20)
#define MAX_OUT_HIGH 65536      /* stop reading with this much unsent */
#define STALL_MS 30000
#define IDLE_MS 120000          /* keep-alive idle close (nginx upstream: 60s) */
#define PG_DEPTH_MAX 64
#define PG_MAX_STMTS 8          /* statements per batch */
#define PG_MAX_PARAMS 8
#define PG_TOTAL_CONN_LIMIT 95
#define NSEG 6                  /* path segments /api/a/b/c -> up to 6 */

/* ---------------------------------------------------------------- worker */

struct pgconn;
typedef struct req req_t;

typedef struct worker {
    int idx;
    int evfd;                   /* bcrypt + pg completions kick this */
    pthread_mutex_t mu;
    bcrypt_job_t *done;         /* finished jobs awaiting the loop */

    struct io_uring ring;
    int have_ring;              /* 0 when the epoll fallback is in use */
    int listen_fd;
    int epfd;                   /* epoll fallback */
    bool use_iouring;

    struct pgconn *pgs;
    int npgs;

    /* overflow FIFO when every PG connection is at depth */
    req_t *fifo_head, *fifo_tail;

    buf_t scratch;              /* shared recv drain buffer */

    int accept_broken;          /* multishot accept rejected: single-shot mode */

    /* connection registry (doubly linked, for stall/idle scans) */
    struct conn *c_head, *c_tail;
    int nconns;
    int next_slot;              /* slot allocator cursor */
    int tickfd;                 /* 1s periodic tick */
    uint64_t now_ms;            /* cached per loop turn */
} worker_t;

/* ---------------------------------------------------------------- conn */

typedef struct conn {
    int fd;
    worker_t *w;
    buf_t in, out;              /* out: encoded responses awaiting send */
    size_t out_off;             /* send progress within out */
    int sending;                /* a send is in flight over out */
    int closing;                /* close once out drains */
    int keep;                   /* keep-alive */
    int nreqs;                  /* in-flight requests (backpressure) */
    uint64_t last_ms;
    struct conn *prev, *next;
    /* epoll fallback state */
    int want_out;               /* EPOLLOUT armed */
    int slot, gen;              /* slot-table identity (user_data) */
    int closed_ring;            /* poll-remove already issued */
} conn_t;

/* ---------------------------------------------------------------- request */

typedef struct {
    const char *p;
    uint32_t n;
} span_t;

/* one result row's cell: view into the request arena */
typedef struct {
    const char *p;
    uint32_t n;                 /* (uint32_t)-1 = NULL */
} pgval_t;

typedef struct {
    pgval_t *vals;              /* nrows * ncols */
    uint32_t nrows, ncols, capacity;
} pgres_t;

/* one prepared statement of a batch: id + text params (req-arena copies) */
typedef struct {
    int stmt;
    int nparams;
    const char *params[PG_MAX_PARAMS];
} batch_stmt_t;

typedef struct req {
    worker_t *w;
    conn_t *c;                  /* NULL once the connection closed */

    /* handler scratch (all arena- or req-lifetime) */
    const char *reg_username, *reg_email;       /* register */
    const char *login_pw;                       /* login */
    pgval_t *login_row;                         /* login: the user row */
    const char *upd_email, *upd_username, *upd_bio, *upd_image; /* PUT /api/user */
    const char *art_title, *art_desc, *art_body;/* article create/update */
    int full_idx;                               /* which result holds the article */
    int pending;                                /* handed to PG or bcrypt: not stuck */
    uint8_t tag_json[4096];                    /* serialized text[] param */
    int upd_password_flag;                      /* PUT user: a new password was set */
    int released;                               /* req_release already ran */

    /* request line + routing targets (views into arena) */
    int method;                 /* M_GET / M_POST / M_PUT / M_DELETE */
#define M_GET 1
#define M_POST 2
#define M_PUT 3
#define M_DELETE 4
    span_t seg[NSEG];
    int nseg;
    span_t query;               /* raw query string */
    span_t body;
    int64_t viewer;             /* authenticated user id, 0 anonymous */
    int has_token;              /* a Token header was presented */
    int auth_bad;               /* presented but invalid -> 401 */
    span_t auth_token;          /* the presented token (echoed by /api/user) */

    /* response */
    buf_t resp;                 /* body being built */
    int status;
    short conn_close;           /* respond Connection: close */
    short replied;

    /* arena: request copies, params, and PG result cells */
    struct arena_chunk *arena;

    /* pg batch */
    struct pgconn *pg;
    batch_stmt_t stmts[PG_MAX_STMTS];
    int nstmts;                 /* statements sent */
    int cur;                    /* statement now receiving rows */
    pgres_t res[PG_MAX_STMTS];
    int failed;
    char sqlstate[6];
    void (*cb)(req_t *);        /* continuation when the batch completes */
    struct req *q_next;         /* pgconn queue link */
    struct req *fifo_next;
    uint64_t birth_ms;
} req_t;

/* arena */
void *arena_alloc(req_t *r, size_t n);
void arena_drain(req_t *r);
void req_release(req_t *r);   /* arena + resp freed, struct back to freelist */

/* ---------------------------------------------------------------- server */

#define TRACE(...) do { if (g_trace) fprintf(stderr, __VA_ARGS__); } while (0)
extern int g_trace;

int srv_init(void);
void srv_run(void);
int srv_parse_db_url(const char *url);

/* connection plumbing (server.c) */
void srv_reply(req_t *r, int status, const char *body, size_t blen);
void srv_reply_close(req_t *r, int status, const char *body, size_t blen);
void srv_conn_close(conn_t *c);
void srv_send(conn_t *c);
void conn_process(conn_t *c);
req_t *req_new(worker_t *w);

/* routing (api.c) */
void route(req_t *r);

/* ---------------------------------------------------------------- pg */

/* Queue a batch on the least-loaded connection (or the worker FIFO).
 * The handler has already added its statements with pg_add(). */
void pg_go(req_t *r);
/* Add one prepared statement to the batch. nparams params, all text
 * (a NULL param is passed as (const char *)0). */
void pg_add(req_t *r, int stmt, int nparams, const char *const *params);

/* results of statement i of the batch (valid inside the callback) */
static inline pgres_t *pg_result(req_t *r, int i) { return &r->res[i]; }

/* per-worker PG plumbing, called from the event loop */
void pg_fill(worker_t *w);
void pg_on_readable(struct pgconn *pc);
void pg_on_writable(struct pgconn *pc);
void pg_arm(struct pgconn *pc);
void pg_advance_pgconn(struct pgconn *pc);

/* statement ids */
enum {
    ST_TAGS,
    ST_USER_INS,
    ST_USER_BY_EMAIL,
    ST_USER_BY_ID,
    ST_USER_UPD,
    ST_PROFILE,
    ST_FOLLOW,
    ST_UNFOLLOW,
    ST_LIST,
    ST_LIST_COUNT,
    ST_LIST_TAG,
    ST_LIST_TAG_COUNT,
    ST_LIST_AUTHOR,
    ST_LIST_AUTHOR_COUNT,
    ST_LIST_FAV,
    ST_LIST_FAV_COUNT,
    ST_FEED,
    ST_FEED_COUNT,
    ST_ART_FULL_SLUG,
    ST_ART_FULL_ID,
    ST_ART_LAST,
    ST_ART_SEL,                 /* id, author_id by slug */
    ST_ART_UPD,
    ST_ART_DEL,
    ST_ART_INS,
    ST_TAGS_INS,
    ST_ARTTAGS_INS,
    ST_FAV_INS,
    ST_FAV_DEL,
    ST_COMMENTS,
    ST_COMMENT_INS,
    ST_COMMENT_DEL,
    ST_COUNT
};

/* api.c response helpers shared with server.c PGO trainer */
char *emit_ts(char *o, const char *src, size_t n);
char *emit_str(char *o, const char *s, size_t n);
char *emit_text_array(char *o, const char *s, size_t n);
