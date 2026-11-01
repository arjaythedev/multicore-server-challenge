#include "pg/pg_internal.h"

#include <string.h>
#include <time.h>

#include "crypto/offload.h"
#include "core/loop.h"
#include "core/wake.h"
#include "util.h"

int64_t pg_mono_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

struct pg_sched g_pg_sched = {
    .lock = PTHREAD_MUTEX_INITIALIZER,
    .batch = PG_READ_BATCH,
    .window_ms = PG_READ_WINDOW_MS,
};

/* ---- shared read scheduler: one process-wide queue per read kind ----
 *
 * Every worker's pg_read_submit joins the same queues; the first free read
 * connection of any worker takes the oldest ready kind, up to the batch cap,
 * as one execution. big batches no longer need one lucky busy worker: any
 * worker's idle read conn drains them. batch size and window are bound once
 * at startup; the mutex guards list surgery and the counters, never
 * callbacks or libpq calls (each PGconn is only touched by its own pool's
 * thread) */

void pg_sched_bind(pg_pool *pool, int read_batch, int read_window_ms) {
    pg_sched *s = &g_pg_sched;
    pthread_mutex_lock(&s->lock);
    CHECK(s->npools < PG_SCHED_MAX_WORKERS, "pg: too many workers (%d) for "
          "the shared read scheduler (max %d)", s->npools + 1,
          PG_SCHED_MAX_WORKERS);
    int wx = -1;
    for (int i = 0; i < PG_SCHED_MAX_WORKERS; i++) {
        if (!s->slots[i].pool) {
            wx = i;
            break;
        }
    }
    CHECK(wx >= 0, "pg: scheduler slot lookup failed");
    s->slots[wx].pool = pool;
    s->npools++;
    /* all pools share one env-sourced config; bind happens pre-threads */
    s->batch = read_batch;
    s->window_ms = read_window_ms;
    pool->wx = wx;
    pthread_mutex_unlock(&s->lock);
}

int pg_sched_queued(void) {
    pg_sched *s = &g_pg_sched;
    pthread_mutex_lock(&s->lock);
    int queued = s->queued;
    pthread_mutex_unlock(&s->lock);
    return queued;
}

int pg_read_batch_cap(pg_read_kind kind) {
    if (kind == PG_READ_TAGS) return PG_READ_TAG_BATCH;
    return g_pg_sched.batch;
}

/* pull the next read batch for a free read conn; false when nothing is ready
 * (empty, or window-gated). clears this slot's wake: the pool acted on its
 * kick */
bool pg_sched_take(const pg_pool *pool, pg_read_kind *out_kind,
                   pg_pending ***out_reqs, int *out_n) {
    pg_sched *s = &g_pg_sched;
    pthread_mutex_lock(&s->lock);
    s->slots[pool->wx].wake = 0;

    pg_read_kind best = PG_READ_COUNT;
    uint64_t best_seq = UINT64_MAX;
    for (int i = 0; i < PG_READ_COUNT; i++) {
        pg_read_queue *q = &s->queues[i];
        if (q->head && q->head->seq < best_seq) {
            best_seq = q->head->seq;
            best = (pg_read_kind)i;
        }
    }
    if (best == PG_READ_COUNT) {
        pthread_mutex_unlock(&s->lock);
        return false;
    }

    /* full batch sends at once; otherwise the window accumulates to amortise
     * one execution */
    int64_t now = pg_mono_ms();
    if (s->window_ms > 0 && s->queued < s->batch && now < s->deadline_ms) {
        pthread_mutex_unlock(&s->lock);
        return false;
    }

    pg_read_queue *q = &s->queues[best];
    int cap = pg_read_batch_cap(best);
    int n = q->count < cap ? q->count : cap;
    pg_pending **reqs = xmalloc((size_t)n * sizeof *reqs);
    for (int i = 0; i < n; i++) {
        pg_pending *p = q->head;
        q->head = p->next;
        if (!q->head) q->tail = NULL;
        p->next = NULL;
        reqs[i] = p;
    }
    q->count -= n;
    s->queued -= n;
    if (s->queued == 0) s->deadline_ms = 0;
    pthread_mutex_unlock(&s->lock);

    *out_kind = best;
    *out_reqs = reqs;
    *out_n = n;
    return true;
}

void pg_sched_read_live_inc(void) {
    pg_sched *s = &g_pg_sched;
    pthread_mutex_lock(&s->lock);
    s->live_reads++;
    pthread_mutex_unlock(&s->lock);
}

void pg_sched_read_live_dec(void) {
    pg_sched *s = &g_pg_sched;
    pthread_mutex_lock(&s->lock);
    int left = --s->live_reads;
    pthread_mutex_unlock(&s->lock);
    CHECK(left >= 0, "pg: scheduler read live count underflow");
    if (left == 0) {
        /* no read conn left process-wide: nothing can ever drain the queues
         * again, so fail everything now (its own pool took care of the
         * pendings that were in flight) */
        pg_sched_fail_all();
    }
}

void pg_sched_fail_all(void) {
    pg_sched *s = &g_pg_sched;
    pg_pending *list = NULL;
    pg_pending *tail = NULL;

    pthread_mutex_lock(&s->lock);
    for (int i = 0; i < PG_READ_COUNT; i++) {
        pg_read_queue *q = &s->queues[i];
        while (q->head) {
            pg_pending *p = q->head;
            q->head = p->next;
            if (!q->head) q->tail = NULL;
            p->next = NULL;
            if (tail) tail->next = p;
            else list = p;
            tail = p;
        }
        q->count = 0;
    }
    s->queued = 0;
    s->deadline_ms = 0;
    pthread_mutex_unlock(&s->lock);

    /* per-home inbox posting after the unlock, never under the sched lock */
    if (list) pg_sched_post_errors(list);
}

void pg_remote_post(pg_pool *owner, pg_remote_item *head, pg_remote_item *tail) {
    if (!head) return;
    CHECK(head && tail, "pg: malformed remote inbox batch");

    pthread_mutex_lock(&owner->remote_lock);
    if (owner->remote_tail) owner->remote_tail->next = head;
    else owner->remote_head = head;
    owner->remote_tail = tail;
    pthread_mutex_unlock(&owner->remote_lock);

    wake_fire(owner->resume_fd);
}

/* every pending in the list fails with PG_ERROR on its own home's loop */
void pg_sched_post_errors(pg_pending *list) {
    pg_sched *s = &g_pg_sched;
    pthread_mutex_lock(&s->lock);
    int npools = s->npools;
    pthread_mutex_unlock(&s->lock);
    CHECK(npools > 0 && npools <= PG_SCHED_MAX_WORKERS, "pg: pool count %d",
          npools);

    pg_owner bag[PG_SCHED_MAX_WORKERS];
    memset(bag, 0, sizeof bag);
    int nbags = 0;

    while (list) {
        pg_pending *p = list;
        list = p->next;
        p->next = NULL;
        CHECK(p->home != NULL, "pg: pending has no home pool");

        pg_remote_item *it = xcalloc(1, sizeof *it);
        it->p = p;
        it->status = PG_ERROR;  // view stays zeroed: PG_ERROR, no result

        int b = 0;
        for (; b < nbags && bag[b].home != p->home; b++) {
        }
        if (b == nbags) {
            CHECK(nbags < PG_SCHED_MAX_WORKERS, "pg: too many worker groups");
            bag[b].home = p->home;
            nbags++;
        }
        if (bag[b].tail) bag[b].tail->next = it;
        else bag[b].head = it;
        bag[b].tail = it;
    }

    for (int b = 0; b < nbags; b++)
        pg_remote_post(bag[b].home, bag[b].head, bag[b].tail);
}

void pg_hold_release(pg_batch_hold *hold) {
    if (!hold) return;
    /* refs crosses threads: remote homes drain concurrently. PGresult is
     * read-only after creation and PQclear is thread-safe */
    int left = __atomic_sub_fetch(&hold->refs, 1, __ATOMIC_SEQ_CST);
    if (left == 0) {
        PQclear(hold->raw);
        free(hold);
    }
}

/* advertise this pool's read-conn availability and wake every slot that has
 * been idle while work sits in the shared queue. restricted to work that a
 * take could actually satisfy right now: window-gated queues are driven by
 * the pool tick instead, or this loops on its own wake */
static void pg_sched_publish(const pg_pool *pool, bool idle) {
    pg_sched *s = &g_pg_sched;
    pg_pool *wake[PG_SCHED_MAX_WORKERS];
    int nwake = 0;

    pthread_mutex_lock(&s->lock);
    s->slots[pool->wx].idle = idle;
    bool fireable = s->window_ms == 0 || s->queued >= s->batch ||
                    pg_mono_ms() >= s->deadline_ms;
    if (s->queued > 0 && fireable) {
        for (int i = 0; i < PG_SCHED_MAX_WORKERS; i++) {
            pg_sched_slot *slot = &s->slots[i];
            if (slot->pool && slot->idle && !slot->wake) {
                slot->wake = 1;
                wake[nwake++] = slot->pool;
            }
        }
    }
    pthread_mutex_unlock(&s->lock);

    for (int i = 0; i < nwake; i++) wake_fire(wake[i]->resume_fd);
}

static void pg_sched_wake_clear(const pg_pool *pool) {
    pg_sched *s = &g_pg_sched;
    pthread_mutex_lock(&s->lock);
    s->slots[pool->wx].wake = 0;
    pthread_mutex_unlock(&s->lock);
}

/* ---- pool-level inbox: one eventfd drives everything that ends up here
 * from another thread (or parked during teardown) ---- */

static void resume_ready(void *user, loop_fd *self, unsigned events) {
    (void)self;
    if (!(events & LOOP_IN)) return;
    pg_pool *pool = user;
    wake_drain(pool->resume_fd);

    pg_sched_wake_clear(pool);

    pthread_mutex_lock(&pool->remote_lock);
    pg_remote_item *it = pool->remote_head;
    pool->remote_head = pool->remote_tail = NULL;
    pthread_mutex_unlock(&pool->remote_lock);

    while (it) {
        pg_remote_item *next = it->next;
        pg_result view = it->viewp ? *it->viewp : (pg_result){0};
        pg_render_async(it->p, it->status, view, it->hold, NULL);
        if (it->hold) pg_hold_release(it->hold);    // item's ref; job took its own
        free(it);
        it = next;
    }

    /* fresh kicks from the shared queue and our own just-freed read conn */
    pg_pool_dispatch_reads(pool);
}

static void read_push(pg_read_queue *q, pg_pending *p) {
    p->next = NULL;
    if (q->tail) q->tail->next = p;
    else q->head = p;
    q->tail = p;
    q->count++;
}

void pg_pending_free(pg_pending *p) {
    if (!p) return;
    free(p->params);
    free(p);
}

void pg_pool_open(pg_pool **out, const char *url, int read_conns,
                  int write_conns, int read_batch, int read_window_ms,
                  int write_group, int write_window_ms, int worker_id,
                  loop *l) {
    CHECK(read_conns >= 1, "pg: at least one read connection is required");
    CHECK(write_conns >= 1, "pg: at least one write connection is required");
    CHECK(read_batch >= 1, "pg: read batch must be positive");
    CHECK(read_window_ms >= 0, "pg: read window must be non-negative");
    CHECK(write_group >= 1 && write_group <= PG_WRITE_GROUP_MAX,
          "pg: write group must be 1..%d", PG_WRITE_GROUP_MAX);
    CHECK(write_window_ms >= 0, "pg: write window must be non-negative");

    pg_pool *pool = xcalloc(1, sizeof *pool);
    pool->loop = l;
    pool->worker_id = worker_id;
    pool->url = xmalloc(strlen(url) + 1);
    strcpy(pool->url, url);
    pool->read_conns = read_conns;
    pool->write_conns = write_conns;
    pool->read_live = read_conns;
    pool->write_live = write_conns;
    pool->write_group = write_group;
    pool->write_window_ms = write_window_ms;
    pool->conns = xcalloc((size_t)(read_conns + write_conns),
                          sizeof *pool->conns);

    pool->resume_fd = wake_new();
    CHECK(pool->resume_fd >= 0, "pg: resume eventfd creation failed");
    pool->resume_ev = loop_add(l, pool->resume_fd, LOOP_IN, resume_ready, pool);
    CHECK(pool->resume_ev != NULL, "pg: loop_add(resume eventfd) failed");

    pg_sched_bind(pool, read_batch, read_window_ms);

    for (int i = 0; i < read_conns + write_conns; i++) {
        pg_conn *cn = &pool->conns[i];
        cn->pool = pool;
        cn->role = i < read_conns ? PG_CONN_READ : PG_CONN_WRITE;
        cn->group_results =
            xcalloc((size_t)write_group, sizeof *cn->group_results);
        cn->retry_backoff_ms = PG_RECONNECT_BACKOFF_MIN;
        pg_conn_open(cn, url, i);
    }
    *out = pool;
}

static pg_conn *pool_pick_write(pg_pool *pool) {
    pg_conn *best = NULL;
    int best_index = -1;
    int total = pool->read_conns + pool->write_conns;
    for (int i = 0; i < total; i++) {
        int index = (pool->rr + i) % total;
        pg_conn *candidate = &pool->conns[index];
        if (candidate->role != PG_CONN_WRITE || candidate->dead) continue;
        int load = candidate->queued + (candidate->busy ? 1 : 0);
        int best_load = best ? best->queued + (best->busy ? 1 : 0) : 0;
        if (!best || load < best_load) {
            best = candidate;
            best_index = index;
        }
    }
    if (best) pool->rr = (best_index + 1) % total;
    return best;
}

/* off-loop submits (a render callback chaining another pg op) marshal to the
 * home loop: PGconns are only touched by their own pool's thread */
struct pg_submit_job {
    pg_pool *pool;
    pg_stmt stmt;
    int nparams;
    const char **params;
    void *ctx;
    pg_cb cb;
};

static void pg_submit_run(void *arg) {
    struct pg_submit_job *job = arg;
    pg_submit(job->pool, job->stmt, job->nparams, job->params, job->ctx,
              job->cb);
    free(job->params);
    free(job);
}

struct pg_read_job {
    pg_pool *pool;
    pg_read_kind kind;
    pg_read read;
    void *ctx;
    pg_cb cb;
};

static void pg_read_submit_run(void *arg) {
    struct pg_read_job *job = arg;
    pg_read_submit(job->pool, job->kind, &job->read, job->ctx, job->cb);
    free(job);
}

void pg_submit(pg_pool *pool, pg_stmt stmt, int nparams,
               const char *const *params, void *ctx, pg_cb cb) {
    CHECK(stmt >= 0 && stmt < PG_STMT_COUNT, "pg_submit: bad statement %d", stmt);
    CHECK(nparams == PG_STMT_PARAM_COUNT[stmt],
          "pg_submit: statement %d takes %u parameters, got %d", (int)stmt,
          (unsigned)PG_STMT_PARAM_COUNT[stmt], nparams);
    CHECK(nparams == 0 || params != NULL, "pg_submit: missing parameters");
    CHECK(cb != NULL, "pg_submit: callback is required");

    if (loop_current() != pool->loop) {
        struct pg_submit_job *job = xmalloc(sizeof *job);
        job->pool = pool;
        job->stmt = stmt;
        job->nparams = nparams;
        job->params = nparams ? xmalloc((size_t)nparams * sizeof *job->params)
                              : NULL;
        if (nparams)
            memcpy(job->params, params, (size_t)nparams * sizeof *job->params);
        job->ctx = ctx;
        job->cb = cb;
        crypto_post(pool->worker_id, pg_submit_run, job);
        return;
    }

    pg_pending *p = xcalloc(1, sizeof *p);
    p->home = pool;
    p->stmt = stmt;
    p->nparams = nparams;
    p->ctx = ctx;
    p->cb = cb;
    p->solo = PG_STMT_SOLO[stmt] != 0;
    if (nparams > 0) {
        p->params = xmalloc((size_t)nparams * sizeof *p->params);
        memcpy(p->params, params, (size_t)nparams * sizeof *p->params);
    }

    pg_conn *cn = pool_pick_write(pool);
    if (!cn) {
        pg_sched_post_errors(p);
        return;
    }

    if (cn->tail) cn->tail->next = p;
    else cn->head = p;
    cn->tail = p;
    cn->queued++;

    /* one commit can carry several writes: a lone write waits briefly for
     * siblings, a deep queue sends now */
    if (cn->queued >= PG_WRITE_IMMEDIATE || pool->write_window_ms == 0) {
        cn->write_deadline_ms = 0;
        pg_conn_pump(cn);
    } else if (cn->write_deadline_ms == 0) {
        cn->write_deadline_ms = pg_mono_ms() + pool->write_window_ms;
    }
}

void pg_read_submit(pg_pool *pool, pg_read_kind kind, const pg_read *read,
                    void *ctx, pg_cb cb) {
    CHECK(kind >= 0 && kind < PG_READ_COUNT, "pg_read_submit: bad kind %d", kind);
    CHECK(cb != NULL, "pg_read_submit: callback is required");
    CHECK(kind == PG_READ_TAGS || read != NULL,
          "pg_read_submit: missing read arguments");

    if (loop_current() != pool->loop) {
        struct pg_read_job *job = xmalloc(sizeof *job);
        job->pool = pool;
        job->kind = kind;
        job->read = read ? *read : (pg_read){0};
        job->ctx = ctx;
        job->cb = cb;
        crypto_post(pool->worker_id, pg_read_submit_run, job);
        return;
    }

    pg_sched *s = &g_pg_sched;
    pthread_mutex_lock(&s->lock);
    if (s->live_reads == 0) {
        pthread_mutex_unlock(&s->lock);
        pg_pending *p = xcalloc(1, sizeof *p);
        p->home = pool;
        p->key = "";
        pg_sched_post_errors(p);
        return;
    }

    pg_pending *p = xcalloc(1, sizeof *p);
    p->home = pool;
    p->ctx = ctx;
    p->cb = cb;
    p->seq = ++s->seq;
    p->list_kind = read ? read->list_kind : 0;
    if (read) {
        p->viewer = read->viewer;
        p->limit = read->limit;
        p->offset = read->offset;
        p->key = read->key ? read->key : "";
    } else {
        p->key = "";
    }

    bool was_empty = s->queued == 0;
    read_push(&s->queues[kind], p);
    s->queued++;
    if (was_empty) s->deadline_ms = pg_mono_ms() + s->window_ms;
    pthread_mutex_unlock(&s->lock);

    /* local idle read conns take first; whoever stays idle gets kicked via
     * publish */
    pg_pool_dispatch_reads(pool);
}

void pg_pool_dispatch_reads(pg_pool *pool) {
    bool has_idle = false;
    bool stuck = false;         // a conn wanted work but take refused
    for (int i = 0; i < pool->read_conns; i++) {
        pg_conn *cn = &pool->conns[i];
        if (cn->dead || cn->busy || cn->setup != PG_SETUP_NONE) continue;
        has_idle = true;
        if (stuck) continue;
        if (!pg_sched_queued()) break;
        if (!pg_conn_dispatch_read(cn)) stuck = true;
    }
    pg_sched_publish(pool, has_idle);
}

void pg_pool_tick(pg_pool *pool) {
    /* lost conns reconnect with backoff before any dispatch */
    int64_t now = pg_mono_ms();
    int total = pool->read_conns + pool->write_conns;
    for (int i = 0; i < total; i++) {
        pg_conn *cn = &pool->conns[i];
        if (!cn->dead || cn->setup != PG_SETUP_NONE) continue;
        if (cn->retry_at_ms == 0 || now < cn->retry_at_ms) continue;
        pg_conn_retry(cn);
    }

    /* safety net: window expiry and any wake that ever gets lost drive from
     * the worker's 1ms tick */
    if (pg_sched_queued()) pg_pool_dispatch_reads(pool);

    /* send a write queued behind a busy lane as soon as the lane frees */
    for (int i = pool->read_conns; i < total; i++) {
        pg_conn *cn = &pool->conns[i];
        if (cn->dead || cn->busy) continue;
        if (!cn->head) {
            cn->write_deadline_ms = 0;
            continue;
        }
        if (cn->write_deadline_ms == 0)
            cn->write_deadline_ms = now + pool->write_window_ms;
        if (cn->queued >= PG_WRITE_IMMEDIATE || now >= cn->write_deadline_ms) {
            cn->write_deadline_ms = 0;
            pg_conn_pump(cn);
        }
    }
}
