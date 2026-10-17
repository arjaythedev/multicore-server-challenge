// The event loop: one io_uring per worker thread, each with its own SO_REUSEPORT listener and its own Postgres
// connections, sharing nothing. Accepts are multishot; each connection has one multishot readiness poll and is
// read with recv() into the worker's scratch buffer when it fires, so an idle keep-alive connection holds no
// userspace buffer at all. (Provided-buffer rings would save that recv() call, but the Ubuntu 24.04 kernel
// 6.8.0-142 rejects their registration with EINVAL.)
// bcrypt runs on a separate small thread pool so a ~50 ms hash never stalls an event loop.
#include "conduit.h"
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
#include <time.h>
#include <sys/socket.h>
#include <unistd.h>

config_t CFG;

#define RBUF_SIZE 65536
#define MAX_HEADER 65536
#define MAX_BODY (8 << 20)

struct io_uring_sqe *get_sqe(worker_t *w) {
    struct io_uring_sqe *sqe = io_uring_get_sqe(&w->ring);
    while (UNLIKELY(!sqe)) {
        io_uring_submit(&w->ring);
        sqe = io_uring_get_sqe(&w->ring);
    }
    return sqe;
}

// ---------- bcrypt pool ----------

static pthread_mutex_t jobs_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t jobs_cv = PTHREAD_COND_INITIALIZER;
static job_t *jobs_head, *jobs_tail;
static int jobs_n;
static bool gathering;

void submit_job(job_t *j) {
    j->next = NULL;
    if (UNLIKELY(STATS_ON)) j->t0 = stats_now();
    pthread_mutex_lock(&jobs_mu);
    if (jobs_tail) jobs_tail->next = j;
    else jobs_head = j;
    jobs_tail = j;
    jobs_n++;
    pthread_cond_broadcast(&jobs_cv);
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
    worker_t *w = j->r->w;
    pthread_mutex_lock(&w->mu);
    j->next = w->done;
    w->done = j;
    pthread_mutex_unlock(&w->mu);
    uint64_t one = 1;
    if (write(w->efd, &one, 8) < 0 && errno != EAGAIN) die("eventfd write: %s", strerror(errno));
}

// Takes up to bcrypt_lanes queued jobs at a time and computes those with the same cost together (bcrypt.c).
// Anything bcrypt.c doesn't handle (another hash format) goes through libxcrypt.
static void *bcrypt_main(void *arg) {
    pthread_setname_np(pthread_self(), "bcrypt");
    struct crypt_data *cd = calloc(1, sizeof *cd);
    if (!cd) die("out of memory");
    for (;;) {
        job_t *batch[BC_LANES];
        int n = 0;
        pthread_mutex_lock(&jobs_mu);
        // A fuller batch costs much less CPU per hash (4 lanes: half), so one thread at a time (the gatherer)
        // lets a login wait up to BCRYPT_WAIT_MS for others to share its batch; the other threads start only
        // on a full batch. Logins are ~0.1% of requests; the wait buys CPU for all the others.
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
        pthread_cond_broadcast(&jobs_cv); // whatever is left may need a new gatherer
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
            int c = bc_cost(s);
            if (c >= 0 && (cost < 0 || c == cost)) {
                cost = c;
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

// `conduit --bcrypt-selftest`: compares bcrypt.c with libxcrypt on random passwords and salts, then times it.
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

static void arm_event(worker_t *w) {
    struct io_uring_sqe *sqe = get_sqe(w);
    io_uring_prep_read(sqe, w->efd, &w->efd_val, 8, 0);
    io_uring_sqe_set_data64(sqe, UD(w, UD_EVENT));
}

static void on_event(worker_t *w) {
    pthread_mutex_lock(&w->mu);
    job_t *j = w->done;
    w->done = NULL;
    pthread_mutex_unlock(&w->mu);
    while (j) {
        job_t *next = j->next;
        if (UNLIKELY(STATS_ON)) stats_bc_done(w, j->t0);
        j->cb(j->r, j);
        j = next;
    }
    arm_event(w);
}

// ---------- connections ----------

static void conn_process(conn_t *c);

static void conn_arm_recv(conn_t *c) {
    struct io_uring_sqe *sqe = get_sqe(c->w);
    io_uring_prep_poll_multishot(sqe, c->fd, POLLIN | POLLRDHUP);
    io_uring_sqe_set_data64(sqe, UD(c, UD_RECV));
    c->recv_armed = true;
}

static void conn_maybe_free(conn_t *c) {
    if (!c->closing || c->recv_armed || c->send_inflight || c->req) return;
    if (UNLIKELY(STATS_ON)) stats_conn(c->w, -1);
    close(c->fd);
    buf_free(&c->in);
    buf_free(&c->out);
    buf_free(&c->sending);
    free(c);
}

// Starts closing: cancels the readiness poll (its final completion clears recv_armed), and the conn is freed
// once nothing refers to it any more.
static void conn_close(conn_t *c) {
    if (!c->closing) {
        c->closing = true;
        if (c->recv_armed) {
            struct io_uring_sqe *sqe = get_sqe(c->w);
            io_uring_prep_poll_remove(sqe, UD(c, UD_RECV));
            io_uring_sqe_set_data64(sqe, 0);
        }
    }
    conn_maybe_free(c);
}

// Responses are appended to c->out; a send owns c->sending until it completes, so appending (and
// reallocating) never moves bytes the kernel is still reading.
static void conn_flush(conn_t *c) {
    if (c->send_inflight || c->out.len == 0) return;
    c->sending = c->out;
    c->out = (buf_t){0};
    c->out_off = 0;
    struct io_uring_sqe *sqe = get_sqe(c->w);
    io_uring_prep_send(sqe, c->fd, c->sending.p, c->sending.len, MSG_NOSIGNAL);
    io_uring_sqe_set_data64(sqe, UD(c, UD_SEND));
    c->send_inflight = true;
}

static void conn_on_send(conn_t *c, int res) {
    c->send_inflight = false;
    if (res < 0) {
        buf_free(&c->sending);
        c->peer_closed = true;
        conn_close(c);
        return;
    }
    c->out_off += res;
    if (c->out_off < c->sending.len && !c->closing) {
        struct io_uring_sqe *sqe = get_sqe(c->w);
        io_uring_prep_send(sqe, c->fd, c->sending.p + c->out_off, c->sending.len - c->out_off, MSG_NOSIGNAL);
        io_uring_sqe_set_data64(sqe, UD(c, UD_SEND));
        c->send_inflight = true;
        return;
    }
    buf_free(&c->sending);
    if (c->closing) { conn_maybe_free(c); return; }
    conn_flush(c);
    if (!c->send_inflight && c->peer_closed && !c->req) conn_close(c);
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

static void write_response(conn_t *c, int status, const buf_t *body, bool keepalive) {
    buf_t *o = &c->out;
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

static void req_free(req_t *r) {
    arena_free(&r->arena);
    free(r);
}

void reply(req_t *r, int status, const buf_t *body) {
    conn_t *c = r->c;
    bool keepalive = r->keepalive;
    c->req = NULL;
    if (UNLIKELY(STATS_ON)) stats_req_done(r->w, r->t0);
    req_free(r);
    if (c->closing) { conn_maybe_free(c); return; }
    write_response(c, status, body, keepalive);
    if (!keepalive) c->peer_closed = true; // stop reading; close once the response is out
    conn_flush(c);
    if (c->peer_closed) {
        if (!c->send_inflight) conn_close(c);
        return;
    }
    if (!c->processing) conn_process(c);
}

void reply_err(req_t *r, int status, const char *msg) {
    buf_t *b = &r->w->body;
    b->len = 0;
    buf_lit(b, "{\"errors\":{\"body\":[");
    buf_json_str(b, msg, strlen(msg));
    buf_lit(b, "]}}");
    reply(r, status, b);
}

static void conn_fail(conn_t *c, int status, const char *msg) {
    buf_t b = {0};
    buf_lit(&b, "{\"errors\":{\"body\":[\"");
    buf_put(&b, msg, strlen(msg));
    buf_lit(&b, "\"]}}");
    write_response(c, status, &b, false);
    buf_free(&b);
    buf_free(&c->in);
    c->peer_closed = true;
    conn_flush(c);
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

static int unhex(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    c |= 0x20;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

// Percent-decodes in place; false on a malformed escape.
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

// Parses one request from c->in. 1: dispatched, 0: need more bytes, -1: protocol error (connection closing).
static int conn_parse(conn_t *c) {
    char *in = c->in.p;
    size_t len = c->in.len;
    char *end = len >= 4 ? memmem(in, len, "\r\n\r\n", 4) : NULL;
    if (!end) {
        if (len > MAX_HEADER) { conn_fail(c, 431, "headers too large"); return -1; }
        return 0;
    }
    size_t hlen = end - in + 4;
    char *line_end = memchr(in, '\r', hlen);
    // request line: METHOD SP target SP HTTP/1.x
    char *sp1 = memchr(in, ' ', line_end - in);
    char *sp2 = sp1 ? memchr(sp1 + 1, ' ', line_end - sp1 - 1) : NULL;
    if (!sp1 || !sp2 || line_end - sp2 - 1 != 8 || memcmp(sp2 + 1, "HTTP/1.", 7) != 0) {
        conn_fail(c, 400, "bad request line");
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
                if (!parse_uint(v, ve - v, &n) || (have_clen && n != clen)) { conn_fail(c, 400, "bad content-length"); return -1; }
                clen = n;
                have_clen = true;
            } else if (hdr_is(p, nl, "authorization")) {
                if (!have_auth) { a_off = v - in; a_len = ve - v; have_auth = true; }
            } else if (hdr_is(p, nl, "connection")) {
                if (has_token(v, ve - v, "close")) keepalive = false;
                else if (http10 && has_token(v, ve - v, "keep-alive")) keepalive = true;
            } else if (hdr_is(p, nl, "transfer-encoding")) {
                conn_fail(c, 400, "transfer-encoding not supported");
                return -1;
            }
        }
        p = e + 2;
    }
    if (clen > MAX_BODY) { conn_fail(c, 413, "body too large"); return -1; }
    size_t total = hlen + clen;
    if (len < total) return 0;

    req_t *r = calloc(1, sizeof *r);
    if (!r) die("out of memory");
    r->c = c;
    r->w = c->w;
    r->keepalive = keepalive;
    if (UNLIKELY(STATS_ON)) r->t0 = stats_now();
    char *raw = arena_alloc(&r->arena, total + 1);
    memcpy(raw, in, total);
    raw[total] = 0;
    memmove(in, in + total, len - total);
    c->in.len -= total;
    if (c->in.len == 0) buf_free(&c->in);

    const char *m = raw + m_off;
    r->method = m_len == 3 && !memcmp(m, "GET", 3) ? M_GET
              : m_len == 4 && !memcmp(m, "POST", 4) ? M_POST
              : m_len == 3 && !memcmp(m, "PUT", 3) ? M_PUT
              : m_len == 6 && !memcmp(m, "DELETE", 6) ? M_DELETE : M_OTHER;
    if (have_auth) r->auth = (str_t){raw + a_off, a_len};
    r->body = (str_t){raw + hlen, (size_t)clen};
    char *t = raw + t_off;
    char *q = memchr(t, '?', t_len);
    size_t plen = q ? (size_t)(q - t) : t_len;
    if (q) r->query = (str_t){q + 1, t_len - plen - 1};
    r->path = (str_t){t, plen};

    // Split /api/<seg>/<seg>/... and decode each segment.
    c->req = r;
    if (plen < 5 || memcmp(t, "/api/", 5) != 0) { r->nseg = -1; return 1; }
    char *s = t + 5, *pe = t + plen;
    for (;;) {
        char *slash = memchr(s, '/', pe - s);
        char *se = slash ? slash : pe;
        if (r->nseg == 6) { r->nseg = -1; break; }
        size_t n = se - s;
        if (!pct_decode(s, &n)) { r->nseg = -2; break; }
        r->seg[r->nseg++] = (str_t){s, n};
        if (!slash) break;
        s = slash + 1;
    }
    return 1;
}

static void conn_process(conn_t *c) {
    c->processing = true;
    while (!c->req && !c->closing && !c->peer_closed && c->in.len) {
        int rc = conn_parse(c);
        if (rc <= 0) break;
        req_t *r = c->req;
        if (r->nseg == -2) { reply_err(r, 400, "bad path escape"); continue; }
        api_dispatch(r);
    }
    c->processing = false;
    if (c->peer_closed && !c->closing && !c->req && !c->send_inflight) conn_close(c);
}

static void conn_on_recv(conn_t *c, struct io_uring_cqe *cqe) {
    worker_t *w = c->w;
    if (!(cqe->flags & IORING_CQE_F_MORE)) c->recv_armed = false;
    if (c->closing) { conn_maybe_free(c); return; }
    bool eof = cqe->res < 0;
    while (!eof) {
        ssize_t n = recv(c->fd, w->rbuf, RBUF_SIZE, MSG_DONTWAIT);
        if (n > 0) {
            if (!c->peer_closed) buf_put(&c->in, w->rbuf, n);
            if (n < RBUF_SIZE) break;
        } else if (n == 0) {
            eof = true;
        } else if (errno != EINTR) {
            if (errno != EAGAIN && errno != EWOULDBLOCK) eof = true;
            break;
        }
    }
    if (!eof && !c->recv_armed && !c->peer_closed) conn_arm_recv(c);
    conn_process(c); // answer whatever complete requests arrived, even if the client is now gone
    if (!eof) return;
    c->peer_closed = true;
    if (!c->req && !c->send_inflight) conn_close(c);
}

static void on_accept(worker_t *w, struct io_uring_cqe *cqe) {
    if (cqe->res >= 0) {
        int fd = cqe->res;
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        conn_t *c = calloc(1, sizeof *c);
        if (!c) die("out of memory");
        c->w = w;
        c->fd = fd;
        if (UNLIKELY(STATS_ON)) stats_conn(w, 1);
        conn_arm_recv(c);
    } else if (cqe->res != -EAGAIN && cqe->res != -EINTR && cqe->res != -ECONNABORTED) {
        logf_("accept: %s", strerror(-cqe->res));
    }
    if (!(cqe->flags & IORING_CQE_F_MORE)) {
        struct io_uring_sqe *sqe = get_sqe(w);
        io_uring_prep_multishot_accept(sqe, w->lfd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
        io_uring_sqe_set_data64(sqe, UD(w, UD_ACCEPT));
    }
}

// ---------- worker ----------

static void *worker_main(void *arg) {
    worker_t *w = arg;
    pthread_setname_np(pthread_self(), "loop");
    for (int i = 0; i < w->npg; i++) pg_connect(&w->pg[i], w);
    if (STATS_ON) stats_init(w);

    struct io_uring_params p = {0};
    p.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN | IORING_SETUP_COOP_TASKRUN | IORING_SETUP_CQSIZE;
    p.cq_entries = 32768;
    int ret = io_uring_queue_init_params(4096, &w->ring, &p);
    if (ret == -EINVAL) {
        memset(&p, 0, sizeof p);
        p.flags = IORING_SETUP_CQSIZE;
        p.cq_entries = 32768;
        ret = io_uring_queue_init_params(4096, &w->ring, &p);
    }
    if (ret < 0) die("io_uring_queue_init: %s (is io_uring enabled? sysctl kernel.io_uring_disabled)", strerror(-ret));

    w->rbuf = malloc(RBUF_SIZE);
    if (!w->rbuf) die("out of memory");

    w->efd = eventfd(0, EFD_CLOEXEC);
    if (w->efd < 0) die("eventfd: %s", strerror(errno));
    arm_event(w);
    struct io_uring_sqe *sqe = get_sqe(w);
    io_uring_prep_multishot_accept(sqe, w->lfd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
    io_uring_sqe_set_data64(sqe, UD(w, UD_ACCEPT));
    for (int i = 0; i < w->npg; i++) pg_arm_recv(&w->pg[i]);

    for (;;) {
        for (int i = 0; i < w->npg; i++) pg_flush(&w->pg[i]);
        ret = io_uring_submit_and_wait(&w->ring, 1);
        if (ret < 0 && ret != -EINTR && ret != -EAGAIN && ret != -EBUSY) die("io_uring_submit_and_wait: %s", strerror(-ret));
        uint64_t t_wake = UNLIKELY(STATS_ON) ? stats_now() : 0;
        struct io_uring_cqe *cqe;
        unsigned head, n = 0;
        io_uring_for_each_cqe(&w->ring, head, cqe) {
            n++;
            uint64_t ud = cqe->user_data;
            void *ptr = (void *)(uintptr_t)(ud & ~(uint64_t)7);
            switch (ud & 7) {
            case UD_ACCEPT: on_accept(w, cqe); break;
            case UD_RECV: conn_on_recv(ptr, cqe); break;
            case UD_SEND: conn_on_send(ptr, cqe->res); break;
            case UD_PGRECV: pg_on_recv(ptr, cqe->res); break;
            case UD_PGSEND: pg_on_send(ptr, cqe->res); break;
            case UD_EVENT: on_event(w); break;
            }
        }
        io_uring_cq_advance(&w->ring, n);
        if (UNLIKELY(STATS_ON)) stats_loop(w, t_wake, n);
    }
    return NULL;
}

// ---------- startup ----------

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

// postgres://user:pass@host:port/db[?...]
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

int main(int argc, char **argv) {
    setvbuf(stderr, NULL, _IOLBF, 0);
    if (argc > 1 && !strcmp(argv[1], "--bcrypt-selftest")) return bcrypt_selftest();
    signal(SIGPIPE, SIG_IGN);
    STATS_ON = getenv("STATS") && *getenv("STATS") && strcmp(getenv("STATS"), "0") != 0;
    const char *url = getenv("DATABASE_URL"), *secret = getenv("JWT_SECRET");
    if (!url || !*url || !secret || !*secret) die("DATABASE_URL and JWT_SECRET are required");
    parse_db_url(url);
    hmac_key_init(&CFG.jwt_key, secret, strlen(secret));
    CFG.host = getenv("HOST") && *getenv("HOST") ? getenv("HOST") : "127.0.0.1";
    CFG.port = getenv("PORT") && *getenv("PORT") ? getenv("PORT") : "3000";
    cpu_set_t cs;
    int ncpu = sched_getaffinity(0, sizeof cs, &cs) == 0 ? CPU_COUNT(&cs) : (int)sysconf(_SC_NPROCESSORS_ONLN);
    if (ncpu < 1) ncpu = 1;
    // One event loop per 4 CPUs (a loop costs about 0.55 core at 14k req/s). With the per-worker FIFO (pg.c) a
    // single loop beat two on 4 cores, all else equal: 14.0k vs 13.3k req/s, p95 387-392 vs 434-445 ms at
    // 10,000 users x0.1; three were worse (p95 490-503 ms). Earlier, without the FIFO, one loop starved among ~40
    // busy processes on 6 CPUs and two were best. About four Postgres connections per CPU beat both fewer (idle
    // CPU) and more (more processes fighting for it).
    CFG.threads = env_int("THREADS", ncpu >= 8 ? ncpu / 4 : 1);
    CFG.db_conns = env_int("DB_CONNS", ncpu * 4 > 95 ? 95 : ncpu * 4);
    CFG.bcrypt_threads = env_int("BCRYPT_THREADS", ncpu >= 2 ? ncpu / 2 : 1);
    CFG.bcrypt_lanes = env_int("BCRYPT_LANES", BC_LANES);
    // Batches in flight per Postgres connection; the rest wait in one FIFO per worker (pg.c). Past saturation
    // this makes every request wait in arrival order instead of behind whatever happens to be queued on its
    // connection: at 10,000 users x0.1, p95 465-477 -> 429-432 ms, p99 515-525 -> 456-466 ms, same req/s.
    // 2-4 starve the backends (-4..-7% req/s while the loop refills them); 16..64 are equivalent.
    CFG.pg_depth = env_int("PG_DEPTH", 16);
    CFG.bcrypt_wait_ms = getenv("BCRYPT_WAIT_MS") ? atoi(getenv("BCRYPT_WAIT_MS")) : 150;
    if (CFG.bcrypt_lanes > BC_LANES) CFG.bcrypt_lanes = BC_LANES;
    // Session settings on our own connections. force_generic_plan: every prepared statement keeps one plan
    // instead of being re-planned per execution (pgbench A/B on the full seed: +41% list, +12% article
    // throughput). JIT and parallel workers only cost time on queries this short.
    CFG.pg_session = getenv("PG_SESSION") ? getenv("PG_SESSION")
                                          : "plan_cache_mode=force_generic_plan,jit=off,max_parallel_workers_per_gather=0";
    if (CFG.db_conns < CFG.threads) CFG.db_conns = CFG.threads;
    if (CFG.db_conns > 95) die("DB_CONNS must be at most 95 (max_connections = 100)");

    worker_t *ws = calloc(CFG.threads, sizeof *ws);
    for (int i = 0; i < CFG.threads; i++) {
        worker_t *w = &ws[i];
        w->id = i;
        w->lfd = listen_socket();
        w->npg = CFG.db_conns / CFG.threads + (i < CFG.db_conns % CFG.threads);
        w->pg = calloc(w->npg, sizeof *w->pg);
        pthread_mutex_init(&w->mu, NULL);
    }
    for (int i = 0; i < CFG.bcrypt_threads; i++) {
        pthread_t t;
        pthread_create(&t, NULL, bcrypt_main, NULL);
    }
    for (int i = 0; i < CFG.threads; i++) pthread_create(&ws[i].th, NULL, worker_main, &ws[i]);
    logf_("listening on %s:%s: %d io_uring workers, %d postgres connections, %d bcrypt threads", CFG.host, CFG.port,
          CFG.threads, CFG.db_conns, CFG.bcrypt_threads);
    for (int i = 0; i < CFG.threads; i++) pthread_join(ws[i].th, NULL);
    return 0;
}
