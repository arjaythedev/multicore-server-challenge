// MIT License — fork of pc-iouring-tigokraft (#10); ideas from pc-iouring-gilnett (#58), rust-tokio-Scooter1337 (#7), csharp-sockets-jh-d (#22).
// rw: Original MIT code (pc) challenge contributors; modifications (pc) frobinson. See README Credits.

// rw: The event loop: one io_uring per worker thread, each with its own SO_REUSEPORT listener and its own Postgres

// rw: connections, sharing nothing. Accepts are multishot; each connection has one multishot readiness poll and is

// rw: read with recv() into the worker's scratch buffer when it fires, so an idle keep-alive connection holds no

// rw: userspace buffer at all. (Provided-buffer rings would save that recv() call, but the Ubuntu 24.04 kernel

// rw: 6.8.0-142 rejects their registration with EINVAL.)

// rw: bcrypt runs on a separate small thread pool so a ~50 ms hash never stalls an event loop.

#include "app.h"
#include <crypt.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <sys/eventfd.h>
#include <sys/random.h>
#include <sys/resource.h>
#include <time.h>
#include <sys/socket.h>
#include <unistd.h>

config_t CFG;

#define RBUF_SIZE 65536
#define MAX_HEADER 65536
#define MAX_BODY (8 << 20)

struct io_uring_sqe *ev_next_sqe(ev_loop *ev) {
    struct io_uring_sqe *sqe = io_uring_get_sqe(&ev->ring);
    while (UNLIKELY(!sqe)) {
        io_uring_submit(&ev->ring);
        sqe = io_uring_get_sqe(&ev->ring);
    }
    return sqe;
}

// rw: ---------- bcrypt pool ----------


static pthread_mutex_t jobs_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t jobs_cv = PTHREAD_COND_INITIALIZER;
static job_t *jobs_head, *jobs_tail;
static int jobs_n;
static bool gathering;

void submit_job(job_t *j) {
    j->next = NULL;
    if (UNLIKELY(STATS_ON)) j->t0 = tm_now();
    pthread_mutex_lock(&jobs_mu);
    bool was_empty = (jobs_n == 0);
    if (jobs_tail) jobs_tail->next = j;
    else jobs_head = j;
    jobs_tail = j;
    jobs_n++;
    // rw: One wakeup per submit is enough: the woken thread becomes the gatherer

    // rw: and timed-waits up to BCRYPT_WAIT_MS for a fuller batch. Only the

    // rw: idle->nonempty transition broadcasts, so a parked pool still starts.

    if (was_empty) pthread_cond_broadcast(&jobs_cv);
    else pthread_cond_signal(&jobs_cv);
    pthread_mutex_unlock(&jobs_mu);
}

static bool ct_streq(const char *a, const char *b) {
    size_t n = strlen(a);
    if (n != strlen(b)) return false;
    unsigned char d = 0;
    for (size_t i = 0; i < n; i++) d |= a[i] ^ b[i];
    return d == 0;
}

static void job_done(job_t *j) {
    ev_loop *ev = j->rq->ev;
    pthread_mutex_lock(&ev->mu);
    j->next = ev->done;
    ev->done = j;
    pthread_mutex_unlock(&ev->mu);
    uint64_t one = 1;
    if (write(ev->efd, &one, 8) < 0 && errno != EAGAIN) die("eventfd write: %s", strerror(errno));
}

// rw: Takes up to bcrypt_lanes queued jobs at a time and computes those with the same cost together (bcrypt.pc).

// rw: Anything bcrypt.pc doesn't handle (another hash format) goes through libxcrypt.

// rw: Pinned by main() to a bcrypt core when an affinity slot was assigned (arg = int *cpu, or NULL).

static void *bcrypt_main(void *arg) {
    if (arg) {
        int cpu = *(int *)arg;
        if (cpu >= 0) {
            cpu_set_t s;
            CPU_ZERO(&s);
            CPU_SET(cpu, &s);
            pthread_setaffinity_np(pthread_self(), sizeof s, &s);
        }
    }
    pthread_setname_np(pthread_self(), "bcrypt");
    // Own scheduling (rewrite, rust-mio idea): BATCH + nice 10 so Linux prefers io_uring workers + PG backends.
    {
        struct sched_param sp = {.sched_priority = 0};
        pthread_setschedparam(pthread_self(), SCHED_BATCH, &sp);
        nice(10);
    }
    struct crypt_data *cd = calloc(1, sizeof *cd);
    if (!cd) die("out of memory");
    for (;;) {
        job_t *batch[BC_LANES];
        int n = 0;
        pthread_mutex_lock(&jobs_mu);
        // rw: A fuller batch costs much less CPU per hash (4 lanes: half), so one thread at a time (the gatherer)

        // rw: lets a login wait up to BCRYPT_WAIT_MS for others to share its batch; the other threads start only

        // rw: on a full batch. Logins are ~0.1% of requests; the wait buys CPU for all the others.

        for (;;) {
            if (jobs_n >= CFG.bcrypt_lanes) break;
            if (jobs_n > 0 && !gathering) {
                gathering = true;
                struct timespec until;
                clock_gettime(CLOCK_REALTIME, &until);
                until.tv_nsec += CFG.bcrypt_wait_ms * 1000000L;
                while (until.tv_nsec >= 1000000000) until.tv_sec++, until.tv_nsec -= 1000000000;
                while (jobs_n < CFG.bcrypt_lanes && pthread_cond_timedwait(&jobs_cv, &jobs_mu, &until) == 0) {}
                gathering = false;
                break;
            }
            pthread_cond_wait(&jobs_cv, &jobs_mu);
        }
        while (jobs_head && n < CFG.bcrypt_lanes) {
            batch[n++] = jobs_head;
            jobs_head = jobs_head->next;
            jobs_n--;
        }
        if (!jobs_head) jobs_tail = NULL;
        pthread_cond_signal(&jobs_cv); // leftover may need a new gatherer; one wakeup suffices
        pthread_mutex_unlock(&jobs_mu);

        const char *pw[BC_LANES], *set[BC_LANES];
        char salts[BC_LANES][30], out[BC_LANES][64];
        job_t *lane[BC_LANES];
        int nl = 0, cost = -1;
        for (int i = 0; i < n; i++) {
            job_t *j = batch[i];
            const char *s = j->setting;
            if (j->hash) {
                if (!bc_gensalt(salts[i])) die("getrandom failed");
                s = salts[i];
            }
            int pc = bc_cost(s);
            if (pc >= 0 && (cost < 0 || pc == cost)) {
                cost = pc;
                pw[nl] = j->pw;
                set[nl] = s;
                lane[nl++] = j;
            } else { // libxcrypt
                const char *h = crypt_rn(j->pw, s, cd, sizeof *cd);
                j->ok = h && h[0] == '$' && strlen(h) < sizeof j->out && (j->hash || ct_streq(h, s));
                if (j->ok && j->hash) strcpy(j->out, h);
                job_done(j);
            }
        }
        if (nl) bc_hash_n(nl, pw, set, out);
        if (getenv("BCRYPT_DEBUG")) logf_("bcrypt batch: %d lane(s), %d queued", nl, jobs_n);
        for (int i = 0; i < nl; i++) {
            job_t *j = lane[i];
            if (j->hash) {
                strcpy(j->out, out[i]);
                j->ok = true;
            } else {
                j->ok = ct_streq(out[i], j->setting);
            }
            job_done(j);
        }
    }
    return NULL;
}

// rw: `conduit --bcrypt-selftest`: compares bcrypt.pc with libxcrypt on random passwords and salts, then times it.

static int bcrypt_selftest(void) {
    struct crypt_data *cd = calloc(1, sizeof *cd);
    int bad = 0, total = 0;
    for (int round = 0; round < 300; round++) {
        int n = 1 + round % BC_LANES, cost = round < 290 ? 4 : 10;
        char pws[BC_LANES][80], sets[BC_LANES][64], out[BC_LANES][64];
        const char *pw[BC_LANES], *set[BC_LANES];
        for (int l = 0; l < n; l++) {
            uint8_t r[80];
            if (getrandom(r, sizeof r, 0) != sizeof r) return 1;
            int len = r[0] % 73;
            bool ascii = round % 2; // $2a$ is only compared on ASCII: libxcrypt deliberately mangles $2a$ keys with 8-bit bytes
            for (int i = 0; i < len; i++) pws[l][i] = ascii ? 32 + r[i + 1] % 95 : 1 + r[i + 1] % 255;
            pws[l][len] = 0;
            char salt[30];
            bc_gensalt(salt);
            snprintf(sets[l], sizeof sets[l], "$2%c$%02d$%s", ascii ? 'a' : 'b', cost, salt + 7);
            pw[l] = pws[l];
            set[l] = sets[l];
        }
        bc_hash_n(n, pw, set, out);
        for (int l = 0; l < n; l++, total++) {
            const char *ref = crypt_rn(pw[l], set[l], cd, sizeof *cd);
            if (!ref || strcmp(ref, out[l]) != 0) {
                if (bad++ < 5) fprintf(stderr, "MISMATCH lanes=%d pw-len=%zu %s\n  ours %s\n  ref  %s\n", n, strlen(pw[l]), set[l], out[l], ref ? ref : "(null)");
            }
        }
    }
    printf("bcrypt selftest: %d of %d hashes match libxcrypt\n", total - bad, total);
    for (int n = 1; n <= BC_LANES; n++) {
        const char *pw[BC_LANES], *set[BC_LANES];
        char sets[BC_LANES][30], out[BC_LANES][64];
        for (int l = 0; l < n; l++) { pw[l] = "password123"; bc_gensalt(sets[l]); set[l] = sets[l]; }
        struct timespec a, b;
        clock_gettime(CLOCK_MONOTONIC, &a);
        for (int k = 0; k < 4; k++) bc_hash_n(n, pw, set, out);
        clock_gettime(CLOCK_MONOTONIC, &b);
        double ms = ((b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6) / 4;
        printf("  %d lane(s), cost 10: %6.1f ms per batch, %6.1f ms of CPU per hash\n", n, ms, ms / n);
    }
    struct timespec a, b;
    char salt[64];
    crypt_gensalt_rn("$2b$", 10, NULL, 0, salt, sizeof salt);
    clock_gettime(CLOCK_MONOTONIC, &a);
    for (int k = 0; k < 4; k++) crypt_rn("password123", salt, cd, sizeof *cd);
    clock_gettime(CLOCK_MONOTONIC, &b);
    printf("  libxcrypt, cost 10:        %6.1f ms per hash\n", ((b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6) / 4);
    return bad != 0;
}

static void arm_event(ev_loop *ev) {
    struct io_uring_sqe *sqe = ev_next_sqe(ev);
    io_uring_prep_read(sqe, ev->efd, &ev->efd_val, 8, 0);
    io_uring_sqe_set_data64(sqe, UD(ev, UD_EVENT));
}

static void on_event(ev_loop *ev) {
    pthread_mutex_lock(&ev->mu);
    job_t *j = ev->done;
    ev->done = NULL;
    pthread_mutex_unlock(&ev->mu);
    while (j) {
        job_t *next = j->next;
        if (UNLIKELY(STATS_ON)) tm_bcrypt_done(ev, j->t0);
        j->cb(j->rq, j);
        j = next;
    }
    arm_event(ev);
}

// rw: ---------- connections ----------


static void conn_process(http_conn *pc);

static void conn_arm_recv(http_conn *pc) {
    struct io_uring_sqe *sqe = ev_next_sqe(pc->ev);
    io_uring_prep_poll_multishot(sqe, pc->fd, POLLIN | POLLRDHUP);
    io_uring_sqe_set_data64(sqe, UD(pc, UD_RECV));
    pc->recv_armed = true;
}

static void conn_maybe_free(http_conn *pc) {
    if (!pc->closing || pc->recv_armed || pc->send_inflight || pc->req) return;
    if (UNLIKELY(STATS_ON)) tm_conn_track(pc->ev, -1);
    close(pc->fd);
    buf_free(&pc->in);
    buf_free(&pc->out);
    buf_free(&pc->sending);
    free(pc);
}

// rw: Starts closing: cancels the readiness poll (its final completion clears recv_armed), and the conn is freed

// rw: once nothing refers to it any more.

static void conn_close(http_conn *pc) {
    if (!pc->closing) {
        pc->closing = true;
        if (pc->recv_armed) {
            struct io_uring_sqe *sqe = ev_next_sqe(pc->ev);
            io_uring_prep_poll_remove(sqe, UD(pc, UD_RECV));
            io_uring_sqe_set_data64(sqe, 0);
        }
    }
    conn_maybe_free(pc);
}

// rw: Responses are appended to pc->out; a send owns pc->sending until it completes, so appending (and

// rw: reallocating) never moves bytes the kernel is still reading.

static void conn_flush(http_conn *pc) {
    if (pc->send_inflight || pc->out.len == 0) return;
    pc->sending = pc->out;
    pc->out = (buf_t){0};
    pc->out_off = 0;
    struct io_uring_sqe *sqe = ev_next_sqe(pc->ev);
    io_uring_prep_send(sqe, pc->fd, pc->sending.p, pc->sending.len, MSG_NOSIGNAL);
    io_uring_sqe_set_data64(sqe, UD(pc, UD_SEND));
    pc->send_inflight = true;
}

static void conn_on_send(http_conn *pc, int res) {
    pc->send_inflight = false;
    if (res < 0) {
        buf_free(&pc->sending);
        pc->peer_closed = true;
        conn_close(pc);
        return;
    }
    pc->out_off += res;
    if (pc->out_off < pc->sending.len && !pc->closing) {
        struct io_uring_sqe *sqe = ev_next_sqe(pc->ev);
        io_uring_prep_send(sqe, pc->fd, pc->sending.p + pc->out_off, pc->sending.len - pc->out_off, MSG_NOSIGNAL);
        io_uring_sqe_set_data64(sqe, UD(pc, UD_SEND));
        pc->send_inflight = true;
        return;
    }
    buf_free(&pc->sending);
    if (pc->closing) { conn_maybe_free(pc); return; }
    conn_flush(pc);
    if (!pc->send_inflight && pc->peer_closed && !pc->req) conn_close(pc);
}

static const char *status_line(int st) {
    switch (st) {
    case 200: return "HTTP/1.1 200 OK\r\n";
    case 201: return "HTTP/1.1 201 Created\r\n";
    case 204: return "HTTP/1.1 204 No Content\r\n";
    case 400: return "HTTP/1.1 400 Bad Request\r\n";
    case 401: return "HTTP/1.1 401 Unauthorized\r\n";
    case 403: return "HTTP/1.1 403 Forbidden\r\n";
    case 404: return "HTTP/1.1 404 Not Found\r\n";
    case 413: return "HTTP/1.1 413 Request Entity Too Large\r\n";
    case 422: return "HTTP/1.1 422 Unprocessable Entity\r\n";
    case 431: return "HTTP/1.1 431 Request Header Fields Too Large\r\n";
    default: return "HTTP/1.1 500 Internal Server Error\r\n";
    }
}

static void write_response(http_conn *pc, int status, const buf_t *body, bool keepalive) {
    buf_t *o = &pc->out;
    const char *sl = status_line(status);
    buf_put(o, sl, strlen(sl));
    if (status != 204) {
        buf_lit(o, "Content-Type: application/json\r\nContent-Length: ");
        buf_i64(o, body ? (int64_t)body->len : 0);
        buf_lit(o, "\r\n");
    }
    if (!keepalive) buf_lit(o, "Connection: close\r\n");
    buf_lit(o, "\r\n");
    if (body && status != 204) buf_put(o, body->p, body->len);
}

static void req_free(http_req *rq) {
    arena_recycle(rq->ev, &rq->arena);
    free(rq);
}

void http_reply(http_req *rq, int status, const buf_t *body) {
    http_conn *pc = rq->pc;
    bool keepalive = rq->keepalive;
    pc->req = NULL;
    if (UNLIKELY(STATS_ON)) tm_req_done(rq->ev, rq->t0);
    req_free(rq);
    if (pc->closing) { conn_maybe_free(pc); return; }
    write_response(pc, status, body, keepalive);
    if (!keepalive) pc->peer_closed = true; // stop reading; close once the response is out
    conn_flush(pc);
    if (pc->peer_closed) {
        if (!pc->send_inflight) conn_close(pc);
        return;
    }
    if (!pc->processing) conn_process(pc);
}

void http_reply_err(http_req *rq, int status, const char *msg) {
    buf_t *b = &rq->ev->body;
    b->len = 0;
    buf_lit(b, "{\"errors\":{\"body\":[");
    buf_json_str(b, msg, strlen(msg));
    buf_lit(b, "]}}");
    http_reply(rq, status, b);
}

static void conn_fail(http_conn *pc, int status, const char *msg) {
    buf_t b = {0};
    buf_lit(&b, "{\"errors\":{\"body\":[\"");
    buf_put(&b, msg, strlen(msg));
    buf_lit(&b, "\"]}}");
    write_response(pc, status, &b, false);
    buf_free(&b);
    buf_free(&pc->in);
    pc->peer_closed = true;
    conn_flush(pc);
}

static bool hdr_is(const char *p, size_t n, const char *name) {
    size_t k = strlen(name);
    if (n != k) return false;
    for (size_t i = 0; i < k; i++)
        if ((p[i] | 0x20) != name[i]) return false;
    return true;
}

static bool has_token(const char *p, size_t n, const char *tok) { // case-insensitive comma list
    size_t k = strlen(tok);
    for (size_t i = 0; i + k <= n; i++) {
        if ((i == 0 || p[i - 1] == ',' || p[i - 1] == ' ') && strncasecmp(p + i, tok, k) == 0 &&
            (i + k == n || p[i + k] == ',' || p[i + k] == ' '))
            return true;
    }
    return false;
}

static int unhex(char pc) {
    if (pc >= '0' && pc <= '9') return pc - '0';
    pc |= 0x20;
    if (pc >= 'a' && pc <= 'f') return pc - 'a' + 10;
    return -1;
}

// rw: Percent-decodes in place; false on a malformed escape.

static bool pct_decode(char *p, size_t *n) {
    size_t o = 0;
    for (size_t i = 0; i < *n; i++) {
        if (p[i] == '%') {
            if (i + 2 >= *n) return false;
            int h = unhex(p[i + 1]), l = unhex(p[i + 2]);
            if (h < 0 || l < 0) return false;
            p[o++] = h << 4 | l;
            i += 2;
        } else {
            p[o++] = p[i];
        }
    }
    *n = o;
    return true;
}

// rw: Parses one request from pc->in. 1: dispatched, 0: need more bytes, -1: protocol error (connection closing).

static int conn_parse(http_conn *pc) {
    char *in = pc->in.p;
    size_t len = pc->in.len;
    char *end = len >= 4 ? memmem(in, len, "\r\n\r\n", 4) : NULL;
    if (!end) {
        if (len > MAX_HEADER) { conn_fail(pc, 431, "headers too large"); return -1; }
        return 0;
    }
    size_t hlen = end - in + 4;
    char *line_end = memchr(in, '\r', hlen);
    // rw: request line: METHOD SP target SP HTTP/1.x

    char *sp1 = memchr(in, ' ', line_end - in);
    char *sp2 = sp1 ? memchr(sp1 + 1, ' ', line_end - sp1 - 1) : NULL;
    if (!sp1 || !sp2 || line_end - sp2 - 1 != 8 || memcmp(sp2 + 1, "HTTP/1.", 7) != 0) {
        conn_fail(pc, 400, "bad request line");
        return -1;
    }
    bool http10 = sp2[8] == '0';
    bool keepalive = !http10;
    size_t m_off = 0, m_len = sp1 - in, t_off = sp1 + 1 - in, t_len = sp2 - sp1 - 1;
    size_t a_off = 0, a_len = 0;
    bool have_auth = false;
    int64_t clen = 0;
    bool have_clen = false;
    for (char *p = line_end + 2; p < end + 2;) {
        char *e = memchr(p, '\r', end + 2 - p);
        if (!e) break;
        char *colon = memchr(p, ':', e - p);
        if (colon) {
            char *v = colon + 1, *ve = e;
            while (v < ve && (*v == ' ' || *v == '\t')) v++;
            while (ve > v && (ve[-1] == ' ' || ve[-1] == '\t')) ve--;
            size_t nl = colon - p;
            if (hdr_is(p, nl, "content-length")) {
                int64_t n;
                if (!parse_uint(v, ve - v, &n) || (have_clen && n != clen)) { conn_fail(pc, 400, "bad content-length"); return -1; }
                clen = n;
                have_clen = true;
            } else if (hdr_is(p, nl, "authorization")) {
                if (!have_auth) { a_off = v - in; a_len = ve - v; have_auth = true; }
            } else if (hdr_is(p, nl, "connection")) {
                if (has_token(v, ve - v, "close")) keepalive = false;
                else if (http10 && has_token(v, ve - v, "keep-alive")) keepalive = true;
            } else if (hdr_is(p, nl, "transfer-encoding")) {
                conn_fail(pc, 400, "transfer-encoding not supported");
                return -1;
            }
        }
        p = e + 2;
    }
    if (clen > MAX_BODY) { conn_fail(pc, 413, "body too large"); return -1; }
    size_t total = hlen + clen;
    if (len < total) return 0;

    http_req *rq = calloc(1, sizeof *rq);
    if (!rq) die("out of memory");
    rq->pc = pc;
    rq->ev = pc->ev;
    rq->keepalive = keepalive;
    arena_seed(rq->ev, &rq->arena);
    if (UNLIKELY(STATS_ON)) rq->t0 = tm_now();
    char *raw = arena_alloc(&rq->arena, total + 1);
    memcpy(raw, in, total);
    raw[total] = 0;
    memmove(in, in + total, len - total);
    pc->in.len -= total;
    if (pc->in.len == 0) buf_free(&pc->in);

    const char *m = raw + m_off;
    rq->method = m_len == 3 && !memcmp(m, "GET", 3) ? M_GET
              : m_len == 4 && !memcmp(m, "POST", 4) ? M_POST
              : m_len == 3 && !memcmp(m, "PUT", 3) ? M_PUT
              : m_len == 6 && !memcmp(m, "DELETE", 6) ? M_DELETE : M_OTHER;
    if (have_auth) rq->auth = (str_t){raw + a_off, a_len};
    rq->body = (str_t){raw + hlen, (size_t)clen};
    char *t = raw + t_off;
    char *q = memchr(t, '?', t_len);
    size_t plen = q ? (size_t)(q - t) : t_len;
    if (q) rq->query = (str_t){q + 1, t_len - plen - 1};
    rq->path = (str_t){t, plen};

    // rw: Split /api/<seg>/<seg>/... and decode each segment.

    pc->req = rq;
    if (plen < 5 || memcmp(t, "/api/", 5) != 0) { rq->nseg = -1; return 1; }
    char *s = t + 5, *pe = t + plen;
    for (;;) {
        char *slash = memchr(s, '/', pe - s);
        char *se = slash ? slash : pe;
        if (rq->nseg == 6) { rq->nseg = -1; break; }
        size_t n = se - s;
        if (!pct_decode(s, &n)) { rq->nseg = -2; break; }
        rq->seg[rq->nseg++] = (str_t){s, n};
        if (!slash) break;
        s = slash + 1;
    }
    return 1;
}

static void conn_process(http_conn *pc) {
    pc->processing = true;
    while (!pc->req && !pc->closing && !pc->peer_closed && pc->in.len) {
        int rc = conn_parse(pc);
        if (rc <= 0) break;
        http_req *rq = pc->req;
        if (rq->nseg == -2) { http_reply_err(rq, 400, "bad path escape"); continue; }
        route_request(rq);
    }
    pc->processing = false;
    if (pc->peer_closed && !pc->closing && !pc->req && !pc->send_inflight) conn_close(pc);
}

static void conn_on_recv(http_conn *pc, struct io_uring_cqe *cqe) {
    ev_loop *ev = pc->ev;
    if (!(cqe->flags & IORING_CQE_F_MORE)) pc->recv_armed = false;
    if (pc->closing) { conn_maybe_free(pc); return; }
    bool eof = cqe->res < 0;
    while (!eof) {
        ssize_t n = recv(pc->fd, ev->rbuf, RBUF_SIZE, MSG_DONTWAIT);
        if (n > 0) {
            if (!pc->peer_closed) buf_put(&pc->in, ev->rbuf, n);
            if (n < RBUF_SIZE) break;
        } else if (n == 0) {
            eof = true;
        } else if (errno != EINTR) {
            if (errno != EAGAIN && errno != EWOULDBLOCK) eof = true;
            break;
        }
    }
    if (!eof && !pc->recv_armed && !pc->peer_closed) conn_arm_recv(pc);
    conn_process(pc); // answer whatever complete requests arrived, even if the client is now gone
    if (!eof) return;
    pc->peer_closed = true;
    if (!pc->req && !pc->send_inflight) conn_close(pc);
}

static void arm_accept(ev_loop *ev) {
    struct io_uring_sqe *sqe = ev_next_sqe(ev);
    io_uring_prep_multishot_accept(sqe, ev->lfd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
    io_uring_sqe_set_data64(sqe, UD(ev, UD_ACCEPT));
}

// rw: fd/memory exhaustion on accept: re-arming the multishot accept at once

// rw: hot-loops on immediate failures, so log at most once/sec and retry after a

// rw: short timeout instead (its completion re-arms the accept).

static void on_accept(ev_loop *ev, struct io_uring_cqe *cqe) {
    if (cqe->res >= 0) {
        int fd = cqe->res;
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        http_conn *pc = calloc(1, sizeof *pc);
        if (!pc) die("out of memory");
        pc->ev = ev;
        pc->fd = fd;
        if (UNLIKELY(STATS_ON)) tm_conn_track(ev, 1);
        conn_arm_recv(pc);
    } else if (cqe->res == -EMFILE || cqe->res == -ENFILE || cqe->res == -ENOMEM) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        uint64_t ms = (uint64_t)now.tv_sec * 1000 + (uint64_t)(now.tv_nsec / 1000000);
        if (ms - ev->accept_err_last_log >= 1000) {
            ev->accept_err_last_log = ms;
            logf_("accept: %s (backing off)", strerror(-cqe->res));
        }
        if (!(cqe->flags & IORING_CQE_F_MORE)) {
            ev->accept_retry_ts.tv_sec = 0;
            ev->accept_retry_ts.tv_nsec = 20 * 1000 * 1000; // 20ms
            struct io_uring_sqe *sqe = ev_next_sqe(ev);
            io_uring_prep_timeout(sqe, &ev->accept_retry_ts, 0, 0);
            io_uring_sqe_set_data64(sqe, UD(ev, UD_ACCEPT_WAIT));
        }
        return;
    } else if (cqe->res != -EAGAIN && cqe->res != -EINTR && cqe->res != -ECONNABORTED) {
        logf_("accept: %s", strerror(-cqe->res));
    }
    if (!(cqe->flags & IORING_CQE_F_MORE)) arm_accept(ev);
}

// rw: ---------- worker ----------


static void *worker_main(void *arg) {
    ev_loop *ev = arg;
    if (ev->pin_cpu >= 0) {
        cpu_set_t s;
        CPU_ZERO(&s);
        CPU_SET(ev->pin_cpu, &s);
        pthread_setaffinity_np(pthread_self(), sizeof s, &s);
    }
    pthread_setname_np(pthread_self(), "loop");
    for (int i = 0; i < ev->nread; i++) pg_conn_open(&ev->pg_read[i], ev);
    for (int i = 0; i < ev->nwrite; i++) pg_conn_open(&ev->pg_write[i], ev);
    if (STATS_ON) tm_init(ev);

    struct io_uring_params p = {0};
    p.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN | IORING_SETUP_COOP_TASKRUN | IORING_SETUP_CQSIZE;
    p.cq_entries = 32768;
    int ret = io_uring_queue_init_params(4096, &ev->ring, &p);
    if (ret == -EINVAL) {
        memset(&p, 0, sizeof p);
        p.flags = IORING_SETUP_CQSIZE;
        p.cq_entries = 32768;
        ret = io_uring_queue_init_params(4096, &ev->ring, &p);
    }
    if (ret < 0) die("io_uring_queue_init: %s (is io_uring enabled? sysctl kernel.io_uring_disabled)", strerror(-ret));

    ev->rbuf = malloc(RBUF_SIZE);
    if (!ev->rbuf) die("out of memory");

    ev->efd = eventfd(0, EFD_CLOEXEC);
    if (ev->efd < 0) die("eventfd: %s", strerror(errno));
    arm_event(ev);
    struct io_uring_sqe *sqe = ev_next_sqe(ev);
    io_uring_prep_multishot_accept(sqe, ev->lfd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
    io_uring_sqe_set_data64(sqe, UD(ev, UD_ACCEPT));
    for (int i = 0; i < ev->nread; i++) pg_conn_arm_read(&ev->pg_read[i]);
    for (int i = 0; i < ev->nwrite; i++) pg_conn_arm_read(&ev->pg_write[i]);

    for (;;) {
        for (int i = 0; i < ev->nread; i++) pg_conn_flush(&ev->pg_read[i]);
        for (int i = 0; i < ev->nwrite; i++) pg_conn_flush(&ev->pg_write[i]); // coalesced write flush (group-commit ready)
        ret = io_uring_submit_and_wait(&ev->ring, 1);
        if (ret < 0 && ret != -EINTR && ret != -EAGAIN && ret != -EBUSY) die("io_uring_submit_and_wait: %s", strerror(-ret));
        uint64_t t_wake = UNLIKELY(STATS_ON) ? tm_now() : 0;
        struct io_uring_cqe *cqe;
        unsigned head, n = 0;
        io_uring_for_each_cqe(&ev->ring, head, cqe) {
            n++;
            uint64_t ud = cqe->user_data;
            void *ptr = (void *)(uintptr_t)(ud & ~(uint64_t)7);
            switch (ud & 7) {
            case UD_ACCEPT: on_accept(ev, cqe); break;
            case UD_ACCEPT_WAIT: arm_accept(ev); break; // accept backoff elapsed; re-arm
            case UD_RECV: conn_on_recv(ptr, cqe); break;
            case UD_SEND: conn_on_send(ptr, cqe->res); break;
            case UD_PGRECV: pg_conn_on_readable(ptr, cqe->res); break;
            case UD_PGSEND: pg_conn_on_writable(ptr, cqe->res); break;
            case UD_EVENT: on_event(ev); break;
            }
        }
        io_uring_cq_advance(&ev->ring, n);
        if (UNLIKELY(STATS_ON)) tm_tick(ev, t_wake, n);
    }
    return NULL;
}

// rw: ---------- startup ----------


static int env_int(const char *name, int def) {
    const char *v = getenv(name);
    if (!v || !*v) return def;
    int n = atoi(v);
    if (n <= 0) die("%s must be a positive integer, got %s", name, v);
    return n;
}

static char *url_part(const char *s, size_t n) {
    char *p = malloc(n + 1);
    memcpy(p, s, n);
    p[n] = 0;
    size_t m = n;
    if (!pct_decode(p, &m)) die("DATABASE_URL: bad escape");
    p[m] = 0;
    return p;
}

// rw: postgres://user:pass@host:port/db[?...]

static void parse_db_url(const char *url) {
    const char *p = strstr(url, "://");
    if (!p) die("DATABASE_URL must look like postgres://user:pass@host:port/db");
    p += 3;
    const char *at = strchr(p, '@');
    const char *hostp = p;
    CFG.db_user = url_part("postgres", 8);
    CFG.db_pass = url_part("", 0);
    if (at) {
        const char *colon = memchr(p, ':', at - p);
        if (colon) {
            CFG.db_user = url_part(p, colon - p);
            CFG.db_pass = url_part(colon + 1, at - colon - 1);
        } else {
            CFG.db_user = url_part(p, at - p);
        }
        hostp = at + 1;
    }
    const char *slash = strchr(hostp, '/');
    const char *hend = slash ? slash : hostp + strlen(hostp);
    const char *colon = NULL;
    if (*hostp == '[') { // [ipv6]:port
        const char *rb = memchr(hostp, ']', hend - hostp);
        if (!rb) die("DATABASE_URL: bad host");
        CFG.db_host = url_part(hostp + 1, rb - hostp - 1);
        if (rb + 1 < hend && rb[1] == ':') colon = rb + 1;
    } else {
        colon = memchr(hostp, ':', hend - hostp);
        CFG.db_host = url_part(hostp, (colon ? colon : hend) - hostp);
    }
    CFG.db_port = colon ? url_part(colon + 1, hend - colon - 1) : url_part("5432", 4);
    if (!*CFG.db_host) CFG.db_host = url_part("127.0.0.1", 9);
    if (slash) {
        const char *q = strchr(slash + 1, '?');
        CFG.db_name = url_part(slash + 1, (q ? q : slash + 1 + strlen(slash + 1)) - slash - 1);
    }
    if (!CFG.db_name || !*CFG.db_name) CFG.db_name = CFG.db_user;
}

static int listen_socket(void) {
    struct addrinfo hints = {.ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM, .ai_flags = AI_PASSIVE | AI_NUMERICSERV}, *res;
    int e = getaddrinfo(CFG.host, CFG.port, &hints, &res);
    if (e) die("listen address %s:%s: %s", CFG.host, CFG.port, gai_strerror(e));
    int fd = socket(res->ai_family, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) die("socket: %s", strerror(errno));
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one) < 0) die("SO_REUSEPORT: %s", strerror(errno));
    if (bind(fd, res->ai_addr, res->ai_addrlen) < 0) die("bind %s:%s: %s", CFG.host, CFG.port, strerror(errno));
    if (listen(fd, 65535) < 0) die("listen: %s", strerror(errno));
    freeaddrinfo(res);
    return fd;
}

// rw: Container-aware CPU quota: the benchmark runs in Docker with --cpus, which

// rw: sets a cgroup quota without shrinking sched_getaffinity. Returns 0 when

// rw: unlimited or unreadable. v2: /sys/fs/cgroup/cpu.max ("$MAX $PERIOD" or

// rw: "max $PERIOD"); v1: cpu.cfs_quota_us / cpu.cfs_period_us.

static int cgroup_cpu_quota(void) {
    FILE *f = fopen("/sys/fs/cgroup/cpu.max", "r");
    if (f) {
        char maxbuf[64] = {0}, perbuf[64] = {0};
        int n = fscanf(f, "%63s %63s", maxbuf, perbuf);
        fclose(f);
        if (n == 2 && strcmp(maxbuf, "max") != 0) {
            long quota = atol(maxbuf), period = atol(perbuf);
            if (quota > 0 && period > 0) return (int)((quota + period - 1) / period);
        }
        return 0;
    }
    FILE *q = fopen("/sys/fs/cgroup/cpu/cpu.cfs_quota_us", "r");
    FILE *p = fopen("/sys/fs/cgroup/cpu/cpu.cfs_period_us", "r");
    if (q && p) {
        long quota = -1, period = 100000;
        if (fscanf(q, "%ld", &quota) != 1) quota = -1;
        if (fscanf(p, "%ld", &period) != 1) period = 100000;
        fclose(q);
        fclose(p);
        if (quota > 0 && period > 0) return (int)((quota + period - 1) / period);
        return 0;
    }
    if (q) fclose(q);
    if (p) fclose(p);
    return 0;
}

// rw: `conduit --print-defaults`: dry run for rig validation. Prints the effective

// rw: worker/connection defaults (honoring THREADS/... env overrides, same

// rw: formulas as startup) and exits without listeners, threads or database I/O.

static int print_defaults(void) {
    cpu_set_t cs;
    int aff = sched_getaffinity(0, sizeof cs, &cs) == 0 ? CPU_COUNT(&cs) : (int)sysconf(_SC_NPROCESSORS_ONLN);
    if (aff < 1) aff = 1;
    int quota = cgroup_cpu_quota();
    int ncpu = quota > 0 && quota < aff ? quota : aff;
    if (ncpu < 1) ncpu = 1;
    printf("THREADS=%d DB_CONNS=%d R=%d W=%d BCRYPT_THREADS=%d BCRYPT_LANES=%d PG_DEPTH=%d BCRYPT_WAIT_MS=%d ncpu=%d affinity=%d quota=%d\n",
           env_int("THREADS", ncpu / 4 > 0 ? ncpu / 4 : 1),
           env_int("DB_CONNS", ncpu * 4 > 95 ? 95 : ncpu * 4),
           env_int("DB_READ_CONNS", (env_int("DB_CONNS", ncpu * 4 > 95 ? 95 : ncpu * 4)*3+3)/4),
           env_int("DB_WRITE_CONNS", 8),
           env_int("BCRYPT_THREADS", ncpu >= 2 ? ncpu / 2 : 1),
           env_int("BCRYPT_LANES", BC_LANES),
           env_int("PG_DEPTH", 16),
           getenv("BCRYPT_WAIT_MS") ? atoi(getenv("BCRYPT_WAIT_MS")) : 40,
           ncpu, aff, quota);
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stderr, NULL, _IOLBF, 0);
    if (argc > 1 && !strcmp(argv[1], "--bcrypt-selftest")) return bcrypt_selftest();
    if (argc > 1 && !strcmp(argv[1], "--print-defaults")) return print_defaults();
    signal(SIGPIPE, SIG_IGN);
    // rw: 20k+ connections need fds far past the usual 1024 default; do this

    // rw: before any listen_socket(). start.sh raises the shell limit to match.

    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0) {
        rl.rlim_cur = rl.rlim_max = 200000;
        if (setrlimit(RLIMIT_NOFILE, &rl) < 0 && getrlimit(RLIMIT_NOFILE, &rl) == 0) {
            rl.rlim_cur = rl.rlim_max; // unprivileged: at least take the hard limit
            setrlimit(RLIMIT_NOFILE, &rl);
        }
    }
    unsigned long nofile = 0;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0) nofile = (unsigned long)rl.rlim_cur;
    STATS_ON = getenv("STATS") && *getenv("STATS") && strcmp(getenv("STATS"), "0") != 0;
    const char *url = getenv("DATABASE_URL"), *secret = getenv("JWT_SECRET");
    if (!url || !*url || !secret || !*secret) die("DATABASE_URL and JWT_SECRET are required");
    parse_db_url(url);
    hmac_key_init(&CFG.jwt_key, secret, strlen(secret));
    CFG.host = getenv("HOST") && *getenv("HOST") ? getenv("HOST") : "127.0.0.1";
    CFG.port = getenv("PORT") && *getenv("PORT") ? getenv("PORT") : "3000";
    cpu_set_t cs;
    int aff = sched_getaffinity(0, sizeof cs, &cs) == 0 ? CPU_COUNT(&cs) : (int)sysconf(_SC_NPROCESSORS_ONLN);
    if (aff < 1) aff = 1;
    int quota = cgroup_cpu_quota();
    int ncpu = quota > 0 && quota < aff ? quota : aff; // effective CPUs for defaults
    if (ncpu < 1) ncpu = 1;
    // rw: One event loop per 4 CPUs (a loop costs about 0.55 core at 14k req/s). With the per-worker FIFO (pg.pc) a

    // rw: single loop beat two on 4 cores, all else equal: 14.0k vs 13.3k req/s, p95 387-392 vs 434-445 ms at

    // rw: 10,000 users x0.1; three were worse (p95 490-503 ms). Earlier, without the FIFO, one loop starved among ~40

    // rw: busy processes on 6 CPUs and two were best. About four Postgres connections per CPU beat both fewer (idle

    // rw: CPU) and more (more processes fighting for it). On the official 8-core box this yields THREADS=2,

    // rw: DB_CONNS=32, BCRYPT_THREADS=4. Env overrides (below) always win.

    CFG.threads = env_int("THREADS", ncpu / 4 > 0 ? ncpu / 4 : 1);
    CFG.db_conns = env_int("DB_CONNS", ncpu * 4 > 95 ? 95 : ncpu * 4);
    // Own split (rewrite, #58 13R/3W + #7 6R/2W ideas): default 75% read / 25% write, at least 1 write/loop.
    // rw: Env overrides: DB_READ_CONNS, DB_WRITE_CONNS (sum must be <=95, else clamped).

    CFG.db_read_conns = env_int("DB_READ_CONNS", (CFG.db_conns * 3 + 3) / 4);
    CFG.db_write_conns = env_int("DB_WRITE_CONNS", CFG.db_conns - CFG.db_read_conns);
    if (CFG.db_write_conns < CFG.threads) CFG.db_write_conns = CFG.threads < 4 ? CFG.threads : 4;
    if (CFG.db_read_conns + CFG.db_write_conns > 95) {
        CFG.db_read_conns = 95 - CFG.db_write_conns;
    }
    CFG.bcrypt_threads = env_int("BCRYPT_THREADS", ncpu >= 2 ? ncpu / 2 : 1);
    CFG.bcrypt_lanes = env_int("BCRYPT_LANES", BC_LANES);
    // rw: Batches in flight per Postgres connection; the rest wait in one FIFO per worker (pg.pc). Past saturation

    // rw: this makes every request wait in arrival order instead of behind whatever happens to be queued on its

    // rw: connection: at 10,000 users x0.1, p95 465-477 -> 429-432 ms, p99 515-525 -> 456-466 ms, same req/s.

    // rw: 2-4 starve the backends (-4..-7% req/s while the loop refills them); 16..64 are equivalent.

    CFG.pg_depth = env_int("PG_DEPTH", 16);
    CFG.bcrypt_wait_ms = getenv("BCRYPT_WAIT_MS") ? atoi(getenv("BCRYPT_WAIT_MS")) : 40;
    if (CFG.bcrypt_lanes > BC_LANES) CFG.bcrypt_lanes = BC_LANES;
    // rw: Session settings on our own connections. force_generic_plan: every prepared statement keeps one plan

    // rw: instead of being re-planned per execution (pgbench A/B on the full seed: +41% list, +12% article

    // rw: throughput). JIT and parallel workers only cost time on queries this short.

    CFG.pg_session = getenv("PG_SESSION") ? getenv("PG_SESSION")
                                          : "plan_cache_mode=force_generic_plan,jit=off,max_parallel_workers_per_gather=0";
    if (CFG.db_conns < CFG.threads) CFG.db_conns = CFG.threads;
    if (CFG.db_conns > 95) die("DB_CONNS must be at most 95 (max_connections = 100)");

    // rw: 64B-aligned so the aligned(64) hot members land on their own cache lines.

    ev_loop *ws = NULL;
    if (posix_memalign((void **)&ws, 64, (size_t)CFG.threads * sizeof *ws) != 0) die("out of memory");
    memset(ws, 0, (size_t)CFG.threads * sizeof *ws);
    for (int i = 0; i < CFG.threads; i++) {
        ev_loop *ev = &ws[i];
        ev->id = i;
        ev->pin_cpu = -1;
        ev->lfd = listen_socket();
        ev->nread = CFG.db_read_conns / CFG.threads + (i < CFG.db_read_conns % CFG.threads);
        ev->nwrite = CFG.db_write_conns / CFG.threads + (i < CFG.db_write_conns % CFG.threads);
        ev->pg_read = calloc(ev->nread ? ev->nread : 1, sizeof *ev->pg_read);
        ev->pg_write = calloc(ev->nwrite ? ev->nwrite : 1, sizeof *ev->pg_write);
        if (!ev->pg_read || !ev->pg_write) die("out of memory");
        // rw: legacy compat for stats/telemetry that still walks ev->pg/npg: point at read pool

        ev->pg = ev->pg_read; ev->npg = ev->nread;
        if (ev->nread == 0) { ev->nread = 1; }
        if (ev->nwrite == 0) { ev->nwrite = 1; }
        pthread_mutex_init(&ev->mu, NULL);
    }
    // rw: Pin workers + bcrypt to disjoint cores within the quota, leaving >= 4

    // rw: cores for Postgres on roomy boxes (>= 8 usable; 2 on smaller ones).

    // rw: Slots come from the sched_getaffinity mask (first ncpu entries, so a

    // rw: cgroup quota without a smaller mask still bounds us).

    int allowed[CPU_SETSIZE], nallow = 0;
    {
        cpu_set_t m;
        if (sched_getaffinity(0, sizeof m, &m) == 0) {
            for (int pc = 0; pc < CPU_SETSIZE && nallow < (int)(sizeof allowed / sizeof allowed[0]); pc++)
                if (CPU_ISSET(pc, &m)) allowed[nallow++] = pc;
        }
    }
    int usable = nallow > 0 ? nallow : 0;
    if (usable > ncpu) usable = ncpu;
    // rw: Cores for our threads; the rest stay free for Postgres. On roomy boxes

    // rw: (>= 8 usable cores) leave 4 for PG: its per-connection backends scale

    // rw: with DB_CONNS and autovacuum/checkpointer want room too. Smaller boxes

    // rw: keep the old leave-2 rule so a 4-core dev box still runs 2 workers.

    int reserve = usable >= 8 ? 4 : 2;
    int pool = usable > reserve ? usable - reserve : usable; // cores for our threads; rest for PG
    char pinbuf[256] = {0};
    size_t pinlen = 0;
    int *bcrypt_cpu = NULL;
    if (pool > 0) {
        for (int i = 0; i < CFG.threads; i++) {
            ws[i].pin_cpu = allowed[i % pool];
            int ret = snprintf(pinbuf + pinlen, sizeof pinbuf - pinlen, "%sw%d:%d",
                               pinlen ? " " : "", i, ws[i].pin_cpu);
            if (ret < 0) break;
            if ((size_t)ret >= sizeof pinbuf - pinlen) { pinlen = sizeof pinbuf - 1; break; }
            pinlen += (size_t)ret;
        }
        bcrypt_cpu = calloc(CFG.bcrypt_threads > 0 ? CFG.bcrypt_threads : 1, sizeof *bcrypt_cpu);
        if (!bcrypt_cpu) die("out of memory");
        for (int i = 0; i < CFG.bcrypt_threads; i++) {
            bcrypt_cpu[i] = allowed[(CFG.threads + i) % pool];
            int ret = snprintf(pinbuf + pinlen, sizeof pinbuf - pinlen, "%sb%d:%d",
                               pinlen ? " " : "", i, bcrypt_cpu[i]);
            if (ret < 0) break;
            if ((size_t)ret >= sizeof pinbuf - pinlen) { pinlen = sizeof pinbuf - 1; break; }
            pinlen += (size_t)ret;
        }
    } else {
        snprintf(pinbuf, sizeof pinbuf, "none");
    }
    for (int i = 0; i < CFG.bcrypt_threads; i++) {
        pthread_t t;
        pthread_create(&t, NULL, bcrypt_main, bcrypt_cpu ? &bcrypt_cpu[i] : NULL);
    }
    for (int i = 0; i < CFG.threads; i++) pthread_create(&ws[i].th, NULL, worker_main, &ws[i]);
    logf_("listening on %s:%s: %d io_uring workers, %d postgres connections, %d bcrypt threads (cpus=%d affinity=%d quota=%d nofile=%lu pin=[%s])",
          CFG.host, CFG.port, CFG.threads, CFG.db_conns, CFG.bcrypt_threads, ncpu, aff, quota, nofile, pinbuf);
    for (int i = 0; i < CFG.threads; i++) pthread_join(ws[i].th, NULL);
    return 0;
}
