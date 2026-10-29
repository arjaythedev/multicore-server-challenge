/* The drain: one process that owns every Postgres read connection for the whole box. Workers hand it reads
 * through shared-memory rings; one queue for all of them means fewer backends, bigger batches and no worker's
 * reads stuck behind another's busy connection.
 *
 * IPC_PG units are run as sent (pipelined Bind/Execute/Sync) and the backend's reply, through ReadyForQuery,
 * goes back to the worker byte for byte: the reply for one unit is contiguous on its connection, so it is
 * forwarded straight out of the receive buffer.
 *
 * IPC_PLAN reads wait for company and run as plans (planner.c), at most one per connection at a time. */
#include <errno.h>
#include <liburing.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "drain.h"
#include "ipc.h"
#include "pg_conn.h"
#include "plan.h"
#include "worker.h"

#define RING_ENTRIES 1024
#define PG_RECV_MIN 65536

enum { D_EVENTFD = 1, D_PG_RECV, D_PG_SEND, D_TIMER };

struct unit {
    struct unit *next;
    struct plan *plan;  /* a plan's phase, or NULL for a worker's unit */
    int worker;
    uint64_t token;
    uint32_t len;  /* bytes, for units waiting in the drain */
    char *bytes;
};

struct dconn {
    int fd;
    struct buf out, sending, in;
    bool send_busy, plan_active;
    int64_t plan_t0;              /* when the running plan started */
    size_t sent;
    size_t reply_start;           /* start of the head unit's reply in `in` */
    struct unit *head, *tail;     /* units in flight */
    uint32_t inflight;
};

/* A reply that didn't fit in its worker's ring yet. */
struct pending_reply {
    struct pending_reply *next;
    uint64_t token;
    uint32_t kind, len;
    char data[];
};

struct drain {
    struct io_uring ring;
    struct dconn *pg;
    int npg;
    unsigned rr;
    struct unit *wait, *wait_tail;     /* units over the pipeline cap */
    struct unit *free_units;
    uint64_t efd_val;
    bool *wake;                        /* workers with new replies this iteration */
    struct pending_reply **overflow, **overflow_tail;
    bool timer_armed;
    struct __kernel_timespec timer_ts;
    int64_t ewma_plan_us;              /* how long a plan takes, start to answer (EWMA, 1/4 weight) */
};

static struct drain D;

static int64_t mono_us(void);

static struct io_uring_sqe *dsqe(void) {
    struct io_uring_sqe *s = io_uring_get_sqe(&D.ring);
    while (unlikely(!s)) {
        io_uring_submit(&D.ring);
        s = io_uring_get_sqe(&D.ring);
    }
    return s;
}

static void arm_eventfd(void) {
    struct io_uring_sqe *s = dsqe();
    io_uring_prep_read(s, ipc.drain_efd, &D.efd_val, sizeof D.efd_val, 0);
    io_uring_sqe_set_data64(s, D_EVENTFD);
}

static void arm_recv(struct dconn *c) {
    buf_reserve(&c->in, PG_RECV_MIN);
    struct io_uring_sqe *s = dsqe();
    io_uring_prep_recv(s, c->fd, c->in.p + c->in.len, c->in.cap - c->in.len, 0);
    io_uring_sqe_set_data64(s, (uint64_t)(uintptr_t)c | D_PG_RECV);
}

static void start_send(struct dconn *c) {
    struct buf t = c->sending;
    c->sending = c->out;
    c->out = t;
    c->out.len = 0;
    c->sent = 0;
    c->send_busy = true;
    struct io_uring_sqe *s = dsqe();
    io_uring_prep_send(s, c->fd, c->sending.p, c->sending.len, MSG_NOSIGNAL);
    io_uring_sqe_set_data64(s, (uint64_t)(uintptr_t)c | D_PG_SEND);
}

/* ---- replies to workers ---- */

static bool push_reply(int worker, uint32_t kind, uint64_t token, const void *data, uint32_t len) {
    void *dst = ipc_reserve(ipc.to_worker[worker], kind, len, token);
    if (!dst) return false;
    memcpy(dst, data, len);
    ipc_commit(ipc.to_worker[worker]);
    D.wake[worker] = true;
    return true;
}

static void reply(int worker, uint32_t kind, uint64_t token, const void *data, uint32_t len) {
    if (!D.overflow[worker] && push_reply(worker, kind, token, data, len)) return;
    struct pending_reply *p = xmalloc(sizeof *p + len);
    p->next = NULL;
    p->token = token;
    p->kind = kind;
    p->len = len;
    memcpy(p->data, data, len);
    if (D.overflow[worker]) D.overflow_tail[worker]->next = p;
    else D.overflow[worker] = p;
    D.overflow_tail[worker] = p;
}

void drain_reply(int worker, uint32_t kind, uint64_t token, const void *data, uint32_t len) {
    reply(worker, kind, token, data, len);
}

static void retry_overflow(void) {
    for (int i = 0; i < ipc.nworkers; i++) {
        while (D.overflow[i]) {
            struct pending_reply *p = D.overflow[i];
            if (!push_reply(i, p->kind, p->token, p->data, p->len)) break;
            D.overflow[i] = p->next;
            free(p);
        }
    }
}

/* ---- units ---- */

static void send_unit(struct dconn *c, struct unit *u, const void *bytes, uint32_t len) {
    buf_put(&c->out, bytes, len);
    u->next = NULL;
    if (c->tail) c->tail->next = u;
    else c->head = u;
    c->tail = u;
    c->inflight++;
}

static struct unit *unit_new(int worker, uint64_t token) {
    struct unit *u = D.free_units;
    if (u) D.free_units = u->next;
    else u = xcalloc(1, sizeof *u);
    u->next = NULL;
    u->plan = NULL;
    u->worker = worker;
    u->token = token;
    u->bytes = NULL;
    u->len = 0;
    return u;
}

static void unit_free(struct unit *u) {
    free(u->bytes);
    u->bytes = NULL;
    u->next = D.free_units;
    D.free_units = u;
}

static void take_unit(int worker, uint64_t token, const void *bytes, uint32_t len) {
    struct unit *u = unit_new(worker, token);
    struct dconn *best = NULL;
    for (int i = 0; i < D.npg; i++) {
        struct dconn *c = &D.pg[(D.rr + (unsigned)i) % (unsigned)D.npg];
        if (!best || c->inflight < best->inflight) best = c;
    }
    D.rr++;
    if (best->inflight < cfg.pg_pipeline && !D.wait) {
        send_unit(best, u, bytes, len);
        return;
    }
    u->bytes = xmalloc(len);
    memcpy(u->bytes, bytes, len);
    u->len = len;
    if (D.wait_tail) D.wait_tail->next = u;
    else D.wait = u;
    D.wait_tail = u;
}

static void refill(struct dconn *c) {
    while (D.wait && c->inflight < cfg.pg_pipeline) {
        struct unit *u = D.wait;
        D.wait = u->next;
        if (!D.wait) D.wait_tail = NULL;
        send_unit(c, u, u->bytes, u->len);
        free(u->bytes);
        u->bytes = NULL;
    }
}

static void read_rings(void) {
    for (int i = 0; i < ipc.nworkers; i++) {
        struct ring *r = ipc.to_drain[i];
        const struct ipc_hdr *m;
        bool any = false;
        while ((m = ipc_peek(r))) {
            any = true;
            if (m->kind == IPC_PG) take_unit(i, m->token, m + 1, m->len);
            else if (m->kind == IPC_PLAN) planner_add(i, m->token, (const struct plan_req *)(m + 1), m->len);
            else die("drain: unknown message kind %u", m->kind);
        }
        if (any) ipc_release(r);
    }
}

/* ---- Postgres replies ---- */

static void on_recv(struct dconn *c, int res) {
    if (res <= 0) die("drain: postgres connection lost (%s)", res ? strerror(-res) : "EOF");
    c->in.len += (size_t)res;
    size_t pos = c->reply_start;
    for (;;) {
        struct pg_msg m;
        ptrdiff_t k = pg_next((const uint8_t *)c->in.p + pos, c->in.len - pos, &m);
        if (k < 0) die("drain: postgres protocol error");
        if (k == 0) break;
        pos += (size_t)k;
        struct unit *u = c->head;
        if (unlikely(!u)) die("drain: reply without a unit");
        if (u->plan) {
            /* A plan consumes each message as it comes (a worker's reply is forwarded whole at the end). */
            bool done;
            bool ended = planner_msg(u->plan, &m, &c->out, &done);
            c->reply_start = pos;
            if (!ended) continue;
            /* The phase ended: either the plan is answered, or its next phase is queued on this connection. */
            c->head = u->next;
            if (!c->head) c->tail = NULL;
            c->inflight--;
            if (done) {
                c->plan_active = false;
                int64_t took = mono_us() - c->plan_t0;
                D.ewma_plan_us = D.ewma_plan_us ? (3 * D.ewma_plan_us + took) / 4 : took;
                unit_free(u);
            } else {
                u->next = NULL;
                if (c->tail) c->tail->next = u;
                else c->head = u;
                c->tail = u;
                c->inflight++;
            }
            c->reply_start = pos;
            refill(c);
            continue;
        }
        if (m.type != 'Z') continue;
        c->head = u->next;
        if (!c->head) c->tail = NULL;
        c->inflight--;
        reply(u->worker, IPC_PG, u->token, c->in.p + c->reply_start, (uint32_t)(pos - c->reply_start));
        unit_free(u);
        c->reply_start = pos;
        refill(c);
    }
    /* Keep the unfinished reply; drop what was forwarded. */
    memmove(c->in.p, c->in.p + c->reply_start, c->in.len - c->reply_start);
    c->in.len -= c->reply_start;
    c->reply_start = 0;
    arm_recv(c);
}

static void on_send(struct dconn *c, int res) {
    if (res < 0) die("drain: postgres send: %s", strerror(-res));
    c->sent += (size_t)res;
    if (c->sent < c->sending.len) {
        struct io_uring_sqe *s = dsqe();
        io_uring_prep_send(s, c->fd, c->sending.p + c->sent, c->sending.len - c->sent, MSG_NOSIGNAL);
        io_uring_sqe_set_data64(s, (uint64_t)(uintptr_t)c | D_PG_SEND);
        return;
    }
    c->sending.len = 0;
    c->send_busy = false;
}

static int64_t mono_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static void arm_timer(int64_t us) {
    if (D.timer_armed) return;
    D.timer_armed = true;
    D.timer_ts.tv_sec = us / 1000000;
    D.timer_ts.tv_nsec = (us % 1000000) * 1000;
    struct io_uring_sqe *s = dsqe();
    io_uring_prep_timeout(s, &D.timer_ts, 0, 0);
    io_uring_sqe_set_data64(s, D_TIMER);
}

/* How long the oldest queued request may wait for company before a plan starts. With plan_pace the wait follows
 * the load: a plan's typical duration times the share of the other connections that are free. When every other
 * connection is busy it is zero (a backend is free and work is queued: start now); when most are free it is close
 * to one plan's duration, so plans start staggered and each takes a full batch instead of a handful. Capped by
 * plan_wait_us, which is the fixed wait without plan_pace. */
static int64_t plan_wait(void) {
    if (!cfg.plan_pace) return cfg.plan_wait_us;
    int free_n = 0;
    for (int i = 0; i < D.npg; i++) free_n += !D.pg[i].plan_active;
    if (free_n <= 1) return 0;
    int64_t w = D.ewma_plan_us * (free_n - 1) / D.npg;
    return w < cfg.plan_wait_us ? w : cfg.plan_wait_us;
}

/* Starts plans while requests are due and a connection has no plan running. */
static void schedule_plans(void) {
    int64_t now = mono_us();
    for (;;) {
        int64_t due = planner_due_in(now, plan_wait());
        if (due < 0) return;
        if (due > 0) {
            arm_timer(due);
            return;
        }
        struct dconn *best = NULL;
        for (int i = 0; i < D.npg; i++) {
            struct dconn *c = &D.pg[i];
            if (!c->plan_active && (!best || c->inflight < best->inflight)) best = c;
        }
        if (!best) return;  /* rescheduled when a plan finishes */
        struct unit *u = unit_new(-1, 0);
        u->plan = planner_start(&best->out);
        if (!u->plan) {
            unit_free(u);
            return;
        }
        best->plan_active = true;
        best->plan_t0 = now;
        u->next = NULL;
        if (best->tail) best->tail->next = u;
        else best->head = u;
        best->tail = u;
        best->inflight++;
    }
}

void drain_run(void) {
    char err[256];
    D.npg = cfg.read_conns;
    D.pg = xcalloc((size_t)D.npg, sizeof *D.pg);
    for (int i = 0; i < D.npg; i++) {
        struct dconn *c = &D.pg[i];
        c->fd = pg_open(&cfg.pg, err, sizeof err);
        if (c->fd < 0) die("drain: postgres: %s", err);
        buf_init(&c->out, 65536);
        buf_init(&c->sending, 65536);
        buf_init(&c->in, 2 * PG_RECV_MIN);
    }
    D.wake = xcalloc((size_t)ipc.nworkers, sizeof *D.wake);
    D.overflow = xcalloc((size_t)ipc.nworkers, sizeof *D.overflow);
    D.overflow_tail = xcalloc((size_t)ipc.nworkers, sizeof *D.overflow_tail);

    struct io_uring_params p = {0};
    p.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN;
    int rc = io_uring_queue_init_params(RING_ENTRIES, &D.ring, &p);
    if (rc == -EINVAL) rc = io_uring_queue_init(RING_ENTRIES, &D.ring, 0);
    if (rc < 0) die("drain: io_uring_queue_init: %s", strerror(-rc));

    planner_init();
    arm_eventfd();
    for (int i = 0; i < D.npg; i++) arm_recv(&D.pg[i]);
    fprintf(stderr, "drain: %d postgres read connections\n", D.npg);

    for (;;) {
        for (int i = 0; i < D.npg; i++) {
            struct dconn *c = &D.pg[i];
            if (!c->send_busy && c->out.len) start_send(c);
        }
        for (int i = 0; i < ipc.nworkers; i++)
            if (D.wake[i]) {
                D.wake[i] = false;
                ipc_wake(ipc.worker_efd[i]);
            }
        rc = io_uring_submit_and_wait(&D.ring, 1);
        if (rc < 0 && rc != -EINTR && rc != -EBUSY && rc != -EAGAIN) die("drain: io_uring: %s", strerror(-rc));
        unsigned head, n = 0;
        struct io_uring_cqe *cqe;
        io_uring_for_each_cqe(&D.ring, head, cqe) {
            uint64_t ud = io_uring_cqe_get_data64(cqe);
            switch (ud & 7) {
            case D_EVENTFD:
                read_rings();
                arm_eventfd();
                break;
            case D_PG_RECV:
                on_recv((struct dconn *)(uintptr_t)(ud & ~(uint64_t)7), cqe->res);
                break;
            case D_PG_SEND:
                on_send((struct dconn *)(uintptr_t)(ud & ~(uint64_t)7), cqe->res);
                break;
            case D_TIMER:
                D.timer_armed = false;
                break;
            }
            n++;
        }
        io_uring_cq_advance(&D.ring, n);
        schedule_plans();
        retry_overflow();
    }
}
