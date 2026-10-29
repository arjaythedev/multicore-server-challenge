/* One worker process: an io_uring event loop that owns its listener, its client connections, its Postgres
 * connections and its bcrypt threads. Nothing is shared with other workers. */
#pragma once
#include <liburing.h>

#include "arena.h"
#include "bcrypt.h"
#include "buf.h"
#include "http.h"
#include "jwt.h"
#include "pg_wire.h"
#include "sql.h"

/* Operation tag in the low 3 bits of a CQE's user_data; the rest is a pointer (8-byte aligned) or, for client
 * receives, the connection's fd and generation. */
/* OP_QUIET: like OP_IGNORE, but a failure is expected too (shutting down a socket the client already reset). */
enum op { OP_ACCEPT, OP_RECV, OP_SEND, OP_PG_RECV, OP_PG_SEND, OP_EVENTFD, OP_IGNORE, OP_QUIET };
#define UD_OP(ud) ((unsigned)((ud) & 7))
#define UD_PTR(ud) ((void *)(uintptr_t)((ud) & ~(uint64_t)7))
#define UD_MAKE_PTR(p, op) ((uint64_t)(uintptr_t)(p) | (op))
#define UD_MAKE_CONN(fd, gen, op) (((uint64_t)(gen) << 35) | ((uint64_t)(uint32_t)(fd) << 3) | (op))
#define UD_FD(ud) ((int)(((ud) >> 3) & 0xffffffff))
#define UD_GEN(ud) ((uint32_t)((ud) >> 35))
#define GEN_MASK 0x1fffffff

struct worker;
struct req;

/* What a handler is told about. EV_ROW carries a DataRow of the current statement (req->stmt); EV_READY means the
 * unit finished (ReadyForQuery: committed, unless req->pg_error); EV_HASHED means the bcrypt job finished. */
enum ev { EV_ROW, EV_READY, EV_HASHED };
typedef void (*handler_fn)(struct req *r, int ev, const struct pg_msg *m);

/* A client connection, indexed by its fd. Idle connections own no buffers. */
struct hconn {
    uint32_t gen;
    bool open, recv_armed, busy, want_recv;
    uint32_t plen, pcap;
    char *pend;            /* bytes received but not yet parsed (partial or pipelined requests) */
};

enum { BC_VERIFY = 1, BC_HASH };

struct bc_job {
    uint8_t kind;
    bool ok;
    bool stale;            /* waited too long: answered 503, not hashed */
    uint8_t pwlen;
    int64_t t_us;          /* when it was queued (CLOCK_MONOTONIC) */
    char pw[BCRYPT_MAX_PW];
    char hash[BCRYPT_LEN + 1];  /* VERIFY: the stored hash; HASH: the result */
};

/* One request in flight. Everything it needs after the synchronous dispatch is copied in. */
struct req {
    struct worker *w;
    struct req *next;      /* Postgres FIFO, wait queue, bcrypt queue or free list */
    handler_fn fn;
    int fd;
    uint32_t gen;
    bool keep_alive, pg_error, write;
    bool solo;             /* a write that may fail on its own (unique names): never grouped with others */
    uint8_t ipc_kind;      /* reads: what q holds for the drain (IPC_PG unit or IPC_PLAN request) */
    uint8_t step;
    uint16_t stmt;         /* statement index within the running unit */
    uint16_t nexec;        /* statements (Executes) in the unit */
    char sqlstate[6];
    int64_t viewer;
    int64_t n[4];          /* handler scratch */
    uint32_t rows;         /* rows seen by the handler */
    char *data;            /* owned copies of request strings */
    uint32_t data_len, data_cap;
    const char *s[6];      /* handler strings (pointing into data or NULL) */
    uint32_t sl[6];
    char *saved;           /* a DataRow body kept for later (login) */
    uint32_t saved_len;
    struct buf q;          /* the unit being built: Bind/Execute pairs, then Sync */
    struct buf resp;       /* the response; body starts at HDR_GAP */
    size_t resp_off, resp_sent;
    size_t resp_mark;      /* response length when the unit was submitted (a retried write rewinds to it) */
    struct bc_job bc;
};

struct pgc {
    struct worker *w;
    int fd;
    bool write, send_busy, dirty;
    struct buf out, sending;
    size_t sent;
    struct buf in;
    struct req *head, *tail;  /* units in flight, in order */
    uint32_t inflight;
    struct req *cur;          /* write connections: the unit of the running group receiving messages */
    bool group_failed;
    struct pgc *next_dirty;
};

struct bcrypt_pool;

struct worker {
    int id;
    struct io_uring ring;
    int listen_fd;
    struct hconn *conns;
    uint32_t nconns;
    bool direct;           /* client sockets are io_uring direct descriptors: "fd" is a slot in the ring's table */
    char *bufs;            /* provided receive buffers */
    uint32_t nbufs, bufsz;
    int *norecv;           /* connections whose receive stopped for lack of buffers */
    uint32_t norecv_len;
    struct pgc *pg;        /* write connections (reads go through the drain process) */
    int npg, nread;
    unsigned rr;
    struct pgc *dirty;
    struct req *wait_read, *wait_read_tail;
    struct req *wait_write, *wait_write_tail;  /* writes waiting for the next group */
    struct req *free_reqs;
    struct arena scratch;
    int efd;
    uint64_t efd_val;
    struct bcrypt_pool *bp;
    double now;            /* wall clock (Unix seconds) at the start of this batch of completions */
    bool wake_drain;       /* reads were queued for the drain in this iteration */
};

/* worker.c */
struct req *req_alloc(struct worker *w, int fd, uint32_t gen);
struct io_uring_sqe *sqe_get(struct worker *w);
void unit_submit(struct req *r, bool write);
void plan_submit(struct req *r, int kind, int filter, int64_t limit, int64_t offset, const char *key, uint32_t keylen);
void req_respond(struct req *r, int status);
void req_error(struct req *r, int status, const char *msg);
void bcrypt_submit(struct req *r);

/* handlers.c: routes a parsed request; returns with the request either answered or in flight. */
void dispatch(struct worker *w, int fd, uint32_t gen, const struct http_req *hr);

/* bcrypt_pool.c */
struct bcrypt_pool *bcrypt_pool_start(struct worker *w, int threads);
void bcrypt_pool_push(struct bcrypt_pool *bp, struct req *r);
struct req *bcrypt_pool_take_done(struct bcrypt_pool *bp);

/* Configuration from the environment, shared by all workers. */
struct config {
    struct pg_url pg;
    const char *host, *port;
    int workers, read_conns, write_conns, bcrypt_threads;
    int bcrypt_wait_ms;
    int bcrypt_batch;      /* most jobs per kernel run (1: one hash at a time) */    /* how long a lone hash job waits for others to share its kernel run */
    int bcrypt_nice;  /* read_conns: the drain's, for the box */
    uint32_t pg_pipeline;  /* units in flight per Postgres read connection */
    uint32_t write_group;  /* most writes committed by one Sync */
    uint32_t plan_max;     /* most planned reads in one plan */
    int64_t plan_wait_us;  /* how long the oldest planned read may wait for company */
    bool planner;          /* hot reads go to the planner (else as plain units) */
    bool plan_pace;        /* plan wait follows the load (drain.c plan_wait); plan_wait_us becomes its cap */
    bool direct_fds;       /* accept client sockets as io_uring direct descriptors (off: no measured gain on loopback) */
};
extern struct config cfg;

void worker_run(int id);
