// Event-loop threads (liburing), HTTP/1.1 keep-alive parser, response writer, and main().
#include "conduit.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <strings.h>
#include <sys/eventfd.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>

#define RING_ENTRIES 4096
#define MAX_REQ_BYTES (256 * 1024)
#define RX_SCRATCH_BYTES (256 * 1024)

static char bind_host[64] = "0.0.0.0";
static int bind_port = 8000;
static int cfg_npg_r = 6;
static int cfg_npg_w = 2;

enum { T_ACCEPT = 1, T_CLIENT_POLL, T_CLIENT_SEND, T_PG_RECV, T_PG_SEND, T_BCRYPT_EVENT };
static inline uint64_t tag_ptr(int tag, void *p) { return ((uint64_t)tag << 56) | (uint64_t)(uintptr_t)p; }
static inline int ptr_tag(uint64_t d) { return (int)(d >> 56); }
static inline void *untag_ptr(uint64_t d) { return (void *)(uintptr_t)(d & ((1ULL << 56) - 1)); }

static struct io_uring_sqe *get_sqe(worker_t *w) {
    struct io_uring_sqe *sqe = io_uring_get_sqe(&w->ring);
    if (!sqe) {
        io_uring_submit(&w->ring);
        sqe = io_uring_get_sqe(&w->ring);
    }
    return sqe;
}

static void arm_accept(worker_t *w) {
    struct io_uring_sqe *sqe = get_sqe(w);
    io_uring_prep_multishot_accept(sqe, w->lfd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
    io_uring_sqe_set_data64(sqe, tag_ptr(T_ACCEPT, NULL));
}

static uint64_t evfd_sink;
static void arm_evfd(worker_t *w) {
    struct io_uring_sqe *sqe = get_sqe(w);
    io_uring_prep_read(sqe, w->evfd, &evfd_sink, 8, 0);
    io_uring_sqe_set_data64(sqe, tag_ptr(T_BCRYPT_EVENT, NULL));
}

static void close_req(req_t *r) {
    worker_t *w = r->w;
    if (r->fd >= 0) {
        if (__builtin_expect(STATS_ON, 0)) stats_conn(w, -1);
        shutdown(r->fd, SHUT_RDWR);
        close(r->fd);
        r->fd = -1;
    }
    if (r->poll_armed) {
        if (!r->closing) {
            r->closing = true;
            struct io_uring_sqe *sqe = get_sqe(w);
            io_uring_prep_poll_remove(sqe, tag_ptr(T_CLIENT_POLL, r));
            io_uring_sqe_set_data64(sqe, 0);
        }
        return;
    }
    arena_reset(&r->arena);
    buf_free(&r->in);
    buf_free(&r->out);
    r->ctx = w->free_req;
    w->free_req = r;
}

static void arm_client_poll(req_t *r) {
    if (r->poll_armed) return;
    struct io_uring_sqe *sqe = get_sqe(r->w);
    io_uring_prep_poll_multishot(sqe, r->fd, POLLIN);
    io_uring_sqe_set_data64(sqe, tag_ptr(T_CLIENT_POLL, r));
    r->poll_armed = true;
}

static void arm_client_send(req_t *r) {
    struct io_uring_sqe *sqe = get_sqe(r->w);
    io_uring_prep_send(sqe, r->fd, r->out.p + r->out_sp, r->out.len - r->out_sp, MSG_NOSIGNAL);
    io_uring_sqe_set_data64(sqe, tag_ptr(T_CLIENT_SEND, r));
}

// ---------- HTTP/1.1 request parser ----------

static int parse_http(req_t *r, const char *b, size_t len, size_t *consumed) {
    const char *hend = memmem(b, len, "\r\n\r\n", 4);
    if (!hend) return len > 16384 ? -1 : 0;

    const char *lend = memchr(b, '\r', (size_t)(hend - b));
    if (!lend) return -1;
    const char *sp1 = memchr(b, ' ', (size_t)(lend - b));
    if (!sp1) return -1;
    const char *sp2 = memchr(sp1 + 1, ' ', (size_t)(lend - (sp1 + 1)));
    if (!sp2) return -1;

    size_t mlen = (size_t)(sp1 - b);
    if (mlen == 3 && memcmp(b, "GET", 3) == 0) r->method = M_GET;
    else if (mlen == 4 && memcmp(b, "POST", 4) == 0) r->method = M_POST;
    else if (mlen == 3 && memcmp(b, "PUT", 3) == 0) r->method = M_PUT;
    else if (mlen == 6 && memcmp(b, "DELETE", 6) == 0) r->method = M_DELETE;
    else r->method = M_OTHER;

    const char *uri = sp1 + 1;
    size_t ulen = (size_t)(sp2 - uri);
    const char *qm = memchr(uri, '?', ulen);
    if (qm) {
        r->path = (str_t){uri, (size_t)(qm - uri)};
        r->query = (str_t){qm + 1, (size_t)(sp2 - (qm + 1))};
    } else {
        r->path = (str_t){uri, ulen};
        r->query = (str_t){"", 0};
    }

    r->keep_alive = !(sp2 + 9 <= lend && memcmp(sp2 + 1, "HTTP/1.0", 8) == 0);
    r->auth = (str_t){NULL, 0};
    int64_t clen = 0;

    const char *p = lend + 2;
    while (p < hend) {
        const char *eol = memchr(p, '\r', (size_t)(hend + 1 - p));
        if (!eol) return -1;
        const char *col = memchr(p, ':', (size_t)(eol - p));
        if (col) {
            size_t kn = (size_t)(col - p);
            const char *vp = col + 1;
            while (vp < eol && (*vp == ' ' || *vp == '\t')) vp++;
            const char *ve = eol;
            while (ve > vp && (ve[-1] == ' ' || ve[-1] == '\t')) ve--;
            size_t vn = (ve > vp) ? (size_t)(ve - vp) : 0;

            if (kn == 14 && strncasecmp(p, "Content-Length", 14) == 0) {
                if (!parse_uint(vp, vn, &clen) || clen > MAX_REQ_BYTES) return -1;
            } else if (kn == 13 && strncasecmp(p, "Authorization", 13) == 0) {
                r->auth = (str_t){vp, vn};
            } else if (kn == 10 && strncasecmp(p, "Connection", 10) == 0) {
                if (vn == 5 && strncasecmp(vp, "close", 5) == 0) r->keep_alive = false;
                else if (vn == 10 && strncasecmp(vp, "keep-alive", 10) == 0) r->keep_alive = true;
            }
        }
        p = eol + 2;
    }

    size_t hbytes = (size_t)(hend + 4 - b);
    size_t total = hbytes + (size_t)clen;
    if (len < total) return 0;

    r->body = (str_t){b + hbytes, (size_t)clen};
    *consumed = total;

    r->nseg = 0;
    if (r->path.n < 4 || memcmp(r->path.p, "/api", 4) != 0 || (r->path.n > 4 && r->path.p[4] != '/')) {
        r->nseg = -1;
        return 1;
    }
    const char *sp = r->path.p + (r->path.n > 4 ? 5 : 4), *se = r->path.p + r->path.n;
    while (sp < se && se[-1] == '/') se--;
    while (sp < se) {
        if (r->nseg >= 5) { r->nseg = -1; return 1; }
        const char *sl = memchr(sp, '/', (size_t)(se - sp));
        if (!sl) sl = se;
        size_t slen = (size_t)(sl - sp);
        char *dec = arena_alloc(&r->arena, slen + 1);
        int dn = url_decode(dec, sp, slen);
        if (dn < 0) { r->nseg = -1; return 1; }
        dec[dn] = 0;
        r->seg[r->nseg++] = (str_t){dec, (size_t)dn};
        sp = sl + 1;
    }
    return 1;
}

static void on_client_recv(req_t *r);

static const char *status_text(int s) {
    switch (s) {
    case 200: return "200 OK";
    case 201: return "201 Created";
    case 204: return "204 No Content";
    case 401: return "401 Unauthorized";
    case 403: return "403 Forbidden";
    case 404: return "404 Not Found";
    case 422: return "422 Unprocessable Entity";
    default:  return "500 Internal Server Error";
    }
}

static void after_response_sent(req_t *r) {
    if (__builtin_expect(STATS_ON, 0)) stats_req_done(r->w, r->t_start);
    buf_free(&r->out);
    arena_reset(&r->arena);
    r->busy = false;
    if (!r->keep_alive) {
        close_req(r);
        return;
    }
    if (r->in.len > 0) {
        on_client_recv(r);
        return;
    }
    arm_client_poll(r);
}

static inline size_t format_u64_fast(char *dst, uint64_t u) {
    char tmp[24];
    int i = 24;
    do {
        tmp[--i] = (char)('0' + (u % 10));
        u /= 10;
    } while (u);
    size_t n = 24 - (size_t)i;
    memcpy(dst, tmp + i, n);
    return n;
}

void reply(req_t *r, int status, const buf_t *body) {
    size_t blen = body ? body->len : 0;
    const char *conn = r->keep_alive ? "keep-alive" : "close";
    int hlen;
    if (__builtin_expect(status == 200 && r->keep_alive, 1)) {
        static const char pfx[] = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nConnection: keep-alive\r\nContent-Length: ";
        memcpy(r->hdr_Out, pfx, sizeof(pfx) - 1);
        hlen = (int)(sizeof(pfx) - 1);
        hlen += (int)format_u64_fast(r->hdr_Out + hlen, blen);
        memcpy(r->hdr_Out + hlen, "\r\n\r\n", 4);
        hlen += 4;
    } else if (status == 204) {
        hlen = snprintf(r->hdr_Out, sizeof r->hdr_Out,
                        "HTTP/1.1 204 No Content\r\nConnection: %s\r\nContent-Length: 0\r\n\r\n", conn);
    } else {
        hlen = snprintf(r->hdr_Out, sizeof r->hdr_Out,
                        "HTTP/1.1 %s\r\nContent-Type: application/json; charset=utf-8\r\nConnection: %s\r\nContent-Length: %zu\r\n\r\n",
                        status_text(status), conn, blen);
    }

    struct iovec iov[2] = {{r->hdr_Out, (size_t)hlen}, {body ? body->p : NULL, blen}};
    int iovcnt = blen ? 2 : 1;
    size_t total = (size_t)hlen + blen;
    ssize_t n;
    do {
        n = writev(r->fd, iov, iovcnt);
    } while (n < 0 && errno == EINTR);

    if (n == (ssize_t)total) {
        after_response_sent(r);
        return;
    }
    size_t done = n > 0 ? (size_t)n : 0;
    if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
        close_req(r);
        return;
    }
    r->out.len = 0;
    r->out_sp = 0;
    if (done < (size_t)hlen) {
        buf_put(&r->out, r->hdr_Out + done, (size_t)hlen - done);
        if (blen) buf_put(&r->out, body->p, blen);
    } else {
        size_t bdone = done - (size_t)hlen;
        buf_put(&r->out, body->p + bdone, blen - bdone);
    }
    arm_client_send(r);
}

void reply_err(req_t *r, int status, const char *msg) {
    buf_t *b = &r->w->body;
    b->len = 0;
    buf_lit(b, "{\"errors\":{\"body\":[");
    buf_json_str(b, msg, strlen(msg));
    buf_lit(b, "]}}");
    reply(r, status, b);
}

static void on_client_recv(req_t *r) {
    if (r->busy || r->fd < 0) return;
    worker_t *w = r->w;

    for (;;) {
        const char *buf;
        size_t len;
        if (r->in.len == 0) {
            ssize_t n = recv(r->fd, w->rx_scratch, RX_SCRATCH_BYTES, 0);
            if (n == 0) { close_req(r); return; }
            if (n < 0) {
                if (errno == EINTR) continue;
                if (errno == EAGAIN || errno == EWOULDBLOCK) { arm_client_poll(r); return; }
                close_req(r);
                return;
            }
            buf = w->rx_scratch;
            len = (size_t)n;
        } else {
            buf_reserve(&r->in, 4096);
            ssize_t n = recv(r->fd, r->in.p + r->in.len, r->in.cap - r->in.len, 0);
            if (n > 0) r->in.len += (size_t)n;
            else if (n == 0) { close_req(r); return; }
            else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { close_req(r); return; }
            buf = r->in.p;
            len = r->in.len;
        }

        r->viewer = 0;
        r->token = (str_t){NULL, 0};
        r->kind = 0;
        if (__builtin_expect(STATS_ON, 0)) r->t_start = stats_now();

        size_t consumed = 0;
        int pr = parse_http(r, buf, len, &consumed);
        if (pr < 0) { close_req(r); return; }
        if (pr == 0) {
            if (buf == w->rx_scratch) buf_put(&r->in, buf, len);
            if (r->in.len > MAX_REQ_BYTES + 16384) { close_req(r); return; }
            arm_client_poll(r);
            return;
        }

        size_t rem = len - consumed;
        if (buf == w->rx_scratch) {
            if (rem > 0) buf_put(&r->in, buf + consumed, rem);
        } else {
            if (rem > 0) {
                memmove(r->in.p, r->in.p + consumed, rem);
                r->in.len = rem;
            } else {
                buf_free(&r->in);
            }
        }

        r->busy = true;
        api_dispatch(r);
        return;
    }
}

static void on_client_send(req_t *r, int res) {
    if (res <= 0) { close_req(r); return; }
    r->out_sp += (size_t)res;
    if (r->out_sp < r->out.len) {
        arm_client_send(r);
        return;
    }
    after_response_sent(r);
}

static void on_accept(worker_t *w, int cfd) {
    if (cfd < 0) return;
    int one = 1;
    setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);

    req_t *r = w->free_req;
    if (r) w->free_req = r->ctx;
    else r = calloc(1, sizeof(req_t));
    if (!r) { close(cfd); return; }
    memset(r, 0, offsetof(req_t, arena));
    r->w = w;
    r->fd = cfd;
    r->keep_alive = true;
    if (__builtin_expect(STATS_ON, 0)) stats_conn(w, +1);
    arm_client_poll(r);
}

static void on_bcrypt_event(worker_t *w) {
    pthread_mutex_lock(&w->done_mu);
    job_t *list = w->done_head;
    w->done_head = NULL;
    pthread_mutex_unlock(&w->done_mu);

    while (list) {
        job_t *nx = list->done_next;
        if (__builtin_expect(STATS_ON, 0)) stats_bc_done(w, list->t_enq);
        list->cb(list->r, list);
        list = nx;
    }
}

static int make_listen_socket(void) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) die("socket listen");
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);

    struct sockaddr_in sa = {.sin_family = AF_INET, .sin_port = htons((uint16_t)bind_port)};
    if (inet_pton(AF_INET, bind_host, &sa.sin_addr) != 1) sa.sin_addr.s_addr = INADDR_ANY;
    if (bind(fd, (struct sockaddr *)&sa, sizeof sa) < 0) die("bind");
    if (listen(fd, 65535) < 0) die("listen");
    return fd;
}

static void handle_cqe(worker_t *w, struct io_uring_cqe *cqe) {
    uint64_t d = io_uring_cqe_get_data64(cqe);
    if (d == 0) return;
    int tag = ptr_tag(d);
    void *ptr = untag_ptr(d);
    int res = cqe->res;

    switch (tag) {
    case T_ACCEPT:
        if (res >= 0) on_accept(w, res);
        if (!(cqe->flags & IORING_CQE_F_MORE)) arm_accept(w);
        break;
    case T_CLIENT_POLL: {
        req_t *r = ptr;
        if (!(cqe->flags & IORING_CQE_F_MORE)) r->poll_armed = false;
        if (r->closing) {
            if (!r->poll_armed) close_req(r);
            break;
        }
        if (res < 0 || (res & (POLLERR | POLLHUP | POLLNVAL))) {
            close_req(r);
            break;
        }
        on_client_recv(r);
        break;
    }
    case T_CLIENT_SEND:
        on_client_send(ptr, res);
        break;
    case T_PG_RECV:
        pg_readable(ptr, res);
        break;
    case T_PG_SEND:
        pg_send_done(ptr, res);
        break;
    case T_BCRYPT_EVENT:
        arm_evfd(w);
        on_bcrypt_event(w);
        break;
    default:
        break;
    }
}

static void *worker_main(void *arg) {
    worker_t *w = arg;
    // Pin worker thread to physical core to eliminate context switching and maximize L1/L2 hits
    int total_cpus = count_cpus();
    if (total_cpus > 0) {
        cpu_set_t cpuset;
        CPU_ZERO(&cpuset);
        CPU_SET(w->id % total_cpus, &cpuset);
        pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);
    }
    pthread_mutex_init(&w->done_mu, NULL);
    w->rx_scratch = malloc(RX_SCRATCH_BYTES);
    if (!w->rx_scratch) die("malloc rx_scratch");
    for (int i = 0; i < 4; i++) buf_reserve(&w->scratch[i], 4096);
    if (STATS_ON) stats_init(w);
    w->lfd = make_listen_socket();
    w->evfd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (w->evfd < 0) die("eventfd");

    struct io_uring_params p = {0};
    const char *sqp = getenv("SQPOLL");
    if (sqp && atoi(sqp) > 0) {
        p.flags |= IORING_SETUP_SQPOLL;
        p.sq_thread_idle = 2000;
    }
    if (io_uring_queue_init_params(RING_ENTRIES, &w->ring, &p) < 0) die("io_uring_queue_init");

    pg_worker_init(w, cfg_npg_r, cfg_npg_w);
    arm_accept(w);
    arm_evfd(w);
    io_uring_submit(&w->ring);

    for (;;) {
        struct io_uring_cqe *cqe;
        int rc = io_uring_submit_and_wait(&w->ring, 1);
        if (rc < 0 && rc != -EINTR) die("io_uring_submit_and_wait");
        uint64_t t_wake = __builtin_expect(STATS_ON, 0) ? stats_now() : 0;
        unsigned head, n = 0;
        io_uring_for_each_cqe(&w->ring, head, cqe) {
            n++;
            handle_cqe(w, cqe);
        }
        io_uring_cq_advance(&w->ring, n);
        api_flush_coalesced(w);
        if (__builtin_expect(STATS_ON, 0)) stats_loop(w, t_wake, n);
    }
    return NULL;
}

int count_cpus(void) {
    cpu_set_t cs;
    if (sched_getaffinity(0, sizeof cs, &cs) == 0) {
        int n = CPU_COUNT(&cs);
        if (n > 0) return n;
    }
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? (int)n : 4;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--bcrypt-selftest") == 0) return bcrypt_selftest();

    signal(SIGPIPE, SIG_IGN);
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur < rl.rlim_max) {
        rl.rlim_cur = rl.rlim_max;
        setrlimit(RLIMIT_NOFILE, &rl);
    }

    const char *db = getenv("DATABASE_URL");
    const char *sec = getenv("JWT_SECRET");
    const char *host = getenv("HOST");
    const char *port = getenv("PORT");
    pg_parse_url(db ? db : "postgres://postgres:postgres@127.0.0.1:5432/conduit");
    jwt_init(sec && *sec ? sec : "conduit-default-secret");
    if (host && *host) snprintf(bind_host, sizeof bind_host, "%s", host);
    if (port && *port) bind_port = atoi(port);

    int cpus = count_cpus();
    int nworkers = cpus / 2;
    if (nworkers < 1) nworkers = 1;
    if (nworkers > 4) nworkers = 4;
    const char *tw = getenv("THREADS");
    if (tw && atoi(tw) > 0) nworkers = atoi(tw);

    int per_w = (4 * cpus) / nworkers;
    if (per_w < 6) per_w = 6;
    if (per_w > 16) per_w = 16;
    // Workload is ~97% reads and ~3% writes: allocate 13 R / 3 W per worker on 8-core box
    cfg_npg_w = 3;
    cfg_npg_r = per_w - cfg_npg_w;
    if (cfg_npg_r < 4) cfg_npg_r = 4;

    const char *dbr = getenv("DB_READ_CONNS");
    if (dbr && atoi(dbr) > 0) cfg_npg_r = atoi(dbr);
    const char *dbw = getenv("DB_WRITE_CONNS");
    if (dbw && atoi(dbw) > 0) cfg_npg_w = atoi(dbw);

    int nbcrypt = cpus;
    if (nbcrypt < 2) nbcrypt = 2;
    const char *bt = getenv("BCRYPT_THREADS");
    if (bt && atoi(bt) > 0) nbcrypt = atoi(bt);

    const char *st = getenv("STATS");
    STATS_ON = st && atoi(st) > 0;

    fprintf(stderr, "conduit-gilnett: %d io_uring workers x (%d R + %d W = %d pg conns), %d bcrypt threads (6-lane SCHED_BATCH), listening on %s:%d\n",
            nworkers, cfg_npg_r, cfg_npg_w, cfg_npg_r + cfg_npg_w, nbcrypt, bind_host, bind_port);

    bcrypt_pool_init(nbcrypt);

    size_t ws_bytes = (size_t)nworkers * sizeof(worker_t);
    worker_t *ws = aligned_alloc(64, ws_bytes);
    if (!ws) ws = calloc((size_t)nworkers, sizeof(worker_t));
    if (!ws) die("allocate workers");
    memset(ws, 0, ws_bytes);
    for (int i = 0; i < nworkers; i++) ws[i].id = i;
    for (int i = 1; i < nworkers; i++) {
        pthread_t t;
        if (pthread_create(&t, NULL, worker_main, &ws[i]) != 0) die("pthread_create worker");
        pthread_detach(t);
    }
    worker_main(&ws[0]);
    return 0;
}
