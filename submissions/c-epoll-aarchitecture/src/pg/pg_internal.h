#ifndef PG_INTERNAL_H
#define PG_INTERNAL_H

#include <libpq-fe.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>

#include "config.h"
#include "core/loop.h"
#include "pg/pg.h"

/* one queued write or read. write: params is an owned array of borrowed strings
 * (caller's arena/json tree). read: key borrowed the same way, rest copied at
 * submit. A read may be taken by any worker's connection, so home remembers the
 * submitting pool: its answer resumes on that pool's event loop */
typedef struct pg_pending {
    pg_pool *home;              // submitting pool: runs the callback
    bool solo;                  // don't join a write group
    pg_stmt stmt;
    int nparams;
    const char **params;
    void *ctx;
    pg_cb cb;
    uint64_t seq;               // read arrival order, all kinds, all workers
    long long viewer;
    int limit;
    long long offset;
    const char *key;
    unsigned char list_kind;    // PG_LIST_* branch of the merged list statement
    struct pg_pending *next;
} pg_pending;

typedef struct pg_read_queue {
    pg_pending *head;
    pg_pending *tail;
    int count;
} pg_read_queue;

/* stack-built around a PGresult, for one callback */
struct pg_result {
    PGresult *raw;
    int first_row;
    int rows;
    int col_offset;
};

/* one read batch's result, shared across workers: the taking pool holds one
 * reference and every remote answer takes one; the last release clears it.
 * PGresult reads and clears are thread-safe; each PGconn is only ever touched
 * by its own pool's thread */
typedef struct pg_batch_hold {
    PGresult *raw;
    int refs;
} pg_batch_hold;

/* an answer parked from another worker's read connection, drained by the home
 * pool's resume eventfd. viewp is NULL for a PG_ERROR with no result */
typedef struct pg_remote_item {
    struct pg_remote_item *next;
    pg_pending *p;
    pg_status status;
    const pg_result *viewp;     // points into view when rows exist
    pg_result view;
    pg_batch_hold *hold;
} pg_remote_item;

/* groups inbox items or failures by home pool so each owner gets one inbox
 * post (one eventfd wake), not one per item */
typedef struct pg_owner {
    pg_pool *home;
    pg_remote_item *head;
    pg_remote_item *tail;
} pg_owner;

typedef enum pg_conn_role {
    PG_CONN_READ = 0,
    PG_CONN_WRITE,
} pg_conn_role;

/* reconnect setup phases: dead conn, non-blocking connect, session init,
 * prepared statements */
typedef enum pg_setup {
    PG_SETUP_NONE = 0,
    PG_SETUP_CONNECT,
    PG_SETUP_INIT,
    PG_SETUP_PREPARE,
} pg_setup;

/* one execution of a single kind, detached from the queue while in flight */
typedef struct pg_read_batch {
    pg_read_kind kind;
    int n;
    pg_pending **reqs;
    pg_batch_hold *hold;        // batch result shared with remote owners
} pg_read_batch;

typedef struct pg_conn {
    PGconn *raw;
    pg_pool *pool;
    loop_fd *ev;
    pg_conn_role role;
    int index;
    pg_pending *head;
    pg_pending *tail;
    int queued;                 // writes not yet delivered
    int64_t write_deadline_ms;  // idle write lane commits its queue then
    bool dead;
    bool busy;                  // one execution or pipeline group in flight
    pg_setup setup;             // reconnect phase while dead
    int64_t retry_at_ms;        // next reconnect attempt
    int retry_backoff_ms;       // doubles on failure, capped, reset on success

    pg_read_batch batch;

    /* write group: BEGIN + group_sent writes + COMMIT, framed by
     * PQpipelineSync; group_results holds the write results */
    bool in_pipeline;
    int group_sent;
    int group_got;
    int group_total;
    bool group_failed;
    PGresult **group_results;
} pg_conn;

struct pg_pool {
    loop *loop;
    int worker_id;              // owning srv_worker; render jobs post back here
    int wx;                     // scheduler slot index
    int read_conns;
    int write_conns;
    int read_live;
    int write_live;
    int write_group;
    int write_window_ms;
    int rr;
    char *url;
    pg_conn *conns;

    /* inbox for answers another worker's connection has taken for this pool:
     * one mutex, drained by the resume eventfd. deferred local failures also
     * travel through here, so nothing callbacks off the pool's own loop */
    pg_remote_item *remote_head;
    pg_remote_item *remote_tail;
    pthread_mutex_t remote_lock;

    /* one eventfd resumes everything that ends up on this pool's loop from
     * elsewhere or was parked during teardown: deferred local failures,
     * cross-worker answers, and fresh takes from the shared read queue */
    int resume_fd;
    loop_fd *resume_ev;
};

/* process-wide read queues. the mutex guards list surgery, the shared batch
 * deadline and the live read conn count; callbacks and libpq calls never run
 * under it */
#define PG_SCHED_MAX_WORKERS 32

typedef struct pg_sched pg_sched;

typedef struct pg_sched_slot {
    pg_pool *pool;              // NULL while free
    int idle;                   // 1: a read conn is free and the queue is empty,
                                // so a submit is worth waking this pool for
    int wake;                   // 1: a kick fire is already in flight
} pg_sched_slot;

struct pg_sched {
    pthread_mutex_t lock;
    pg_read_queue queues[PG_READ_COUNT];
    uint64_t seq;
    int queued;
    int64_t deadline_ms;
    int batch;                  // env READ_BATCH, bound once at startup
    int window_ms;
    int live_reads;
    int npools;
    pg_sched_slot slots[PG_SCHED_MAX_WORKERS];
};

extern struct pg_sched g_pg_sched;

void pg_conn_open(pg_conn *cn, const char *url, int index);
void pg_conn_retry(pg_conn *cn);
void pg_conn_pump(pg_conn *cn);
bool pg_conn_dispatch_read(pg_conn *cn);
void pg_pool_dispatch_reads(pg_pool *pool);

/* process-wide read scheduler; the sched lock never joins callbacks or libpq
 * calls. bind registers a pool once at startup (main thread, pre workers) */
void pg_sched_bind(pg_pool *pool, int read_batch, int read_window_ms);
int  pg_sched_queued(void);
bool pg_sched_take(const pg_pool *pool, pg_read_kind *out_kind,
                   pg_pending ***out_reqs, int *out_n);
void pg_remote_post(pg_pool *owner, pg_remote_item *head, pg_remote_item *tail);

/* fail every pending in the list with PG_ERROR on its own home's loop */
void pg_sched_post_errors(pg_pending *list);
void pg_hold_release(pg_batch_hold *hold);
void pg_sched_fail_all(void);
void pg_sched_read_live_inc(void);
void pg_sched_read_live_dec(void);
int  pg_read_batch_cap(pg_read_kind kind);
void pg_pending_free(pg_pending *p);

/* run a pending's callback on the offload pool: takes one reference on hold
 * (reads) and ownership of raw (writes, cleared after cb); p is freed after cb */
void pg_render_async(pg_pending *p, pg_status status, pg_result view,
                     pg_batch_hold *hold, PGresult *raw);
int64_t pg_mono_ms(void);

#endif
