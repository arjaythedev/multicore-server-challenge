#include "pg/pg_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "core/buf.h"
#include "crypto/offload.h"
#include "util.h"

static void pg_conn_event(void *user, loop_fd *self, unsigned events);
static void pg_conn_fail(pg_conn *cn);
static void pg_conn_set_events(pg_conn *cn);
static void pg_conn_consume(pg_conn *cn);
static void pg_conn_deliver_group(pg_conn *cn);
static void pg_conn_deliver_one(pg_conn *cn, PGresult *r);
static void pg_conn_deliver_read(pg_conn *cn, PGresult *r);
static void pg_owner_bag_add(pg_owner *bag, int *nbags, pg_pending *p,
                             pg_remote_item *it);
static void pg_owner_bag_flush(pg_owner *bag, int nbags);
static void setup_fail(pg_conn *cn, const char *what);
static void setup_connected(pg_conn *cn);
static void setup_poll(pg_conn *cn);

static pg_status status_of(PGresult *r) {
    if (!r) return PG_ERROR;
    // *UNCRUSTIFY-OFF*
    switch (PQresultStatus(r)) {
    case PGRES_TUPLES_OK: return PG_ROWS;
    case PGRES_COMMAND_OK: return PG_COMMAND;
    default: return PG_ERROR;
    }
    // *UNCRUSTIFY-ON*
}

static pg_pending *pending_pop(pg_conn *cn) {
    pg_pending *p = cn->head;
    CHECK(p != NULL, "pg: delivery queue underrun");
    cn->head = p->next;
    if (!cn->head) cn->tail = NULL;
    p->next = NULL;
    cn->queued--;
    return p;
}

static void group_clear(pg_conn *cn) {
    for (int i = 0; i < cn->pool->write_group; i++) {
        if (cn->group_results[i]) {
            PQclear(cn->group_results[i]);
            cn->group_results[i] = NULL;
        }
    }
    cn->group_sent = 0;
    cn->group_got = 0;
    cn->group_total = 0;
    cn->group_failed = false;
    cn->in_pipeline = false;
}

/* pg result callbacks run on the offload pool: tuple parsing + JSON rendering
 * is the heavy per-response CPU and must stay off the io threads. the job owns
 * the result (write results are cleared), the pending, and one batch reference
 * for reads; everything it touches is refcounted or heap-only */
struct render_job {
    pg_cb cb;
    void *ctx;
    pg_status status;
    pg_result view;
    pg_pending *p;
    pg_batch_hold *hold;        // read batches: released after cb
    PGresult *raw;              // write results: cleared after cb
};

static void render_work(void *arg) {
    struct render_job *job = arg;
    job->cb(job->ctx, job->status, &job->view);
    if (job->raw) PQclear(job->raw);
    if (job->p) pg_pending_free(job->p);
    if (job->hold) pg_hold_release(job->hold);
}

static void render_done(void *arg) {
    (void)arg;
}

void pg_render_async(pg_pending *p, pg_status status, pg_result view,
                     pg_batch_hold *hold, PGresult *raw) {
    struct render_job *job = xmalloc(sizeof *job);
    job->cb = p->cb;
    job->ctx = p->ctx;
    job->status = status;
    job->view = view;
    job->p = p;
    job->hold = hold;
    job->raw = raw;
    if (hold) __atomic_fetch_add(&hold->refs, 1, __ATOMIC_SEQ_CST);
    crypto_submit(p->home->worker_id, render_work, render_done, job);
}

static bool send_pending(pg_conn *cn, const pg_pending *p) {
    char name[16];
    int n = snprintf(name, sizeof name, "s%d", (int)p->stmt);
    if (n < 0 || (size_t)n >= sizeof name) return false;
    return PQsendQueryPrepared(cn->raw, name, p->nparams,
                               (const char *const *)p->params, NULL, NULL, 0) == 1;
}

static void encode_text_element(buf *out, const char *s) {
    buf_putc(out, '"');
    for (; *s; s++) {
        if (*s == '"' || *s == '\\') buf_putc(out, '\\');
        buf_putc(out, *s);
    }
    buf_putc(out, '"');
}

/* arrays are text literals; libpq copies them before PQsendQueryPrepared
 * returns, so the bufs are freed right after. every element quoted+escaped */
static bool send_read(pg_conn *cn, pg_read_kind kind, pg_pending **reqs,
                      int n) {
    char name[16];
    int len = snprintf(name, sizeof name, "r%d", (int)kind);
    if (len < 0 || (size_t)len >= sizeof name) return false;

    if (kind == PG_READ_TAGS) {
        return PQsendQueryPrepared(cn->raw, name, 0, NULL, NULL, NULL, 0) == 1;
    }

    buf index;
    buf viewer;
    buf limit;
    buf offset;
    buf key;
    buf lkind;
    bool merged = kind == PG_READ_LIST;
    buf_init(&index);
    buf_init(&viewer);
    buf_init(&limit);
    buf_init(&offset);
    buf_init(&key);
    buf_init(&lkind);
    buf_putc(&index, '{');
    buf_putc(&viewer, '{');
    buf_putc(&limit, '{');
    buf_putc(&offset, '{');
    buf_putc(&key, '{');
    buf_putc(&lkind, '{');

    for (int i = 0; i < n; i++) {
        if (i) {
            buf_putc(&index, ',');
            buf_putc(&viewer, ',');
            buf_putc(&limit, ',');
            buf_putc(&offset, ',');
            buf_putc(&key, ',');
            buf_putc(&lkind, ',');
        }
        buf_printf(&index, "%d", i);
        buf_printf(&viewer, "%lld", reqs[i]->viewer);
        buf_printf(&limit, "%d", reqs[i]->limit);
        buf_printf(&offset, "%lld", reqs[i]->offset);
        encode_text_element(&key, reqs[i]->key);
        buf_printf(&lkind, "%d", (int)reqs[i]->list_kind);
    }
    buf_putc(&index, '}');
    buf_putc(&viewer, '}');
    buf_putc(&limit, '}');
    buf_putc(&offset, '}');
    buf_putc(&key, '}');
    buf_putc(&lkind, '}');
    /* libpq wants C strings; buf doesn't terminate, so add NUL in reserved cap */
    buf_putc(&index, '\0');
    buf_putc(&viewer, '\0');
    buf_putc(&limit, '\0');
    buf_putc(&offset, '\0');
    buf_putc(&key, '\0');
    buf_putc(&lkind, '\0');

    const char *params5[5] = { index.data, viewer.data, limit.data,
                               offset.data, key.data };
    const char *params6[6] = { index.data, viewer.data, limit.data,
                               offset.data, key.data, lkind.data };
    int rc = PQsendQueryPrepared(cn->raw, name, merged ? 6 : 5,
                                 merged ? params6 : params5, NULL, NULL, 0);
    buf_free(&index);
    buf_free(&viewer);
    buf_free(&limit);
    buf_free(&offset);
    buf_free(&key);
    buf_free(&lkind);
    return rc == 1;
}

void pg_conn_pump(pg_conn *cn) {
    if (cn->dead || cn->busy || cn->role != PG_CONN_WRITE || !cn->head) return;

    const pg_pending *head = cn->head;
    int group = 0;
    if (!head->solo) {
        for (const pg_pending *p = head;
             p && !p->solo && group < cn->pool->write_group; p = p->next)
            group++;
    }

    if (group >= 2) {
        if (PQenterPipelineMode(cn->raw) != 1) {
            pg_conn_fail(cn);
            return;
        }
        cn->in_pipeline = true;
        cn->group_sent = 0;
        cn->group_got = 0;
        cn->group_total = group + 2;
        cn->group_failed = false;

        if (PQsendQueryParams(cn->raw, "BEGIN", 0, NULL, NULL, NULL, NULL, 0) != 1) {
            pg_conn_fail(cn);
            return;
        }
        const pg_pending *p = head;
        for (int i = 0; i < group; i++, p = p->next) {
            if (!send_pending(cn, p)) {
                pg_conn_fail(cn);
                return;
            }
            cn->group_sent++;
        }
        if (PQsendQueryParams(cn->raw, "COMMIT", 0, NULL, NULL, NULL, NULL, 0) != 1) {
            pg_conn_fail(cn);
            return;
        }
        if (PQpipelineSync(cn->raw) != 1) {
            pg_conn_fail(cn);
            return;
        }
        cn->busy = true;
        pg_conn_set_events(cn);
        return;
    }

    if (!send_pending(cn, head)) {
        pg_conn_fail(cn);
        return;
    }
    cn->busy = true;
    pg_conn_set_events(cn);
}

bool pg_conn_dispatch_read(pg_conn *cn) {
    if (cn->dead || cn->busy || cn->role != PG_CONN_READ) return false;

    /* the pool has a free read conn: pull the oldest ready kind, up to the
     * batch cap, from the process-wide shared queue */
    pg_read_kind kind;
    pg_pending **reqs;
    int n;
    if (!pg_sched_take(cn->pool, &kind, &reqs, &n)) return false;

    cn->batch.kind = kind;
    cn->batch.n = n;
    cn->batch.reqs = reqs;
    cn->busy = true;

    if (!send_read(cn, kind, reqs, n)) {
        pg_conn_fail(cn);
        return true;
    }
    pg_conn_set_events(cn);
    return true;
}

void pg_conn_open(pg_conn *cn, const char *url, int index) {
    cn->index = index;
    cn->raw = PQconnectdb(url);
    CHECK(cn->raw != NULL, "pg[%d]: PQconnectdb failed", index);
    CHECK(PQstatus(cn->raw) == CONNECTION_OK, "pg[%d]: %s", index,
          PQerrorMessage(cn->raw));
    CHECK(PQsetnonblocking(cn->raw, 1) == 0, "pg[%d]: setnonblocking: %s", index,
          PQerrorMessage(cn->raw));

    PGresult *r = PQexec(cn->raw, PG_SESSION_INIT);
    CHECK(r != NULL && PQresultStatus(r) == PGRES_COMMAND_OK,
          "pg[%d]: session init: %s", index,
          r ? PQresultErrorMessage(r) : PQerrorMessage(cn->raw));
    PQclear(r);

    for (int i = 0; i < PG_STMT_COUNT; i++) {
        char name[16];
        int n = snprintf(name, sizeof name, "s%d", i);
        CHECK(n > 0 && (size_t)n < sizeof name, "pg[%d]: statement name", index);
        r = PQprepare(cn->raw, name, PG_STMT_SQL[i],
                      (int)PG_STMT_PARAM_COUNT[i], NULL);
        CHECK(r != NULL && PQresultStatus(r) == PGRES_COMMAND_OK,
              "pg[%d]: prepare %s: %s", index, PG_STMT_SQL[i],
              r ? PQresultErrorMessage(r) : PQerrorMessage(cn->raw));
        PQclear(r);
    }
    for (int i = 0; i < PG_READ_COUNT; i++) {
        char name[16];
        int n = snprintf(name, sizeof name, "r%d", i);
        CHECK(n > 0 && (size_t)n < sizeof name, "pg[%d]: read name", index);
        r = PQprepare(cn->raw, name, PG_READ_SQL[i],
                      (int)PG_READ_PARAM_COUNT[i], NULL);
        CHECK(r != NULL && PQresultStatus(r) == PGRES_COMMAND_OK,
              "pg[%d]: prepare %s: %s", index, PG_READ_SQL[i],
              r ? PQresultErrorMessage(r) : PQerrorMessage(cn->raw));
        PQclear(r);
    }

    int fd = PQsocket(cn->raw);
    CHECK(fd >= 0, "pg[%d]: no socket", index);
    cn->ev = loop_add(cn->pool->loop, fd, LOOP_IN, pg_conn_event, cn);
    CHECK(cn->ev != NULL, "pg[%d]: loop_add failed", index);

    if (cn->role == PG_CONN_READ) pg_sched_read_live_inc();
}

static void pg_conn_set_events(pg_conn *cn) {
    if (cn->dead) return;
    unsigned events = LOOP_IN;
    int rc = PQflush(cn->raw);
    if (rc < 0) {
        pg_conn_fail(cn);
        return;
    }
    if (rc > 0) events |= LOOP_OUT;
    loop_set_events(cn->pool->loop, cn->ev, events);
}

static void pg_conn_fail(pg_conn *cn) {
    if (cn->dead) return;
    cn->dead = true;
    pg_pool *pool = cn->pool;
    int delay = cn->retry_backoff_ms;
    cn->retry_at_ms = pg_mono_ms() + delay;
    cn->retry_backoff_ms = delay * 2 > PG_RECONNECT_BACKOFF_MAX
                               ? PG_RECONNECT_BACKOFF_MAX
                               : delay * 2;
    fprintf(stderr, "pg[%d]: connection lost; retry in %d ms\n", cn->index,
            delay);
    if (cn->role == PG_CONN_READ) {
        CHECK(pool->read_live > 0, "pg: read live count underflow");
        pool->read_live--;
    } else {
        CHECK(pool->write_live > 0, "pg: write live count underflow");
        pool->write_live--;
    }

    if (cn->ev) {
        loop_remove(pool->loop, cn->ev);
        cn->ev = NULL;
    }
    group_clear(cn);
    cn->busy = false;

    pg_pending *list = NULL;
    if (cn->batch.reqs) {
        pg_pending *tail = NULL;
        for (int i = 0; i < cn->batch.n; i++) {
            pg_pending *p = cn->batch.reqs[i];
            p->next = NULL;
            if (tail) tail->next = p;
            else list = p;
            tail = p;
        }
        free(cn->batch.reqs);
        cn->batch.reqs = NULL;
        cn->batch.n = 0;
    }

    pg_pending *queued = cn->head;
    cn->head = cn->tail = NULL;
    cn->queued = 0;
    if (queued) {
        if (list) {
            pg_pending *tail = list;
            while (tail->next) tail = tail->next;
            tail->next = queued;
        } else {
            list = queued;
        }
    }

    /* batch pendings come from every pool (they were taken from the shared
     * queue): fail each one on its own home's loop */
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
        it->status = PG_ERROR;
        pg_owner_bag_add(bag, &nbags, p, it);
    }
    pg_owner_bag_flush(bag, nbags);

    if (cn->raw) {
        PQfinish(cn->raw);
        cn->raw = NULL;
    }

    if (cn->role == PG_CONN_READ) {
        /* last read conn process-wide also fails everything parked in the
         * shared queues */
        pg_sched_read_live_dec();
        pg_pool_dispatch_reads(pool);
    }
}

static void pg_conn_deliver_one(pg_conn *cn, PGresult *r) {
    pg_pending *p = pending_pop(cn);
    pg_result view = {
        .raw = r,
        .first_row = 0,
        .rows = r ? PQntuples(r) : 0,
        .col_offset = 0,
    };
    pg_render_async(p, status_of(r), view, NULL, r);
}

static void pg_conn_deliver_group(pg_conn *cn) {
    int sent = cn->group_sent;
    bool failed = cn->group_failed;

    for (int i = 0; i < sent; i++) {
        PGresult *r = cn->group_results[i];
        cn->group_results[i] = NULL;

        pg_pending *p = pending_pop(cn);
        pg_status status = failed || !r ? PG_ERROR : status_of(r);
        pg_result view = {
            .raw = r,
            .first_row = 0,
            .rows = r ? PQntuples(r) : 0,
            .col_offset = 0,
        };
        pg_render_async(p, status, view, NULL, r);
    }
    cn->group_sent = 0;
    cn->group_got = 0;
    cn->group_total = 0;
    cn->group_failed = false;
}

static void pg_owner_bag_add(pg_owner *bag, int *nbags, pg_pending *p,
                             pg_remote_item *it) {
    int b = 0;
    for (; b < *nbags && bag[b].home != p->home; b++) {}
    if (b == *nbags) {
        CHECK(*nbags < PG_SCHED_MAX_WORKERS, "pg: too many worker groups");
        bag[b].home = p->home;
        (*nbags)++;
    }
    it->next = NULL;
    if (bag[b].tail) bag[b].tail->next = it;
    else bag[b].head = it;
    bag[b].tail = it;
}

static void pg_owner_bag_flush(pg_owner *bag, int nbags) {
    for (int b = 0; b < nbags; b++)
        pg_remote_post(bag[b].home, bag[b].head, bag[b].tail);
}

static void pg_conn_deliver_read(pg_conn *cn, PGresult *r) {
    int n = cn->batch.n;
    pg_pending **reqs = cn->batch.reqs;
    pg_read_kind kind = cn->batch.kind;
    cn->batch.n = 0;
    cn->batch.reqs = NULL;
    cn->batch.hold = NULL;

    bool broadcast = kind == PG_READ_TAGS;
    bool ok = r && PQresultStatus(r) == PGRES_TUPLES_OK;
    if (!ok) {
        fprintf(stderr, "pg read %d failed: %s\n", (int)kind,
                r ? PQresultErrorMessage(r) : PQerrorMessage(cn->raw));
    }
    bool valid = ok;
    int *first = NULL;
    int *count = NULL;
    int *last = NULL;

    if (ok && !broadcast) {
        first = xmalloc((size_t)n * sizeof *first);
        count = xcalloc((size_t)n, sizeof *count);
        last = xmalloc((size_t)n * sizeof *last);
        for (int i = 0; i < n; i++) {
            first[i] = -1;
            last[i] = -1;
        }

        int rows = PQntuples(r);
        for (int row = 0; row < rows; row++) {
            if (PQgetisnull(r, row, 0)) {
                valid = false;
                break;
            }
            const char *raw = PQgetvalue(r, row, 0);
            char *end = NULL;
            long index = strtol(raw, &end, 10);
            if (!end || *end != '\0' || index < 0 || index >= n) {
                valid = false;
                break;
            }
            if (count[index] && last[index] != row - 1) {
                /* unnest order is a plan contract (parallel gather off);
                 * reordering is a bug */
                valid = false;
                break;
            }
            if (count[index] == 0) first[index] = row;
            count[index]++;
            last[index] = row;
        }
    }

    if (ok && !valid) {
        fprintf(stderr, "pg read %d returned rows that do not map to requests\n",
                (int)kind);
    }

    /* the batch result outlives this conn: remote homes take one reference
     * each and the last release clears it, on whichever thread got there
     * first. so no PQclear here for reads */
    pg_batch_hold *hold = NULL;
    if (r) {
        hold = xcalloc(1, sizeof *hold);
        hold->raw = r;
        __atomic_store_n(&hold->refs, 1, __ATOMIC_SEQ_CST);
    }

    /* pendings homed elsewhere get one inbox item each, posted per owner so
     * the remote loop wakes once */
    pg_owner bag[PG_SCHED_MAX_WORKERS];
    memset(bag, 0, sizeof bag);
    int nbags = 0;

    for (int i = 0; i < n; i++) {
        pg_pending *p = reqs[i];
        if (p->home == cn->pool) {
            if (!valid) {
                pg_result view = { .raw = r };
                pg_render_async(p, PG_ERROR, view, hold, NULL);
            } else if (broadcast) {
                pg_result view = {
                    .raw = r,
                    .first_row = 0,
                    .rows = PQntuples(r),
                    .col_offset = 0,
                };
                pg_render_async(p, PG_ROWS, view, hold, NULL);
            } else {
                pg_result view = {
                    .raw = r,
                    .first_row = first && count[i] ? first[i] : 0,
                    .rows = count ? count[i] : 0,
                    .col_offset = 1,
                };
                pg_render_async(p, PG_ROWS, view, hold, NULL);
            }
            continue;
        }

        CHECK(p->home != NULL, "pg: pending has no home pool");
        pg_remote_item *it = xcalloc(1, sizeof *it);
        it->p = p;
        it->status = !valid ? PG_ERROR : PG_ROWS;
        if (r) {
            it->view.raw = r;
            if (valid && !broadcast) {
                it->view.first_row = first && count[i] ? first[i] : 0;
                it->view.rows = count ? count[i] : 0;
                it->view.col_offset = 1;
            } else if (valid) {
                it->view.first_row = 0;
                it->view.rows = PQntuples(r);
                it->view.col_offset = 0;
            }
            it->viewp = &it->view;
        }
        if (r) {
            __atomic_fetch_add(&hold->refs, 1, __ATOMIC_SEQ_CST);
            it->hold = hold;
        }
        pg_owner_bag_add(bag, &nbags, p, it);
    }
    pg_owner_bag_flush(bag, nbags);
    if (hold) pg_hold_release(hold);

    free(first);
    free(count);
    free(last);
    free(reqs);
}

static void pg_conn_consume_read(pg_conn *cn) {
    if (!cn->busy) return;
    if (PQisBusy(cn->raw)) return;

    PGresult *r = PQgetResult(cn->raw);
    /* deliver_read owns the result: the shared batch hold clears it once the
     * last remote home is done, so no PQclear here */
    pg_conn_deliver_read(cn, r);

    /* a query ends with a NULL result; drain it before the next execution */
    PGresult *end = PQgetResult(cn->raw);
    if (end) PQclear(end);
    cn->busy = false;
}

static void pg_conn_consume_write(pg_conn *cn) {
    for (;;) {
        if (!cn->busy) return;
        if (PQisBusy(cn->raw)) return;
        PGresult *r = PQgetResult(cn->raw);

        if (cn->in_pipeline) {
            /* pipeline mode inserts a NULL between statement results: a
             * separator, not the end of the batch */
            if (!r) continue;

            if (PQresultStatus(r) == PGRES_PIPELINE_SYNC) {
                if (cn->group_got != cn->group_total) {
                    PQclear(r);
                    pg_conn_fail(cn);
                    return;
                }
                PQclear(r);
                if (PQexitPipelineMode(cn->raw) != 1) {
                    pg_conn_fail(cn);
                    return;
                }
                cn->in_pipeline = false;

                int sent = cn->group_sent;
                if (cn->group_failed) {
                    /* BEGIN framed the group, so a statement error rolled it
                     * back; retry each write alone */
                    pg_pending *p = cn->head;
                    for (int i = 0; i < sent && p; i++, p = p->next)
                        p->solo = true;
                    group_clear(cn);
                } else {
                    pg_conn_deliver_group(cn);
                }
                cn->busy = false;
                return;
            }

            int index = cn->group_got;
            if (index >= cn->group_total) {
                PQclear(r);
                pg_conn_fail(cn);
                return;
            }

            ExecStatusType status = PQresultStatus(r);
            if (status == PGRES_PIPELINE_ABORTED) {
                cn->group_failed = true;
                PQclear(r);
            } else if (index >= 1 && index <= cn->group_sent) {
                if (status != PGRES_TUPLES_OK && status != PGRES_COMMAND_OK)
                    cn->group_failed = true;
                cn->group_results[index - 1] = r;
            } else {
                if (status != PGRES_COMMAND_OK) cn->group_failed = true;
                PQclear(r);
            }
            cn->group_got++;
            continue;
        }

        if (!r) {
            cn->busy = false;
            return;
        }
        pg_conn_deliver_one(cn, r);
        /* busy until the trailing NULL arrives: a callback submitting the next
         * stmt can't re-enter */
    }
}

static void pg_conn_consume(pg_conn *cn) {
    if (cn->role == PG_CONN_READ) pg_conn_consume_read(cn);
    else pg_conn_consume_write(cn);
}

/* ---- reconnect: dead conns come back via pool tick + the conn's own fd ---- */

/* non-blocking setup, one phase per result drain: TCP connect poll, session
 * SETs, then every PQprepare pipelined into a single round trip */
static void setup_events(pg_conn *cn, unsigned events) {
    if (cn->ev) loop_set_events(cn->pool->loop, cn->ev, events);
}

static void setup_send_prepares(pg_conn *cn) {
    if (PQenterPipelineMode(cn->raw) != 1) {
        setup_fail(cn, "enter pipeline");
        return;
    }
    for (int i = 0; i < PG_STMT_COUNT; i++) {
        char name[16];
        int n = snprintf(name, sizeof name, "s%d", i);
        CHECK(n > 0 && (size_t)n < sizeof name, "pg[%d]: statement name",
              cn->index);
        if (PQsendPrepare(cn->raw, name, PG_STMT_SQL[i],
                          (int)PG_STMT_PARAM_COUNT[i], NULL) != 1) {
            setup_fail(cn, "prepare send");
            return;
        }
    }
    for (int i = 0; i < PG_READ_COUNT; i++) {
        char name[16];
        int n = snprintf(name, sizeof name, "r%d", i);
        CHECK(n > 0 && (size_t)n < sizeof name, "pg[%d]: read name", cn->index);
        if (PQsendPrepare(cn->raw, name, PG_READ_SQL[i],
                          (int)PG_READ_PARAM_COUNT[i], NULL) != 1) {
            setup_fail(cn, "prepare send");
            return;
        }
    }
    if (PQpipelineSync(cn->raw) != 1) {
        setup_fail(cn, "pipeline sync");
        return;
    }
    cn->setup = PG_SETUP_PREPARE;
}

static void setup_fail(pg_conn *cn, const char *what) {
    if (cn->ev) {
        loop_remove(cn->pool->loop, cn->ev);
        cn->ev = NULL;
    }
    if (cn->raw) {
        fprintf(stderr, "pg[%d]: reconnect %s failed: %s", cn->index, what,
                PQerrorMessage(cn->raw));
        PQfinish(cn->raw);
        cn->raw = NULL;
    }
    cn->busy = false;
    group_clear(cn);
    cn->setup = PG_SETUP_NONE;
    int delay = cn->retry_backoff_ms;
    cn->retry_at_ms = pg_mono_ms() + delay;
    cn->retry_backoff_ms = delay * 2 > PG_RECONNECT_BACKOFF_MAX
                               ? PG_RECONNECT_BACKOFF_MAX
                               : delay * 2;
    fprintf(stderr, "pg[%d]: next retry in %d ms\n", cn->index, delay);
}

static void setup_ready(pg_conn *cn) {
    if (PQexitPipelineMode(cn->raw) != 1) {
        setup_fail(cn, "exit pipeline");
        return;
    }
    while (!PQisBusy(cn->raw)) {
        PGresult *left = PQgetResult(cn->raw);
        if (!left) break;
        PQclear(left);
    }

    pg_pool *pool = cn->pool;
    cn->setup = PG_SETUP_NONE;
    cn->dead = false;
    cn->busy = false;
    cn->retry_at_ms = 0;
    cn->retry_backoff_ms = PG_RECONNECT_BACKOFF_MIN;
    setup_events(cn, LOOP_IN);
    fprintf(stderr, "pg[%d]: reconnected\n", cn->index);

    if (cn->role == PG_CONN_READ) {
        pool->read_live++;
        pg_sched_read_live_inc();
        pg_pool_dispatch_reads(pool);
    } else {
        pool->write_live++;
    }
}

static void setup_consume(pg_conn *cn) {
    if (!PQconsumeInput(cn->raw)) {
        setup_fail(cn, "setup input");
        return;
    }
    for (;;) {
        if (PQisBusy(cn->raw)) break;
        PGresult *r = PQgetResult(cn->raw);
        if (!r) {
            if (cn->setup == PG_SETUP_INIT) {
                setup_send_prepares(cn);
                return;
            }
            continue;           // pipeline separators between prepares
        }
        ExecStatusType st = PQresultStatus(r);
        if (st == PGRES_PIPELINE_SYNC) {
            PQclear(r);
            setup_ready(cn);
            return;
        }
        if (st != PGRES_COMMAND_OK) {
            fprintf(stderr, "pg[%d]: setup: %s", cn->index,
                    PQresultErrorMessage(r));
            PQclear(r);
            setup_fail(cn, "setup statement");
            return;
        }
        PQclear(r);
    }
    setup_events(cn, LOOP_IN);
}

static void setup_poll(pg_conn *cn) {
    PostgresPollingStatusType ps = PQconnectPoll(cn->raw);
    switch (ps) {
    case PGRES_POLLING_OK:
        setup_connected(cn);
        return;
    case PGRES_POLLING_FAILED:
        setup_fail(cn, "connect");
        return;
    case PGRES_POLLING_READING:
        setup_events(cn, LOOP_IN);
        return;
    case PGRES_POLLING_WRITING:
        setup_events(cn, LOOP_OUT);
        return;
    default:
        return;
    }
}

static void setup_connected(pg_conn *cn) {
    if (PQsetnonblocking(cn->raw, 1) != 0) {
        setup_fail(cn, "setnonblocking");
        return;
    }
    if (!PQsendQuery(cn->raw, PG_SESSION_INIT)) {
        setup_fail(cn, "session init send");
        return;
    }
    cn->setup = PG_SETUP_INIT;
    setup_events(cn, LOOP_IN);
}

void pg_conn_retry(pg_conn *cn) {
    if (!cn->dead || cn->setup != PG_SETUP_NONE) return;

    cn->setup = PG_SETUP_CONNECT;
    cn->raw = PQconnectStart(cn->pool->url);
    if (!cn->raw || PQstatus(cn->raw) == CONNECTION_BAD) {
        setup_fail(cn, "connect start");
        return;
    }
    int fd = PQsocket(cn->raw);
    if (fd < 0) {
        setup_fail(cn, "connect socket");
        return;
    }
    cn->ev = loop_add(cn->pool->loop, fd, LOOP_IN, pg_conn_event, cn);
    if (!cn->ev) {
        setup_fail(cn, "loop_add");
        return;
    }
    setup_poll(cn);
}

static void setup_event(pg_conn *cn, unsigned events) {
    if (events & LOOP_ERR) {
        setup_fail(cn, cn->setup == PG_SETUP_CONNECT ? "connect socket"
                                                     : "setup socket");
        return;
    }
    if (cn->setup == PG_SETUP_CONNECT) {
        setup_poll(cn);
        return;
    }
    setup_consume(cn);
}

static void pg_conn_event(void *user, loop_fd *self, unsigned events) {
    (void)self;
    pg_conn *cn = user;

    /* reconnect phases drive the fd until the conn is live again */
    if (cn->setup != PG_SETUP_NONE) {
        setup_event(cn, events);
        return;
    }
    if (cn->dead) return;

    if (events & LOOP_ERR) {
        pg_conn_fail(cn);
        return;
    }

    if (events & LOOP_OUT) {
        int rc = PQflush(cn->raw);
        if (rc < 0) {
            pg_conn_fail(cn);
            return;
        }
    }

    if (events & LOOP_IN) {
        if (!PQconsumeInput(cn->raw)) {
            pg_conn_fail(cn);
            return;
        }
        pg_conn_consume(cn);
        if (cn->dead) return;
    }

    if (cn->role == PG_CONN_READ) {
        pg_pool_dispatch_reads(cn->pool);
    } else if (!cn->busy && cn->head) {
        pg_conn_pump(cn);
    }
    if (!cn->dead) pg_conn_set_events(cn);
}
