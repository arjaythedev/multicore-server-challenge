/* The worker's event loop. Client sockets: one multishot accept on the worker's own SO_REUSEPORT listener, one
 * multishot receive per connection into the ring's provided buffers (an idle connection owns no buffer), and one
 * send per response. Postgres sockets: one plain receive each into a growable buffer, and sends of everything
 * queued since the last loop iteration, so units from many requests leave in one write. */
#include "worker.h"

#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/eventfd.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "ipc.h"
#include "json_out.h"
#include "pg_conn.h"
#include "plan.h"

#define BGID 1
#define RING_ENTRIES 4096
#define CQ_ENTRIES 65536
#define PG_RECV_MIN 65536

struct config cfg;

struct io_uring_sqe *sqe_get(struct worker *w) {
    struct io_uring_sqe *s = io_uring_get_sqe(&w->ring);
    while (unlikely(!s)) {
        io_uring_submit(&w->ring);
        s = io_uring_get_sqe(&w->ring);
    }
    return s;
}

static int64_t mono_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static double wall_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

/* ---- requests ---- */

struct req *req_alloc(struct worker *w, int fd, uint32_t gen) {
    struct req *r = w->free_reqs;
    if (r) {
        w->free_reqs = r->next;
    } else {
        r = xcalloc(1, sizeof *r);
        r->w = w;
        buf_init(&r->q, 1024);
        buf_init(&r->resp, 4096);
    }
    r->next = NULL;
    r->fn = NULL;
    r->fd = fd;
    r->gen = gen;
    r->keep_alive = true;
    r->pg_error = r->write = r->solo = false;
    r->merge = M_NONE;
    r->q_split = 0;
    r->step = 0;
    r->nexec = 0;
    r->stmt = 0;
    r->sqlstate[0] = 0;
    r->viewer = 0;
    memset(r->n, 0, sizeof r->n);
    r->rows = 0;
    r->data = NULL;
    r->data_len = r->data_cap = 0;
    memset(r->s, 0, sizeof r->s);
    memset(r->sl, 0, sizeof r->sl);
    r->saved = NULL;
    r->saved_len = 0;
    r->q.len = 0;
    r->resp.len = 0;
    r->bc.kind = 0;
    return r;
}

static void req_free(struct req *r) {
    struct worker *w = r->w;
    free(r->data);
    free(r->saved);
    r->data = r->saved = NULL;
    /* Keep pooled buffers small: an occasional big list page shouldn't pin memory forever. */
    if (r->resp.cap > 65536) {
        buf_free(&r->resp);
        buf_init(&r->resp, 4096);
    }
    if (r->q.cap > 65536) {
        buf_free(&r->q);
        buf_init(&r->q, 1024);
    }
    r->next = w->free_reqs;
    w->free_reqs = r;
}

/* ---- client connections ---- */

static void provide_buffer(struct worker *w, unsigned bid) {
    struct io_uring_sqe *s = sqe_get(w);
    io_uring_prep_provide_buffers(s, w->bufs + (size_t)bid * w->bufsz, (int)w->bufsz, 1, BGID, (int)bid);
    s->flags |= IOSQE_CQE_SKIP_SUCCESS;
    io_uring_sqe_set_data64(s, OP_IGNORE);
}

static void arm_recv(struct worker *w, int fd) {
    struct hconn *c = &w->conns[fd];
    struct io_uring_sqe *s = sqe_get(w);
    io_uring_prep_recv_multishot(s, fd, NULL, 0, 0);
    s->flags |= IOSQE_BUFFER_SELECT | (w->direct ? IOSQE_FIXED_FILE : 0);
    s->buf_group = BGID;
    io_uring_sqe_set_data64(s, UD_MAKE_CONN(fd, c->gen, OP_RECV));
    c->recv_armed = true;
}

static void arm_accept(struct worker *w) {
    struct io_uring_sqe *s = sqe_get(w);
    if (w->direct) io_uring_prep_multishot_accept_direct(s, w->listen_fd, NULL, NULL, 0);
    else io_uring_prep_multishot_accept(s, w->listen_fd, NULL, NULL, SOCK_CLOEXEC);
    io_uring_sqe_set_data64(s, OP_ACCEPT);
}

static void conn_close(struct worker *w, int fd) {
    struct hconn *c = &w->conns[fd];
    if (!c->open) return;
    c->open = false;
    c->gen = (c->gen + 1) & GEN_MASK;
    if ((uint32_t)fd < ipc.live_n) atomic_store_explicit(&ipc.live[w->id][fd], c->gen, memory_order_relaxed);
    c->busy = c->want_recv = false;
    free(c->pend);
    c->pend = NULL;
    c->plen = c->pcap = 0;
    if (w->direct) {
        /* Both go through the ring after anything already queued for this slot, and an operation's file is
         * fixed when it is issued, so the slot cannot be reused under an earlier send. The shutdown ends the
         * multishot receive, which keeps the socket alive until then. */
        struct io_uring_sqe *s = sqe_get(w);
        io_uring_prep_shutdown(s, fd, SHUT_RDWR);
        s->flags |= IOSQE_FIXED_FILE | IOSQE_CQE_SKIP_SUCCESS;
        io_uring_sqe_set_data64(s, OP_QUIET);
        s = sqe_get(w);
        io_uring_prep_close_direct(s, (unsigned)fd);
        s->flags |= IOSQE_CQE_SKIP_SUCCESS;
        io_uring_sqe_set_data64(s, OP_IGNORE);
        return;
    }
    /* Queued but unsubmitted operations on this fd must reach the kernel before the number can be reused. */
    io_uring_submit(&w->ring);
    shutdown(fd, SHUT_RDWR);  /* ends the multishot receive, which holds its own file reference */
    close(fd);
}

static void pend_append(struct hconn *c, const char *p, size_t n) {
    if (c->pcap - c->plen < n) {
        uint32_t cap = c->pcap ? c->pcap : 1024;
        while (cap - c->plen < n) cap *= 2;
        c->pend = xrealloc(c->pend, cap);
        c->pcap = cap;
    }
    memcpy(c->pend + c->plen, p, n);
    c->plen += (uint32_t)n;
}

static void bad_request(struct worker *w, int fd, ptrdiff_t why) {
    struct hconn *c = &w->conns[fd];
    struct req *r = req_alloc(w, fd, c->gen);
    c->busy = true;
    r->keep_alive = false;
    c->plen = 0;
    req_error(r, why == HTTP_TOO_LARGE ? 413 : 400, why == HTTP_TOO_LARGE ? "request too large" : "bad request");
}

/* Parses and dispatches buffered requests while the connection is idle. */
static void drain_pending(struct worker *w, int fd) {
    struct hconn *c = &w->conns[fd];
    while (c->open && !c->busy && c->plen) {
        struct http_req hr;
        ptrdiff_t k = http_parse(c->pend, c->plen, &hr);
        if (k == 0) return;
        if (k < 0) {
            bad_request(w, fd, k);
            return;
        }
        c->busy = true;
        dispatch(w, fd, c->gen, &hr);
        arena_reset(&w->scratch);
        memmove(c->pend, c->pend + k, c->plen - (size_t)k);
        c->plen -= (uint32_t)k;
    }
    if (c->open && c->plen == 0 && c->pcap > 65536) {
        free(c->pend);
        c->pend = NULL;
        c->pcap = 0;
    }
}

static void on_data(struct worker *w, int fd, const char *p, size_t n) {
    struct hconn *c = &w->conns[fd];
    if (c->busy || c->plen) {
        pend_append(c, p, n);
        if (!c->busy) drain_pending(w, fd);
        return;
    }
    /* Fast path: the whole request is in this buffer; parse it where it lies. */
    struct http_req hr;
    ptrdiff_t k = http_parse(p, n, &hr);
    if (k < 0) {
        bad_request(w, fd, k);
        return;
    }
    if (k > 0) {
        c->busy = true;
        dispatch(w, fd, c->gen, &hr);
        arena_reset(&w->scratch);
    }
    if ((size_t)k < n && c->open) pend_append(c, p + k, n - (size_t)k);
}

static void on_accept(struct worker *w, struct io_uring_cqe *cqe) {
    if (cqe->res >= 0) {
        int fd = cqe->res;
        if ((uint32_t)fd >= w->nconns) {
            if (!w->direct) close(fd);  /* a direct slot is always inside the table, which is nconns long */
        } else {
            struct hconn *c = &w->conns[fd];
            c->open = true;
            c->busy = c->want_recv = false;
            c->plen = 0;
            arm_recv(w, fd);
        }
    } else if (cqe->res != -EAGAIN && cqe->res != -EINTR && cqe->res != -ECONNABORTED) {
        fprintf(stderr, "worker %d: accept: %s\n", w->id, strerror(-cqe->res));
    }
    if (!(cqe->flags & IORING_CQE_F_MORE)) arm_accept(w);
}

static void on_recv(struct worker *w, struct io_uring_cqe *cqe) {
    uint64_t ud = io_uring_cqe_get_data64(cqe);
    int fd = UD_FD(ud);
    struct hconn *c = &w->conns[fd];
    bool live = c->open && c->gen == UD_GEN(ud);
    bool more = cqe->flags & IORING_CQE_F_MORE;

    if (cqe->flags & IORING_CQE_F_BUFFER) {
        unsigned bid = cqe->flags >> IORING_CQE_BUFFER_SHIFT;
        if (live && cqe->res > 0) on_data(w, fd, w->bufs + (size_t)bid * w->bufsz, (size_t)cqe->res);
        provide_buffer(w, bid);
    }
    if (!live || more) return;
    c->recv_armed = false;
    if (cqe->res == -ENOBUFS) {
        /* Out of receive buffers: retry once some come back. */
        if (!c->want_recv) {
            c->want_recv = true;
            w->norecv[w->norecv_len++] = fd;
        }
    } else if (cqe->res > 0) {
        if (c->open) arm_recv(w, fd);  /* multishot ended for another reason (e.g. CQ overflow) */
    } else {
        conn_close(w, fd);  /* EOF or error */
    }
}

static void rearm_starved(struct worker *w) {
    uint32_t n = w->norecv_len;
    w->norecv_len = 0;
    for (uint32_t i = 0; i < n; i++) {
        int fd = w->norecv[i];
        struct hconn *c = &w->conns[fd];
        if (c->open && c->want_recv && !c->recv_armed) {
            c->want_recv = false;
            arm_recv(w, fd);
        }
    }
}

/* ACK delay: after a response, TCP_QUICKACK off on its socket through the ring (a socket command, kernel 6.7+), so
 * the next request's ACK leaves with that request's response instead of as a packet of its own. The kernel picks
 * quick or delayed ACK as a request arrives and leaves delayed mode whenever its delayed-ACK timer fires (a response
 * slower than about 40 ms), so this goes out after every response. Only a failure posts a completion; on a kernel
 * without the command the worker makes the setsockopt call itself from then on. */
static const int quickack_off __attribute__((aligned(8))) = 0;
#define ACK_UD UD_MAKE_PTR(&quickack_off, OP_QUIET)
static bool ack_delay, ack_syscall;

/* SOCKET_URING_OP_SETSOCKOPT in the kernel's uapi (6.7+). liburing 2.5's header predates it, and its
 * io_uring_prep_cmd_sock drops level, optname and optval, so the fields are set here by their uapi places: level and
 * optname share the 64-bit addr word, optlen is the file_index word, optval the addr3 word. */
#define URING_SETSOCKOPT 3

static void delay_ack(struct worker *w, int fd) {
    if (ack_syscall) {
        if (!w->direct) setsockopt(fd, IPPROTO_TCP, TCP_QUICKACK, &quickack_off, sizeof quickack_off);
        return;
    }
    struct io_uring_sqe *s = sqe_get(w);
    io_uring_prep_rw(IORING_OP_URING_CMD, s, fd, NULL, 0, 0);
    s->cmd_op = URING_SETSOCKOPT;
    s->addr = (uint64_t)(uint32_t)IPPROTO_TCP | (uint64_t)(uint32_t)TCP_QUICKACK << 32;
    s->file_index = sizeof quickack_off;
    s->addr3 = (uint64_t)(uintptr_t)&quickack_off;
    s->flags |= IOSQE_CQE_SKIP_SUCCESS;
    if (w->direct) s->flags |= IOSQE_FIXED_FILE;
    io_uring_sqe_set_data64(s, ACK_UD);
}

static void send_resp(struct req *r) {
    struct io_uring_sqe *s = sqe_get(r->w);
    size_t off = r->resp_off + r->resp_sent;
    io_uring_prep_send(s, r->fd, r->resp.p + off, r->resp.len - off, MSG_NOSIGNAL);
    if (r->w->direct) s->flags |= IOSQE_FIXED_FILE;
    io_uring_sqe_set_data64(s, UD_MAKE_PTR(r, OP_SEND));
}

void req_respond(struct req *r, int status) {
    struct hconn *c = &r->w->conns[r->fd];
    if (!c->open || c->gen != r->gen) {
        req_free(r);
        return;
    }
    r->resp_off = http_finish(&r->resp, status, r->keep_alive);
    r->resp_sent = 0;
    send_resp(r);
}

void req_error(struct req *r, int status, const char *msg) {
    http_begin(&r->resp);
    buf_lit(&r->resp, "{\"errors\":{\"body\":[");
    json_str(&r->resp, msg, strlen(msg));
    buf_lit(&r->resp, "]}}");
    req_respond(r, status);
}

static void on_send(struct worker *w, struct io_uring_cqe *cqe) {
    struct req *r = UD_PTR(io_uring_cqe_get_data64(cqe));
    int fd = r->fd;
    struct hconn *c = &w->conns[fd];
    bool live = c->open && c->gen == r->gen;
    if (cqe->res < 0) {
        req_free(r);
        if (live) conn_close(w, fd);
        return;
    }
    r->resp_sent += (size_t)cqe->res;
    if (r->resp_off + r->resp_sent < r->resp.len) {
        if (live) send_resp(r);
        else req_free(r);
        return;
    }
    bool keep = r->keep_alive;
    req_free(r);
    if (!live) return;
    c->busy = false;
    if (!keep) {
        conn_close(w, fd);
        return;
    }
    if (ack_delay) delay_ack(w, fd);
    if (c->plen) drain_pending(w, fd);
}

/* ---- Postgres connections ---- */

static void pg_arm_recv(struct worker *w, struct pgc *pc) {
    char *dst = buf_reserve(&pc->in, PG_RECV_MIN);
    struct io_uring_sqe *s = sqe_get(w);
    io_uring_prep_recv(s, pc->fd, dst, pc->in.cap - pc->in.len, 0);
    io_uring_sqe_set_data64(s, UD_MAKE_PTR(pc, OP_PG_RECV));
}

static void pg_start_send(struct worker *w, struct pgc *pc) {
    struct buf t = pc->sending;
    pc->sending = pc->out;
    pc->out = t;
    pc->out.len = 0;
    pc->sent = 0;
    pc->send_busy = true;
    struct io_uring_sqe *s = sqe_get(w);
    io_uring_prep_send(s, pc->fd, pc->sending.p, pc->sending.len, MSG_NOSIGNAL);
    io_uring_sqe_set_data64(s, UD_MAKE_PTR(pc, OP_PG_SEND));
}

static void pg_start_group(struct worker *w, struct pgc *pc);

/* Microseconds until the queued writes should go out as a group: at once for a solo write (it runs alone, so waiting
 * gains nothing) or a full group, otherwise once the oldest has waited write_wait_us for company. */
static int64_t write_due_in(const struct worker *w, int64_t now) {
    const struct req *r = w->wait_write;
    if (r->solo || w->wait_write_n >= cfg.write_group) return 0;
    int64_t due = r->t_us + cfg.write_wait_us - now;
    return due > 0 ? due : 0;
}

#define TIMER_UD(w) UD_MAKE_PTR(&(w)->timer_ts, OP_IGNORE)

static void arm_write_timer(struct worker *w, int64_t us) {
    if (w->timer_armed) return;
    w->timer_armed = true;
    w->timer_ts.tv_sec = us / 1000000;
    w->timer_ts.tv_nsec = (us % 1000000) * 1000;
    struct io_uring_sqe *s = sqe_get(w);
    io_uring_prep_timeout(s, &w->timer_ts, 0, 0);
    io_uring_sqe_set_data64(s, TIMER_UD(w));
}

static void pg_flush_all(struct worker *w) {
    if (w->wait_write) {
        int64_t now = mono_us();
        for (int i = w->nread; i < w->npg && w->wait_write && write_due_in(w, now) == 0; i++)
            if (!w->pg[i].head) pg_start_group(w, &w->pg[i]);
        if (w->wait_write) {
            int64_t due = write_due_in(w, now);
            if (due > 0) arm_write_timer(w, due);
        }
    }
    while (w->dirty) {
        struct pgc *pc = w->dirty;
        w->dirty = pc->next_dirty;
        pc->dirty = false;
        if (!pc->send_busy && pc->out.len) pg_start_send(w, pc);
    }
}

static void mark_dirty(struct pgc *pc) {
    if (!pc->dirty) {
        pc->dirty = true;
        pc->next_dirty = pc->w->dirty;
        pc->w->dirty = pc;
    }
}

/* Sends a request's unit from byte `from` of q (0: all of it; q_split: what follows its write statement). */
static void emit_unit(struct pgc *pc, struct req *r, uint32_t from) {
    if (from >= r->q.len) return;
    buf_put(&pc->out, r->q.p + from, r->q.len - from);
    pc->steps[pc->nsteps++] = (struct wstep){r, 0, 0};
}

static const enum stmt merge_stmt[M_KINDS] = {
    [M_FAV] = S_M_FAVORITE, [M_UNFAV] = S_M_UNFAVORITE, [M_FOLLOW] = S_M_FOLLOW,
    [M_UNFOLLOW] = S_M_UNFOLLOW, [M_COMMENT] = S_M_COMMENT,
};

static void bind_i64s(struct pg_bind *pb, struct req **rs, uint32_t n) {
    size_t at;
    pg_bind_array_begin(pb, OID_INT8, &at);
    for (uint32_t i = 0; i < n; i++) pg_bind_array_i64(pb, rs[i]->viewer);
    pg_bind_array_end(pb, at, n, false);
}

static void bind_texts(struct pg_bind *pb, struct req **rs, uint32_t n, int slot) {
    size_t at;
    pg_bind_array_begin(pb, OID_TEXT, &at);
    for (uint32_t i = 0; i < n; i++) pg_bind_array_text(pb, rs[i]->s[slot], rs[i]->sl[slot]);
    pg_bind_array_end(pb, at, n, false);
}

/* One statement for every request of the kind in the segment; their rows come back by ordinal (pc->run). */
static void emit_merged(struct pgc *pc, int kind, struct req **seg, uint32_t nseg) {
    uint32_t start = pc->nrun;
    for (uint32_t i = 0; i < nseg; i++)
        if (seg[i]->merge == kind) pc->run[pc->nrun++] = seg[i];
    struct req **rs = pc->run + start;
    uint32_t n = pc->nrun - start;
    struct pg_bind pb;
    pg_bind_begin(&pb, &pc->out, stmt_names[merge_stmt[kind]]);
    if (kind == M_COMMENT) {
        bind_texts(&pb, rs, n, 0);
        bind_i64s(&pb, rs, n);
        bind_texts(&pb, rs, n, 1);
    } else {
        bind_i64s(&pb, rs, n);
        bind_texts(&pb, rs, n, 0);
    }
    pg_bind_end(&pb);
    pg_execute(&pc->out);
    pc->steps[pc->nsteps++] = (struct wstep){NULL, start, n};
}

/* A segment's merged statements (kinds with two or more requests) go first, then every request's unit in arrival
 * order: the rest of it for merged requests (the favorite read-back), all of it for the others. */
static void emit_segment(struct pgc *pc, struct req **seg, uint32_t nseg) {
    uint32_t count[M_KINDS] = {0};
    for (uint32_t i = 0; i < nseg; i++) count[seg[i]->merge]++;
    for (int k = 1; k < M_KINDS; k++)
        if (count[k] >= 2) emit_merged(pc, k, seg, nseg);
    for (uint32_t i = 0; i < nseg; i++) emit_unit(pc, seg[i], count[seg[i]->merge] >= 2 ? seg[i]->q_split : 0);
}

/* Whether r's viewer already has a write of another kind in the segment: merging would reorder the two. */
static bool seg_conflict(struct req **seg, uint32_t nseg, const struct req *r) {
    for (uint32_t i = 0; i < nseg; i++)
        if (seg[i]->viewer == r->viewer && seg[i]->merge != r->merge) return true;
    return false;
}

/* Writes: an idle write connection takes the queued writes (up to write_group, or one solo write) and sends
 * them as one transaction ended by one Sync, so one WAL flush commits them all. Every response still waits
 * for that ReadyForQuery (rule 6).
 *
 * With write_merge the group is cut into segments: runs of favorites, unfavorites, follows, unfollows and new
 * comments. Each kind in a segment goes as one statement over arrays (sql.c S_M_*), followed by each request's
 * own read-back. Any other write ends the segment and keeps its place, and so does a viewer coming back with
 * another kind of write, so no user's writes change order. */
static void pg_start_group(struct worker *w, struct pgc *pc) {
    uint32_t n = 0, nseg = 0;
    pc->group_failed = false;
    pc->nsteps = pc->cur = pc->nrun = 0;
    while (w->wait_write && n < cfg.write_group) {
        struct req *r = w->wait_write;
        if (n && r->solo) break;
        w->wait_write = r->next;
        w->wait_write_n--;
        r->next = NULL;
        r->stmt = 0;
        r->pg_error = false;
        r->sqlstate[0] = 0;
        if (pc->tail) pc->tail->next = r;
        else pc->head = r;
        pc->tail = r;
        n++;
        if (cfg.write_merge && r->merge != M_NONE && !r->solo) {
            if (seg_conflict(pc->seg, nseg, r)) {
                emit_segment(pc, pc->seg, nseg);
                nseg = 0;
            }
            pc->seg[nseg++] = r;
        } else {
            emit_segment(pc, pc->seg, nseg);
            nseg = 0;
            emit_unit(pc, r, 0);
        }
        if (r->solo) break;
    }
    emit_segment(pc, pc->seg, nseg);
    if (!w->wait_write) w->wait_write_tail = NULL;
    pg_sync(&pc->out);
    pc->inflight = n;
    mark_dirty(pc);
}

static bool to_drain(struct worker *w, struct req *r) {
    struct ring *ring = ipc.to_drain[w->id];
    void *dst = ipc_reserve(ring, r->ipc_kind, (uint32_t)r->q.len, (uint64_t)(uintptr_t)r);
    if (!dst) return false;
    memcpy(dst, r->q.p, r->q.len);
    ipc_commit(ring);
    w->wake_drain = true;
    return true;
}

void unit_submit(struct req *r, bool write) {
    struct worker *w = r->w;
    r->write = write;
    r->stmt = 0;
    r->pg_error = false;
    r->sqlstate[0] = 0;
    r->next = NULL;

    if (write) {
        /* Queued; pg_flush_all starts a group on an idle write connection once this batch of completions has
         * been handled, so every write that arrived in it shares the commit. */
        r->resp_mark = r->resp.len;
        r->t_us = mono_us();
        if (w->wait_write_tail) w->wait_write_tail->next = r;
        else w->wait_write = r;
        w->wait_write_tail = r;
        w->wait_write_n++;
        return;
    }

    /* Reads go to the drain process; if its ring is full they wait here, in order. */
    pg_sync(&r->q);
    r->ipc_kind = IPC_PG;
    if (!w->wait_read && to_drain(w, r)) return;
    if (w->wait_read_tail) w->wait_read_tail->next = r;
    else w->wait_read = r;
    w->wait_read_tail = r;
}

/* A planned read: the drain batches it with others and answers with the finished body. */
void plan_submit(struct req *r, int kind, int filter, int64_t limit, int64_t offset, const char *key, uint32_t keylen) {
    struct worker *w = r->w;
    r->q.len = 0;
    struct plan_req *pr = (struct plan_req *)buf_reserve(&r->q, sizeof *pr + keylen);
    memset(pr, 0, sizeof *pr);
    pr->kind = (uint8_t)kind;
    pr->filter = (uint8_t)filter;
    pr->keylen = keylen;
    pr->fd = r->fd;
    pr->gen = r->gen;
    pr->viewer = r->viewer;
    pr->limit = limit;
    pr->offset = offset;
    memcpy(pr->key, key, keylen);
    r->q.len = sizeof *pr + keylen;
    r->ipc_kind = IPC_PLAN;
    r->next = NULL;
    if (!w->wait_read && to_drain(w, r)) return;
    if (w->wait_read_tail) w->wait_read_tail->next = r;
    else w->wait_read = r;
    w->wait_read_tail = r;
}

static void flush_wait_read(struct worker *w) {
    while (w->wait_read && to_drain(w, w->wait_read)) {
        w->wait_read = w->wait_read->next;
        if (!w->wait_read) w->wait_read_tail = NULL;
    }
}

static void pg_error_msg(struct worker *w, const struct pg_msg *m, struct pg_error *e) {
    pg_parse_error(m, e);
    if (strcmp(e->sqlstate, "23505") != 0)
        fprintf(stderr, "worker %d: postgres error %s: %s\n", w->id, e->sqlstate, e->message);
}

/* One message of a read unit's reply, relayed by the drain. */
static void read_reply_msg(struct worker *w, struct req *r, const struct pg_msg *m) {
    switch (m->type) {
    case 'D':
        if (!r->pg_error) r->fn(r, EV_ROW, m);
        break;
    case 'C':
    case 'I':
        r->stmt++;
        break;
    case 'E': {
        struct pg_error e;
        pg_error_msg(w, m, &e);
        if (!r->pg_error) {
            r->pg_error = true;
            memcpy(r->sqlstate, e.sqlstate, 6);
        }
        break;
    }
    case 'Z':
        r->fn(r, EV_READY, NULL);
        break;
    default:
        break;
    }
}

static void on_drain_replies(struct worker *w) {
    struct ring *ring = ipc.to_worker[w->id];
    const struct ipc_hdr *h;
    bool any = false;
    while ((h = ipc_peek(ring))) {
        any = true;
        struct req *r = (struct req *)(uintptr_t)h->token;
        if (h->kind == IPC_PLAN) {
            const struct plan_reply *rp = (const struct plan_reply *)(h + 1);
            if (rp->status == 0) {
                /* Dropped unrun: the drain saw the client gone (req_respond frees it; a live one gets a 503). */
                req_error(r, 503, "server busy, try again");
                continue;
            }
            http_begin(&r->resp);
            buf_put(&r->resp, rp->body, rp->len);
            req_respond(r, rp->status);
            continue;
        }
        if (h->kind != IPC_PG) die("worker %d: unknown reply kind %u", w->id, h->kind);
        const uint8_t *p = (const uint8_t *)(h + 1);
        size_t n = h->len;
        while (n) {
            struct pg_msg m;
            ptrdiff_t k = pg_next(p, n, &m);
            if (k <= 0) die("worker %d: malformed reply from the drain", w->id);
            p += k, n -= (size_t)k;
            read_reply_msg(w, r, &m);
        }
    }
    if (any) ipc_release(ring);
}

/* A merged statement's row ends with its request's ordinal k. Drops that column in place (the row lies in the
 * connection's own receive buffer and is read once), so the handler sees the row of the single statement. */
static bool row_take_k(const struct pg_msg *m, struct pg_msg *row, int64_t *k) {
    struct pg_row pr;
    if (!pg_row_init(&pr, m) || pr.ncols == 0) return false;
    const uint8_t *last = NULL, *v = NULL;
    int32_t n = -1;
    for (uint16_t i = 0; i < pr.ncols; i++) {
        last = pr.p;
        n = pg_col(&pr, &v);
        if (n == -2) return false;
    }
    if (n != 8) return false;
    *k = pg_i64(v);
    store_be16((uint8_t *)m->body, (uint16_t)(pr.ncols - 1));
    *row = *m;
    row->len = (uint32_t)(last - m->body);
    return true;
}

static void pg_dispatch_write(struct worker *w, struct pgc *pc, const struct pg_msg *m) {
    struct wstep *st = pc->cur < pc->nsteps ? &pc->steps[pc->cur] : NULL;
    switch (m->type) {
    case 'D':
        if (unlikely(!st)) die("postgres: row without a write");
        if (pc->group_failed) break;
        if (st->r) {
            st->r->fn(st->r, EV_ROW, m);
        } else {
            struct pg_msg row;
            int64_t k;
            if (unlikely(!row_take_k(m, &row, &k) || k < 1 || k > st->n)) die("postgres: malformed merged row");
            struct req *r = pc->run[st->run + (uint32_t)k - 1];
            r->fn(r, EV_ROW, &row);
        }
        break;
    case 'C':
    case 'I':
        if (unlikely(!st)) die("postgres: completion without a write");
        if (!st->r) {
            for (uint32_t i = 0; i < st->n; i++) pc->run[st->run + i]->stmt = 1;  /* their write was statement 0 */
            pc->cur++;
        } else if (++st->r->stmt == st->r->nexec) {
            pc->cur++;
        }
        break;
    case 'E': {
        struct pg_error e;
        pg_error_msg(w, m, &e);
        pc->group_failed = true;
        /* an error at commit time belongs to the group; a lone write owns it */
        struct req *r = st ? (st->r ? st->r : pc->run[st->run]) : pc->head;
        if (r && !r->pg_error) {
            r->pg_error = true;
            memcpy(r->sqlstate, e.sqlstate, 6);
        }
        break;
    }
    case 'Z': {
        struct req *list = pc->head, *tail = pc->tail;
        if (unlikely(!list)) die("postgres: ReadyForQuery without a write group");
        pc->head = pc->tail = NULL;
        pc->nsteps = pc->cur = pc->nrun = 0;
        pc->inflight = 0;
        if (pc->group_failed && list->next) {
            /* The whole group rolled back, so none of it happened: retry each write alone, first in line. */
            for (struct req *x = list; x; x = x->next) {
                x->solo = true;
                x->rows = 0;
                x->resp.len = x->resp_mark;
                w->wait_write_n++;
            }
            tail->next = w->wait_write;
            if (!w->wait_write) w->wait_write_tail = tail;
            w->wait_write = list;
            break;
        }
        while (list) {
            struct req *next = list->next;
            list->fn(list, EV_READY, NULL);
            list = next;
        }
        break;
    }
    case '1': case '2': case '3': case 'n': case 't': case 'T': case 'N': case 'S': case 'A':
        break;
    default:
        die("postgres: unexpected message '%c'", m->type);
    }
}

static void pg_dispatch(struct worker *w, struct pgc *pc, const struct pg_msg *m) { pg_dispatch_write(w, pc, m); }

static void on_pg_recv(struct worker *w, struct io_uring_cqe *cqe) {
    struct pgc *pc = UD_PTR(io_uring_cqe_get_data64(cqe));
    if (cqe->res <= 0) die("worker %d: postgres connection lost (%s)", w->id, cqe->res ? strerror(-cqe->res) : "EOF");
    pc->in.len += (size_t)cqe->res;
    size_t pos = 0;
    for (;;) {
        struct pg_msg m;
        ptrdiff_t k = pg_next((const uint8_t *)pc->in.p + pos, pc->in.len - pos, &m);
        if (k < 0) die("worker %d: postgres protocol error", w->id);
        if (k == 0) break;
        pos += (size_t)k;
        pg_dispatch(w, pc, &m);
    }
    memmove(pc->in.p, pc->in.p + pos, pc->in.len - pos);
    pc->in.len -= pos;
    if (pc->in.cap > (1u << 22) && pc->in.len < PG_RECV_MIN) {
        /* A huge result came through; give the memory back. */
        struct buf small;
        buf_init(&small, 2 * PG_RECV_MIN);
        buf_put(&small, pc->in.p, pc->in.len);
        buf_free(&pc->in);
        pc->in = small;
    }
    pg_arm_recv(w, pc);
}

static void on_pg_send(struct worker *w, struct io_uring_cqe *cqe) {
    struct pgc *pc = UD_PTR(io_uring_cqe_get_data64(cqe));
    if (cqe->res < 0) die("worker %d: postgres send: %s", w->id, strerror(-cqe->res));
    pc->sent += (size_t)cqe->res;
    if (pc->sent < pc->sending.len) {
        struct io_uring_sqe *s = sqe_get(w);
        io_uring_prep_send(s, pc->fd, pc->sending.p + pc->sent, pc->sending.len - pc->sent, MSG_NOSIGNAL);
        io_uring_sqe_set_data64(s, UD_MAKE_PTR(pc, OP_PG_SEND));
        return;
    }
    pc->sending.len = 0;
    pc->send_busy = false;
    if (pc->out.len) pg_start_send(w, pc);
}

/* ---- bcrypt completions ---- */

void bcrypt_submit(struct req *r) { bcrypt_pool_push(r->w->bp, r); }

static void arm_eventfd(struct worker *w) {
    struct io_uring_sqe *s = sqe_get(w);
    io_uring_prep_read(s, w->efd, &w->efd_val, sizeof w->efd_val, 0);
    io_uring_sqe_set_data64(s, OP_EVENTFD);
}

static void on_eventfd(struct worker *w, struct io_uring_cqe *cqe) {
    if (cqe->res < 0 && cqe->res != -EAGAIN && cqe->res != -EINTR) die("eventfd read: %s", strerror(-cqe->res));
    on_drain_replies(w);
    struct req *r = bcrypt_pool_take_done(w->bp);
    while (r) {
        struct req *next = r->next;
        if (r->bc.stale) req_error(r, 503, "server busy, try again");
        else r->fn(r, EV_HASHED, NULL);
        r = next;
    }
    arm_eventfd(w);
}

/* ---- setup ---- */

static int listen_socket(const char *host, const char *port) {
    struct addrinfo hints = {.ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM, .ai_flags = AI_PASSIVE}, *res;
    int rc = getaddrinfo(host, port, &hints, &res);
    if (rc) die("listen %s:%s: %s", host, port, gai_strerror(rc));
    int fd = socket(res->ai_family, res->ai_socktype | SOCK_CLOEXEC, res->ai_protocol);
    if (fd < 0) die("socket: %s", strerror(errno));
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one) < 0) die("SO_REUSEPORT: %s", strerror(errno));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);  /* inherited by accepted sockets */
    if (bind(fd, res->ai_addr, res->ai_addrlen) < 0) die("bind %s:%s: %s", host, port, strerror(errno));
    if (listen(fd, 65535) < 0) die("listen: %s", strerror(errno));
    freeaddrinfo(res);
    return fd;
}

static void ring_init(struct worker *w) {
    struct io_uring_params p = {0};
    p.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN | IORING_SETUP_CQSIZE;
    p.cq_entries = CQ_ENTRIES;
    int rc = io_uring_queue_init_params(RING_ENTRIES, &w->ring, &p);
    if (rc == -EINVAL) {
        memset(&p, 0, sizeof p);
        p.flags = IORING_SETUP_CQSIZE;
        p.cq_entries = CQ_ENTRIES;
        rc = io_uring_queue_init_params(RING_ENTRIES, &w->ring, &p);
    }
    if (rc < 0) die("io_uring_queue_init: %s", strerror(-rc));
}

static void buffers_init(struct worker *w) {
    w->bufs = xmalloc((size_t)w->nbufs * w->bufsz);
    struct io_uring_sqe *s = sqe_get(w);
    io_uring_prep_provide_buffers(s, w->bufs, (int)w->bufsz, (int)w->nbufs, BGID, 0);
    io_uring_sqe_set_data64(s, OP_IGNORE);
    io_uring_submit_and_wait(&w->ring, 1);
    struct io_uring_cqe *cqe;
    if (io_uring_peek_cqe(&w->ring, &cqe) == 0) {
        if (cqe->res < 0) die("provide buffers: %s", strerror(-cqe->res));
        io_uring_cqe_seen(&w->ring, cqe);
    }
}

static void pg_init(struct worker *w) {
    char err[256];
    w->nread = 0;  /* reads go through the drain */
    w->npg = cfg.write_conns;
    w->pg = xcalloc((size_t)w->npg, sizeof *w->pg);
    for (int i = 0; i < w->npg; i++) {
        struct pgc *pc = &w->pg[i];
        pc->w = w;
        pc->write = true;
        pc->fd = pg_open(&cfg.pg, err, sizeof err);
        if (pc->fd < 0) die("worker %d: postgres: %s", w->id, err);
        buf_init(&pc->out, 16384);
        buf_init(&pc->sending, 16384);
        buf_init(&pc->in, 2 * PG_RECV_MIN);
        /* At most one step per request plus one merged step per two requests. */
        pc->steps = xcalloc(2 * (size_t)cfg.write_group + 1, sizeof *pc->steps);
        pc->run = xcalloc(cfg.write_group, sizeof *pc->run);
        pc->seg = xcalloc(cfg.write_group, sizeof *pc->seg);
    }
}

static void on_cqe(struct worker *w, struct io_uring_cqe *cqe) {
    uint64_t ud = io_uring_cqe_get_data64(cqe);
    switch (UD_OP(ud)) {
    case OP_ACCEPT: on_accept(w, cqe); break;
    case OP_RECV: on_recv(w, cqe); break;
    case OP_SEND: on_send(w, cqe); break;
    case OP_PG_RECV: on_pg_recv(w, cqe); break;
    case OP_PG_SEND: on_pg_send(w, cqe); break;
    case OP_EVENTFD: on_eventfd(w, cqe); break;
    case OP_IGNORE:
        if (ud == TIMER_UD(w)) {
            w->timer_armed = false;  /* the loop starts the waiting group (pg_flush_all) */
            break;
        }
        if (cqe->res < 0) fprintf(stderr, "worker %d: ring op failed: %s\n", w->id, strerror(-cqe->res));
        break;
    case OP_QUIET:
        /* EBADF is a client closed in the same iteration, before the ring took the setsockopt. */
        if (ud == ACK_UD && !ack_syscall && (cqe->res == -EINVAL || cqe->res == -EOPNOTSUPP)) {
            ack_syscall = true;
            fprintf(stderr, "worker %d: no TCP_QUICKACK through io_uring (%s); using setsockopt\n", w->id,
                    strerror(-cqe->res));
        }
        break;
    }
}

void worker_run(int id) {
    struct worker *w = xcalloc(1, sizeof *w);
    w->id = id;

    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur < rl.rlim_max) {
        rl.rlim_cur = rl.rlim_max;
        setrlimit(RLIMIT_NOFILE, &rl);
    }
    getrlimit(RLIMIT_NOFILE, &rl);
    w->nconns = rl.rlim_cur > (1u << 22) ? (1u << 22) : (uint32_t)rl.rlim_cur;
    w->conns = xcalloc(w->nconns, sizeof *w->conns);
    w->norecv = xcalloc(w->nconns, sizeof *w->norecv);
    arena_init(&w->scratch, 1 << 16);
    w->nbufs = 4096;
    w->bufsz = 4096;

    pg_init(w);
    ring_init(w);
    if (cfg.direct_fds) {
        /* Accepted sockets live only in the ring's file table: no fd-table lookup and reference count per send
         * and receive. The kernel caps a table at 2^20 slots. */
        if (w->nconns > (1u << 20)) w->nconns = 1u << 20;
        int rc = io_uring_register_files_sparse(&w->ring, w->nconns);
        if (rc == 0) w->direct = true;
        else fprintf(stderr, "worker %d: no direct descriptors (%s); using plain fds\n", id, strerror(-rc));
    }
    buffers_init(w);
    w->listen_fd = listen_socket(cfg.host, cfg.port);
    w->efd = ipc.worker_efd[id];  /* replies from the drain and finished bcrypt jobs */
    w->bp = bcrypt_pool_start(w, cfg.bcrypt_threads);

    ack_delay = cfg.ack_delay;
    arm_accept(w);
    arm_eventfd(w);
    for (int i = 0; i < w->npg; i++) pg_arm_recv(w, &w->pg[i]);
    fprintf(stderr, "worker %d: listening on %s:%s with %d postgres write connection(s)\n", id, cfg.host, cfg.port,
            w->npg);

    for (;;) {
        pg_flush_all(w);
        if (w->norecv_len) rearm_starved(w);
        if (w->wait_read) flush_wait_read(w);
        if (w->wake_drain) {
            w->wake_drain = false;
            ipc_wake(ipc.drain_efd);
        }
        int rc = io_uring_submit_and_wait(&w->ring, 1);
        if (rc < 0 && rc != -EINTR && rc != -EBUSY && rc != -EAGAIN) die("io_uring_submit_and_wait: %s", strerror(-rc));
        w->now = wall_now();
        unsigned head, n = 0;
        struct io_uring_cqe *cqe;
        io_uring_for_each_cqe(&w->ring, head, cqe) {
            on_cqe(w, cqe);
            n++;
        }
        io_uring_cq_advance(&w->ring, n);
    }
}
