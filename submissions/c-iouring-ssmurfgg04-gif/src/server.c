/* server.c - workers, connections, the request pool and the two event
 * loops: io_uring (multishot accept + multishot poll, direct send) and an
 * epoll fallback for kernels without multishot (pre-5.19). Both loops run
 * the same request pipeline; the epoll path also serves as the local test
 * rig.
 *
 * Connections live in per-worker slot tables addressed by (generation,
 * slot) packed into the 64-bit user_data, so a completion can never point
 * at a recycled connection. Requests are freelist-allocated and carry a
 * chunk arena that holds the parsed request, query parameters and every
 * Postgres result cell until the response is sent. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <poll.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

#include <liburing.h>

#include "conduit.h"
#include "http.h"
#include "json.h"
#include "jwt.h"
#include "pg.h"
#include "util.h"

/* user_data encoding */
#define UD_ACCEPT 0xfffffffffffffffeULL
#define UD_EVENT 0xfffffffffffffffdULL
#define UD_TICK 0xfffffffffffffffcULL
#define UD_PG 0x0000504700000000ULL /* (UD_PG | pg_idx) */
#define UD_CONN(gen, slot) (((uint64_t)(gen) << 32) | (uint32_t)(slot))
#define UD_IS_PG(ud) (((ud) >> 32) == 0x5047)
#define UD_SLOT(ud) ((uint32_t)((ud) & 0xffffffff))
#define UD_GEN(ud) ((uint32_t)((ud) >> 32))
#define MAX_SLOTS 65536
#define MAX_REQS_PER_CONN 8
#define ARENA_CHUNK 4096

typedef struct arena_chunk {
    struct arena_chunk *next;
    uint32_t used, cap;
    char data[];
} arena_chunk_t;

cfg_t cfg;

int g_trace;                /* LOG=1: log io_uring event flow */
#define TRACE(...) do { if (g_trace) fprintf(stderr, __VA_ARGS__); } while (0)

static worker_t g_workers[64];
static int g_nworkers;
static int g_epoll_forced;      /* --epoll: use the fallback on purpose */

/* ---------------------------------------------------------------- req pool */

typedef struct req_node req_node_t;
struct req_node {
    req_t r;
    req_node_t *next;
};

static __thread req_node_t *req_freelist;

void *arena_alloc(req_t *r, size_t n)
{
    n = (n + 15) & ~(size_t)15;
    arena_chunk_t *ch = r->arena;
    if (n > ARENA_CHUNK) {
        ch = malloc(sizeof(arena_chunk_t) + n);
        if (!ch) return NULL;
        ch->used = (uint32_t)n;
        ch->cap = (uint32_t)n;
        ch->next = r->arena;
        r->arena = ch;
        return ch->data;
    }
    if (!ch || ch->cap - ch->used < n) {
        ch = malloc(sizeof(arena_chunk_t) + ARENA_CHUNK);
        if (!ch) return NULL;
        ch->used = 0;
        ch->cap = ARENA_CHUNK;
        ch->next = r->arena;
        r->arena = ch;
    }
    void *p = ch->data + ch->used;
    ch->used += (uint32_t)n;
    return p;
}

void arena_drain(req_t *r)
{
    arena_chunk_t *ch = r->arena;
    while (ch) {
        arena_chunk_t *next = ch->next;
        free(ch);
        ch = next;
    }
    r->arena = NULL;
}

req_t *req_new(worker_t *w)
{
    req_node_t *n = req_freelist;
    if (n) {
        req_freelist = n->next;
    } else {
        n = malloc(sizeof *n);
        if (!n) return NULL;
    }
    req_t *r = &n->r;
    memset(r, 0, sizeof *r);
    r->w = w;
    r->released = 0;
    buf_init(&r->resp);
    return r;
}

void req_release(req_t *r)
{
    if (r->released) return; /* srv_reply owns the release; be idempotent */
    r->released = 1;
    buf_free(&r->resp);
    arena_drain(r);
    req_node_t *n = (req_node_t *)r;
    n->next = req_freelist;
    req_freelist = n;
}

/* ---------------------------------------------------------------- config */

static const char *env_or(const char *name, const char *def)
{
    const char *v = getenv(name);
    return v && *v ? v : def;
}

int srv_parse_db_url(const char *url)
{
    /* postgres://user:pass@host:port/db (password may be empty) */
    const char *p = strstr(url, "://");
    if (!p) return -1;
    p += 3;
    const char *slash = strrchr(p, '/');
    if (!slash) return -1;
    const char *at = NULL;
    for (const char *q = p; q < slash; q++)
        if (*q == '@') at = q;
    char up[256];
    size_t head = at ? (size_t)(at - p) : 0;
    if (head >= sizeof up) return -1;
    if (at) {
        memcpy(up, p, head);
        up[head] = 0;
        char *colon = strchr(up, ':');
        if (colon) {
            *colon = 0;
            cfg.db_pass = strdup(colon + 1);
        } else {
            cfg.db_pass = strdup("");
        }
        cfg.db_user = strdup(up);
    } else {
        cfg.db_user = strdup("conduit");
        cfg.db_pass = strdup("");
    }
    const char *hostport = at ? at + 1 : p;
    const char *hcolon = strchr(hostport, ':');
    char hostbuf[128];
    if (hcolon && hcolon < slash) {
        size_t hl = (size_t)(hcolon - hostport);
        if (hl >= sizeof hostbuf) return -1;
        memcpy(hostbuf, hostport, hl);
        hostbuf[hl] = 0;
        char portbuf[16];
        size_t pl = (size_t)(slash - hcolon - 1);
        if (pl >= sizeof portbuf) return -1;
        memcpy(portbuf, hcolon + 1, pl);
        portbuf[pl] = 0;
        cfg.db_port = strdup(portbuf);
    } else {
        size_t hl = (size_t)(slash - hostport);
        if (hl >= sizeof hostbuf) return -1;
        memcpy(hostbuf, hostport, hl);
        hostbuf[hl] = 0;
        cfg.db_port = strdup("5432");
    }
    cfg.db_host = strdup(hostbuf);
    cfg.db_name = strdup(slash + 1);
    return 0;
}

static void config_load(void)
{
    long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
    if (ncpu < 1) ncpu = 1;

    memset(&cfg, 0, sizeof cfg);
    cfg.threads = atoi(env_or("THREADS", ""));
    if (cfg.threads <= 0) cfg.threads = (int)(ncpu / 2);
    if (cfg.threads > 32) cfg.threads = 32;
    cfg.db_reads = atoi(env_or("DB_READS", "9"));
    cfg.db_writes = atoi(env_or("DB_WRITES", "3"));
    if (cfg.db_reads < 1) cfg.db_reads = 1;
    if (cfg.db_writes < 0) cfg.db_writes = 0;
    cfg.pg_depth = atoi(env_or("PG_DEPTH", "16"));
    if (cfg.pg_depth < 1) cfg.pg_depth = 1;
    if (cfg.pg_depth > PG_DEPTH_MAX) cfg.pg_depth = PG_DEPTH_MAX;
    cfg.bcrypt_threads = atoi(env_or("BCRYPT_THREADS", ""));
    if (cfg.bcrypt_threads <= 0) cfg.bcrypt_threads = (int)(ncpu / 2);
    cfg.bcrypt_lanes = atoi(env_or("BCRYPT_LANES", "4"));
    if (cfg.bcrypt_lanes < 1) cfg.bcrypt_lanes = 1;
    if (cfg.bcrypt_lanes > 4) cfg.bcrypt_lanes = 4;
    cfg.bcrypt_wait_ms = atoi(env_or("BCRYPT_WAIT_MS", "40"));
    if (cfg.bcrypt_wait_ms < 0) cfg.bcrypt_wait_ms = 0;

    const char *url = getenv("DATABASE_URL");
    if (!url || srv_parse_db_url(url)) {
        fprintf(stderr, "conduit: DATABASE_URL is required (postgres://user:pass@host:port/db)\n");
        exit(1);
    }
    const char *sec = getenv("JWT_SECRET");
    if (!sec || !*sec) {
        fprintf(stderr, "conduit: JWT_SECRET is required\n");
        exit(1);
    }
    cfg.jwt_secret = sec;
    cfg.listen_host = env_or("HOST", "0.0.0.0");
    cfg.listen_port = env_or("PORT", "3000");

    if ((long)cfg.threads * (cfg.db_reads + cfg.db_writes) > PG_TOTAL_CONN_LIMIT) {
        fprintf(stderr, "conduit: %d threads x (%d reads + %d writes) exceeds the %d connection cap\n",
                cfg.threads, cfg.db_reads, cfg.db_writes, PG_TOTAL_CONN_LIMIT);
        exit(1);
    }
}

/* ---------------------------------------------------------------- memory guard */

static double mem_available_mb(void)
{
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f) return 1e9;
    char line[256];
    double avail = 1e9;
    while (fgets(line, sizeof line, f))
        if (sscanf(line, "MemAvailable: %lf kB", &avail) == 1) {
            avail /= 1024.0;
            break;
        }
    fclose(f);
    return avail;
}

static double g_mem_mb = 1e9; /* written by tick, read by accept: benign race */
#define MEM_STOP_MB 192.0
#define MEM_SHED_MB 96.0

/* ---------------------------------------------------------------- listeners */

static int listen_on(const char *host, const char *port)
{
    struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM,
                              .ai_flags = AI_PASSIVE }, *res;
    if (getaddrinfo(host, port, &hints, &res) || !res) return -1;
    int fd = -1;
    for (struct addrinfo *rp = res; rp; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
        if (fd < 0) continue;
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
        if (!bind(fd, rp->ai_addr, rp->ai_addrlen) && !listen(fd, 65535)) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

/* ---------------------------------------------------------------- conn mgmt */

typedef struct {
    conn_t *c;
    uint32_t gen;
} slot_t;

static slot_t *g_slots;         /* g_nworkers * MAX_SLOTS */

static conn_t *conn_from_ud(worker_t *w, uint64_t ud)
{
    uint32_t slot = UD_SLOT(ud), gen = UD_GEN(ud);
    if (slot >= MAX_SLOTS) return NULL;
    slot_t *s = &g_slots[(size_t)w->idx * MAX_SLOTS + slot];
    if (s->gen != gen || !s->c) return NULL;
    return s->c;
}

static conn_t *conn_new(worker_t *w, int fd)
{
    slot_t *s = NULL;
    for (int i = 0; i < MAX_SLOTS; i++) {
        slot_t *cand = &g_slots[(size_t)w->idx * MAX_SLOTS + w->next_slot];
        w->next_slot = (w->next_slot + 1) % MAX_SLOTS;
        if (!cand->c) { s = cand; break; }
    }
    if (!s) { close(fd); return NULL; }
    conn_t *c = calloc(1, sizeof *c);
    if (!c) { close(fd); return NULL; }
    c->fd = fd;
    c->w = w;
    c->keep = 1;
    c->last_ms = w->now_ms;
    buf_init(&c->in);
    buf_init(&c->out);
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    s->c = c;
    s->gen++;
    c->slot = (int)(s - &g_slots[(size_t)w->idx * MAX_SLOTS]);
    c->gen = s->gen;
    c->prev = w->c_tail;
    if (w->c_tail) w->c_tail->next = c;
    else w->c_head = c;
    w->c_tail = c;
    w->nconns++;
    return c;
}

static void conn_detach(conn_t *c)
{
    worker_t *w = c->w;
    if (c->fd < 0) return;
    if (c->prev) c->prev->next = c->next;
    else w->c_head = c->next;
    if (c->next) c->next->prev = c->prev;
    else w->c_tail = c->prev;
    c->next = c->prev = NULL;
    w->nconns--;
    /* in-flight requests lose their connection */
    for (req_t *r = w->fifo_head; r; r = r->fifo_next)
        if (r->c == c) r->c = NULL;
    if (w->use_iouring && !c->closed_ring) {
        io_uring_prep_poll_remove(io_uring_get_sqe(&w->ring), UD_CONN(c->gen, c->slot));
        c->closed_ring = 1;
    }
    g_slots[(size_t)w->idx * MAX_SLOTS + c->slot].c = NULL;
    buf_free(&c->in);
    buf_free(&c->out);
    close(c->fd);
    c->fd = -1;
    free(c);
}

void srv_conn_close(conn_t *c)
{
    if (c->closing) return;
    c->closing = 1;
    c->keep = 0;
    if (!c->sending && c->out.len == 0 && c->nreqs == 0) conn_detach(c);
}

/* ---------------------------------------------------------------- replies */

static const char *status_text(int s)
{
    switch (s) {
    case 200: return "OK";
    case 201: return "Created";
    case 204: return "No Content";
    case 400: return "Bad Request";
    case 401: return "Unauthorized";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 413: return "Payload Too Large";
    case 422: return "Unprocessable Entity";
    case 500: return "Internal Server Error";
    default: return "Error";
    }
}

void srv_reply(req_t *r, int status, const char *body, size_t blen)
{
    if (r->replied) return;
    r->replied = 1;
    conn_t *c = r->c;

    if (c) {
        char hdr[256];
        int hn;
        if (status == 204 || blen == 0)
            hn = snprintf(hdr, sizeof hdr,
                          "HTTP/1.1 %d %s\r\nContent-Length: 0\r\n%s\r\n",
                          status, status_text(status),
                          c->closing ? "Connection: close\r\n" : "");
        else
            hn = snprintf(hdr, sizeof hdr,
                          "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\n"
                          "Content-Length: %zu\r\n%s\r\n",
                          status, status_text(status), blen,
                          c->closing ? "Connection: close\r\n" : "");
        buf_put(&c->out, hdr, (size_t)hn);
        if (blen) buf_put(&c->out, body, blen);
        c->last_ms = r->w->now_ms;
        c->nreqs--;
        if (!c->sending) srv_send(c);
    }
    req_release(r);
}

void srv_reply_close(req_t *r, int status, const char *body, size_t blen)
{
    if (r->c) srv_conn_close(r->c);
    srv_reply(r, status, body, blen);
}

/* ---------------------------------------------------------------- sending */

void srv_send(conn_t *c)
{
    worker_t *w = c->w;
    if (!c->out.len) {
        if (c->closing && !c->nreqs) conn_detach(c);
        return;
    }
    if (w->use_iouring) {
        c->sending = 1;
        struct io_uring_sqe *sqe = io_uring_get_sqe(&w->ring);
        io_uring_prep_send(sqe, c->fd, c->out.p + c->out_off, c->out.len - c->out_off, MSG_NOSIGNAL);
        io_uring_sqe_set_data64(sqe, UD_CONN(c->gen, c->slot));
        io_uring_submit(&w->ring);
    } else {
        while (c->out_off < c->out.len) {
            ssize_t n = send(c->fd, c->out.p + c->out_off, c->out.len - c->out_off, MSG_NOSIGNAL);
            if (n > 0) { c->out_off += (size_t)n; continue; }
            if (n < 0 && errno == EINTR) continue;
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                if (!c->want_out) {
                    c->want_out = 1;
                    struct epoll_event ev = { .events = EPOLLIN | EPOLLOUT | EPOLLRDHUP,
                                              .data.u64 = UD_CONN(c->gen, c->slot) };
                    epoll_ctl(w->epfd, EPOLL_CTL_MOD, c->fd, &ev);
                }
                return;
            }
            conn_detach(c);
            return;
        }
        c->out.len = 0;
        c->out_off = 0;
        if (c->want_out) {
            c->want_out = 0;
            struct epoll_event ev = { .events = EPOLLIN | EPOLLRDHUP,
                                      .data.u64 = UD_CONN(c->gen, c->slot) };
            epoll_ctl(w->epfd, EPOLL_CTL_MOD, c->fd, &ev);
        }
        if (c->closing && !c->nreqs) { conn_detach(c); return; }
        conn_process(c);
    }
}

static void send_done(conn_t *c, int32_t n)
{
    if (n <= 0) {
        c->sending = 0;
        if (n == -EAGAIN || n == -EINTR) {
            srv_send(c);
            return;
        }
        conn_detach(c);
        return;
    }
    c->out_off += (size_t)n;
    if (c->out_off >= c->out.len) {
        c->out.len = 0;
        c->out_off = 0;
        c->sending = 0;
        if (c->closing && !c->nreqs) { conn_detach(c); return; }
        conn_process(c);
        return;
    }
    /* partial send: reissue from the new offset */
    struct io_uring_sqe *sqe = io_uring_get_sqe(&c->w->ring);
    io_uring_prep_send(sqe, c->fd, c->out.p + c->out_off, c->out.len - c->out_off, MSG_NOSIGNAL);
    io_uring_sqe_set_data64(sqe, UD_CONN(c->gen, c->slot));
    io_uring_submit(&c->w->ring);
}

/* ---------------------------------------------------------------- requests */

/* finished bcrypt jobs are delivered here by the bcrypt threads */
static void drain_done(worker_t *w)
{
    pthread_mutex_lock(&w->mu);
    bcrypt_job_t *j = w->done;
    w->done = NULL;
    pthread_mutex_unlock(&w->mu);
    while (j) {
        bcrypt_job_t *next = j->next;
        j->next = NULL;
        j->done(j);
        j = next;
    }
}

void conn_process(conn_t *c)
{
    worker_t *w = c->w;
    if (c->closing || c->sending) return;
    /* replies can drain synchronously and try to re-enter; the outer loop
     * already owns the uncommitted parse offsets */
    static __thread int inside;
    if (inside) return;
    inside = 1;
    size_t off = 0;
    while (c->nreqs < MAX_REQS_PER_CONN) {
        if (off >= c->in.len) break;
        req_t *r = req_new(w);
        if (!r) break;
        r->c = c;
        r->viewer = 0;
        size_t rc = http_request(c->in.p + off, c->in.len - off, r);
        if (rc == HTTP_INCOMPLETE) {
            req_release(r);
            if (c->in.len - off > MAX_HEADER + MAX_BODY) {
                static const char e400[] = "{\"errors\":{\"body\":[\"too large\"]}}";
                srv_conn_close(c);
                c->nreqs++;
                srv_reply(r, 400, e400, sizeof e400 - 1);
            }
            break;
        }
        if (rc == HTTP_ERROR) {
            static const char e400[] = "{\"errors\":{\"body\":[\"bad request\"]}}";
            off = c->in.len; /* cannot resync: everything is garbage */
            c->nreqs++;
            srv_reply_close(r, 400, e400, sizeof e400 - 1);
            break;
        }
        off += rc;
        c->nreqs++;
        c->last_ms = w->now_ms;
        route(r);
        if (!r->replied && !r->pending && r->nstmts == 0) {
            static const char e500[] = "{\"errors\":{\"body\":[\"internal error\"]}}";
            srv_reply(r, 500, e500, sizeof e500 - 1);
        }
    }
    if (off && c->fd >= 0) {
        memmove(c->in.p, c->in.p + off, c->in.len - off);
        c->in.len -= (uint32_t)off;
        if (!c->in.len && c->in.cap > 65536) {
            buf_free(&c->in);
            buf_init(&c->in);
        }
    }
    inside = 0;
}

/* read-ready on a client connection: drain to EAGAIN, then parse */
static void conn_readable(conn_t *c)
{
    worker_t *w = c->w;
    for (;;) {
        if (buf_reserve(&c->in, SCRATCH_SZ)) break;
        ssize_t n = recv(c->fd, c->in.p + c->in.len, SCRATCH_SZ, MSG_DONTWAIT);
        if (n > 0) {
            c->in.len += (uint32_t)n;
            c->last_ms = w->now_ms;
            if ((size_t)n < SCRATCH_SZ) break;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n == 0) { srv_conn_close(c); return; }
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        conn_detach(c);
        return;
    }
    if (c->out.len < MAX_OUT_HIGH) conn_process(c);
}

static void conn_accept(worker_t *w, int fd)
{
    if (g_mem_mb < MEM_STOP_MB) {
        close(fd);
        return;
    }
    TRACE("trace: accept fd=%d\n", fd);
    if (!conn_new(w, fd)) return;
    if (w->use_iouring) {
        struct io_uring_sqe *sqe = io_uring_get_sqe(&w->ring);
        io_uring_prep_poll_multishot(sqe, fd, POLLIN | POLLRDHUP);
        io_uring_sqe_set_data64(sqe, UD_CONN(w->c_tail->gen, w->c_tail->slot));
        io_uring_submit(&w->ring);
    } else {
        struct epoll_event ev = { .events = EPOLLIN | EPOLLRDHUP, .data.u64 = 0 };
        conn_t *c = w->c_tail;
        ev.data.u64 = UD_CONN(c->gen, c->slot);
        epoll_ctl(w->epfd, EPOLL_CTL_ADD, c->fd, &ev);
    }
}

/* ---------------------------------------------------------------- tick */

static void tick(worker_t *w)
{
    w->now_ms = now_mono_ms();
    static __thread uint64_t last_slow;
    g_mem_mb = mem_available_mb();

    /* reconnect dead PG connections, watch the FIFO */
    pg_tick(w);
    pg_fifo_check(w);

    /* every 4 ticks: stall + idle scan, memory shedding */
    if (w->now_ms - last_slow < 4000) return;
    last_slow = w->now_ms;
    int shed = g_mem_mb < MEM_SHED_MB;
    conn_t *c = w->c_head;
    while (c) {
        conn_t *next = c->next;
        uint64_t idle = w->now_ms - c->last_ms;
        if (idle > STALL_MS && (c->out.len || c->sending)) {
            conn_detach(c);
        } else if (idle > IDLE_MS || (shed && idle > 5000)) {
            conn_detach(c);
        }
        c = next;
    }
}

/* ---------------------------------------------------------------- epoll loop */

static void epoll_arm_listener(worker_t *w)
{
    struct epoll_event ev = { .events = EPOLLIN, .data.u64 = UD_ACCEPT };
    epoll_ctl(w->epfd, EPOLL_CTL_ADD, w->listen_fd, &ev);
    ev.data.u64 = UD_EVENT;
    epoll_ctl(w->epfd, EPOLL_CTL_ADD, w->evfd, &ev);
    ev.data.u64 = UD_TICK;
    epoll_ctl(w->epfd, EPOLL_CTL_ADD, w->tickfd, &ev);
    for (int i = 0; i < w->npgs; i++) {
        ev.events = EPOLLIN | EPOLLOUT; /* connect completion needs EPOLLOUT */
        ev.data.u64 = UD_PG | (uint32_t)i;
        epoll_ctl(w->epfd, EPOLL_CTL_ADD, w->pgs[i].fd, &ev);
    }
}

static void epoll_rearm_pg(worker_t *w, int idx)
{
    /* EPOLLOUT only while a partial send is pending; otherwise it spins */
    int events = EPOLLIN | (w->pgs[idx].want_out ? EPOLLOUT : 0);
    struct epoll_event ev = { .events = events, .data.u64 = UD_PG | (uint32_t)idx };
    epoll_ctl(w->epfd, EPOLL_CTL_DEL, w->pgs[idx].fd, NULL);
    if (w->pgs[idx].fd >= 0) epoll_ctl(w->epfd, EPOLL_CTL_ADD, w->pgs[idx].fd, &ev);
}

static void *worker_epoll(void *arg)
{
    worker_t *w = arg;
    w->use_iouring = 0;
    w->now_ms = now_mono_ms();

    w->epfd = epoll_create1(EPOLL_CLOEXEC);
    w->evfd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    struct itimerspec its = { .it_interval = { 1, 0 }, .it_value = { 1, 0 } };
    w->tickfd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    timerfd_settime(w->tickfd, 0, &its, NULL);
    epoll_arm_listener(w);

    struct epoll_event evs[1024];
    for (;;) {
        int n = epoll_wait(w->epfd, evs, 1024, -1);
        if (n < 0 && errno == EINTR) continue;
        for (int i = 0; i < n; i++) {
            uint64_t ud = evs[i].data.u64;
            if (ud == UD_ACCEPT) {
                for (;;) {
                    int fd = accept4(w->listen_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
                    if (fd < 0) break;
                    conn_accept(w, fd);
                }
            } else if (ud == UD_EVENT) {
                uint64_t v;
                while (read(w->evfd, &v, sizeof v) == sizeof v) {}
                drain_done(w);
            } else if (ud == UD_TICK) {
                uint64_t v;
                while (read(w->tickfd, &v, sizeof v) == sizeof v) {}
                tick(w);
            } else if (UD_IS_PG(ud)) {
                int idx = (int)(ud & 0xffffffff);
                pgconn_t *pc = &w->pgs[idx];
                if (evs[i].events & (EPOLLHUP | EPOLLERR)) {
                    pg_reconnect(pc);
                    epoll_rearm_pg(w, idx);
                    continue;
                }
                if (pc->state == PGS_CONNECTING) {
                    pg_on_writable(pc);
                    continue;
                }
                if (evs[i].events & EPOLLIN) pg_on_readable(pc);
                if (evs[i].events & EPOLLOUT) pg_on_writable(pc);
                epoll_rearm_pg(w, idx);
            } else {
                conn_t *c = conn_from_ud(w, ud);
                if (!c) continue;
                if (evs[i].events & (EPOLLHUP | EPOLLERR)) {
                    conn_detach(c);
                    continue;
                }
                if (evs[i].events & EPOLLOUT) {
                    c->sending = 0;
                    srv_send(c);
                    if (!c || c->fd < 0) continue;
                    continue;
                }
                if (evs[i].events & (EPOLLIN | EPOLLRDHUP)) {
                    conn_readable(c);
                }
            }
        }
    }
    return NULL;
}

/* ---------------------------------------------------------------- io_uring loop */

static int ring_setup(worker_t *w)
{
    struct io_uring_params p = { 0 };
    p.flags = IORING_SETUP_CQSIZE;
    p.cq_entries = CQ_ENTRIES;
    unsigned flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN |
                     IORING_SETUP_COOP_TASKRUN;
    for (int attempt = 0; attempt < 3; attempt++) {
        int rc = io_uring_queue_init_params(RING_ENTRIES, &w->ring, &p);
        if (!rc) return 0;
        if (attempt == 0) flags &= ~IORING_SETUP_DEFER_TASKRUN;
        else if (attempt == 1) flags &= ~IORING_SETUP_COOP_TASKRUN;
        p.flags = IORING_SETUP_CQSIZE;
    }
    return -1;
}

static void ring_arm_all(worker_t *w)
{
    /* multishot accept */
    struct io_uring_sqe *sqe = io_uring_get_sqe(&w->ring);
    io_uring_prep_multishot_accept(sqe, w->listen_fd, NULL, NULL, 0);
    io_uring_sqe_set_data64(sqe, UD_ACCEPT);

    /* eventfd + timerfd */
    sqe = io_uring_get_sqe(&w->ring);
    io_uring_prep_poll_add(sqe, w->evfd, POLLIN);
    io_uring_sqe_set_data64(sqe, UD_EVENT);

    sqe = io_uring_get_sqe(&w->ring);
    io_uring_prep_poll_add(sqe, w->tickfd, POLLIN);
    io_uring_sqe_set_data64(sqe, UD_TICK);

    /* PG readiness: one-shot POLLOUT while connecting, multishot POLLIN live */
    for (int i = 0; i < w->npgs; i++) pg_arm(&w->pgs[i]);

    io_uring_submit(&w->ring);
}

/* io_uring: readiness polling for a PG connection. A connecting socket gets
 * a one-shot POLLOUT (the connect completion); a live one gets multishot
 * POLLIN. Sends stay synchronous (drain now, resume on the next poll event),
 * so POLLOUT is never armed for live connections and cannot spin. */
void pg_arm(pgconn_t *pc)
{
    worker_t *w = pc->w;
    if (!w->use_iouring || pc->fd < 0 || pc->recv_armed) return;
    struct io_uring_sqe *sqe = io_uring_get_sqe(&w->ring);
    if (!sqe) return;
    if (pc->state == PGS_CONNECTING)
        io_uring_prep_poll_add(sqe, pc->fd, POLLOUT);
    else
        io_uring_prep_poll_multishot(sqe, pc->fd, POLLIN | POLLRDHUP | POLLERR | POLLHUP);
    io_uring_sqe_set_data64(sqe, UD_PG | (uint32_t)pc->id);
    pc->recv_armed = 1;
    io_uring_submit(&w->ring);
}

static void pg_poll_event(worker_t *w, int idx, int32_t res, unsigned flags)
{
    pgconn_t *pc = &w->pgs[idx];
    pc->recv_armed = 0;
    if (res < 0 && res != -ECANCELED && res != -EAGAIN) {
        pg_reconnect(pc);
        pg_arm(pc);
        return;
    }
    if (pc->state == PGS_CONNECTING) {
        if (res & POLLOUT) pg_on_writable(pc); /* completes the connect */
        /* res without POLLOUT (spurious or error report): SO_ERROR decides */
        else pg_on_writable(pc);
    } else {
        if (res & (POLLIN | POLLHUP | POLLERR)) {
            pg_on_readable(pc); /* drain + advance + deliver batches */
            if (pc->out_off < pc->out.len) pg_on_writable(pc); /* resume partial send */
        }
    }
    pg_arm(pc);
    (void)flags;
}


/* Multishot accept needs kernel 5.19+; the challenge box (Ubuntu 24.04,
 * 6.8) has it. Probe for real: listen on an ephemeral port, arm multishot
 * accept, connect to ourselves, and require the completion to carry
 * IORING_CQE_F_MORE (a single-shot accept never does). */
static int probe_multishot(struct io_uring *ring)
{
    int lfd = listen_on("127.0.0.1", "0");
    if (lfd < 0) return 0;
    struct sockaddr_storage ss;
    socklen_t slen = sizeof ss;
    getsockname(lfd, (struct sockaddr *)&ss, &slen);

    struct io_uring_sqe *sqe = io_uring_get_sqe(ring);
    io_uring_prep_multishot_accept(sqe, lfd, NULL, NULL, 0);
    io_uring_sqe_set_data64(sqe, 0x0defacedULL);
    io_uring_submit(ring);

    /* connect to ourselves from a second socket */
    int cfd = socket(((struct sockaddr *)&ss)->sa_family, SOCK_STREAM | SOCK_NONBLOCK, 0);
    int connected = -1;
    if (cfd >= 0) connected = connect(cfd, (struct sockaddr *)&ss, slen);

    struct io_uring_cqe *cqe = NULL;
    int ok = 0;
    struct __kernel_timespec ts = { .tv_sec = 0, .tv_nsec = 500 * 1000 * 1000 };
    sqe = io_uring_get_sqe(ring);
    io_uring_prep_timeout(sqe, &ts, 1, 0);
    io_uring_submit(ring);
    for (int i = 0; i < 16; i++) {
        if (io_uring_peek_cqe(ring, &cqe)) continue;
        uint64_t ud = io_uring_cqe_get_data64(cqe);
        if (ud == 0x0defacedULL) {
            ok = cqe->res >= 0 && (cqe->flags & IORING_CQE_F_MORE);
            io_uring_cqe_seen(ring, cqe);
            break;
        }
        io_uring_cqe_seen(ring, cqe);
    }
    io_uring_prep_poll_remove(io_uring_get_sqe(ring), 0x0defacedULL);
    io_uring_submit(ring);
    if (cfd >= 0) close(cfd);
    close(lfd);
    fprintf(stderr, "conduit: multishot io_uring probe: %s\n", ok ? "ok" : "unsupported");
    return ok;
}

static void *worker_iouring(void *arg)
{
    worker_t *w = arg;
    w->use_iouring = 1;
    w->now_ms = now_mono_ms();

    if (ring_setup(w) || !probe_multishot(&w->ring)) {
        fprintf(stderr, "conduit: multishot io_uring unavailable, falling back to epoll\n");
        return worker_epoll(arg);
    }

    w->evfd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    struct itimerspec its = { .it_interval = { 1, 0 }, .it_value = { 1, 0 } };
    w->tickfd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    timerfd_settime(w->tickfd, 0, &its, NULL);
    ring_arm_all(w);

    struct io_uring_cqe *cqe;
    unsigned head;
    unsigned count;
    for (;;) {
        io_uring_submit_and_wait(&w->ring, 1);
        count = 0;
        io_uring_for_each_cqe(&w->ring, head, cqe) {
            uint64_t ud = io_uring_cqe_get_data64(cqe);
            int32_t res = cqe->res;
            count++;
            if (ud == UD_ACCEPT) {
                if (res >= 0) conn_accept(w, res);
                if (res < 0 && res != -ECANCELED && !w->accept_broken) {
                    /* kernel refused multishot accept: single-shot from now on */
                    w->accept_broken = 1;
                    fprintf(stderr, "conduit: multishot accept rejected (%d), single-shot fallback\n", res);
                }
                if (w->accept_broken) {
                    struct io_uring_sqe *sqe = io_uring_get_sqe(&w->ring);
                    io_uring_prep_accept(sqe, w->listen_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
                    io_uring_sqe_set_data64(sqe, UD_ACCEPT);
                } else if (!(cqe->flags & IORING_CQE_F_MORE) && res >= 0) {
                    struct io_uring_sqe *sqe = io_uring_get_sqe(&w->ring);
                    io_uring_prep_multishot_accept(sqe, w->listen_fd, NULL, NULL, 0);
                    io_uring_sqe_set_data64(sqe, UD_ACCEPT);
                }
            } else if (ud == UD_EVENT) {
                uint64_t v;
                while (read(w->evfd, &v, sizeof v) == sizeof v) {}
                drain_done(w);
                struct io_uring_sqe *sqe = io_uring_get_sqe(&w->ring);
                io_uring_prep_poll_add(sqe, w->evfd, POLLIN);
                io_uring_sqe_set_data64(sqe, UD_EVENT);
            } else if (ud == UD_TICK) {
                uint64_t v;
                while (read(w->tickfd, &v, sizeof v) == sizeof v) {}
                tick(w);
                struct io_uring_sqe *sqe = io_uring_get_sqe(&w->ring);
                io_uring_prep_poll_add(sqe, w->tickfd, POLLIN);
                io_uring_sqe_set_data64(sqe, UD_TICK);
            } else if (UD_IS_PG(ud)) {
                pg_poll_event(w, (int)(ud & 0xffffffff), res, cqe->flags);
            } else {
                conn_t *c = conn_from_ud(w, ud);
                TRACE("trace: conn cqe res=%d sending=%d\n", res, c ? c->sending : -1);
                if (!c) continue;
                if (res == -ECANCELED) continue;
                if (res <= 0) {
                    if (c->sending) {
                        c->sending = 0;
                        send_done(c, res);
                    } else {
                        /* poll reported an error or the peer closed */
                        conn_detach(c);
                    }
                    continue;
                }
                if (c->sending) {
                    send_done(c, res);
                    continue;
                }
                /* multishot poll completion: readable */
                conn_readable(c);
                if (!(cqe->flags & IORING_CQE_F_MORE)) {
                    if (!c || c->fd < 0) continue;
                    struct io_uring_sqe *sqe = io_uring_get_sqe(&w->ring);
                    io_uring_prep_poll_multishot(sqe, c->fd, POLLIN | POLLRDHUP);
                    io_uring_sqe_set_data64(sqe, UD_CONN(c->gen, c->slot));
                }
            }
        }
        io_uring_cq_advance(&w->ring, count);
    }
    return NULL;
}

/* ---------------------------------------------------------------- startup */

int srv_init(void)
{
    signal(SIGPIPE, SIG_IGN);
    g_trace = !!getenv("LOG");
    config_load();
    jwt_b64url_init();
    jwt_init(cfg.jwt_secret, strlen(cfg.jwt_secret));

    int st = bcrypt_selftest();
    if (st) {
        fprintf(stderr, "conduit: bcrypt selftest failed (%d)\n", st);
        return -1;
    }

    g_slots = calloc((size_t)cfg.threads * MAX_SLOTS, sizeof(slot_t));
    if (!g_slots) return -1;

    g_nworkers = cfg.threads;
    for (int i = 0; i < g_nworkers; i++) {
        worker_t *w = &g_workers[i];
        memset(w, 0, sizeof *w);
        w->idx = i;
        pthread_mutex_init(&w->mu, NULL);
        w->listen_fd = listen_on(cfg.listen_host, cfg.listen_port);
        if (w->listen_fd < 0) {
            perror("listen");
            return -1;
        }
        w->now_ms = now_mono_ms();
        w->npgs = cfg.db_reads + cfg.db_writes;
        w->pgs = calloc((size_t)w->npgs, sizeof(pgconn_t));
        if (!w->pgs) return -1;
        for (int k = 0; k < w->npgs; k++) {
            pgconn_t *pc = &w->pgs[k];
            memset(pc, 0, sizeof *pc);
            pc->fd = -1;
            pc->w = w;
            pc->id = k;
            pc->state = PGS_DEAD;
        }
        buf_init(&w->scratch);
        buf_reserve(&w->scratch, SCRATCH_SZ);
        w->scratch.len = 0;
    }
    return 0;
}

void srv_run(void)
{
    /* PG connections are opened on each worker thread (blocking-ish there is
     * avoided: connections start DEAD and reconnect asynchronously). */
    for (int i = 0; i < g_nworkers; i++)
        for (int k = 0; k < g_workers[i].npgs; k++)
            pg_connect(&g_workers[i].pgs[k]);

    bcrypt_pool_start(cfg.bcrypt_threads);

    for (int i = 1; i < g_nworkers; i++) {
        pthread_t t;
        pthread_create(&t, NULL, g_epoll_forced ? worker_epoll : worker_iouring, &g_workers[i]);
        pthread_detach(t);
    }
    (g_epoll_forced ? worker_epoll : worker_iouring)(&g_workers[0]);
}

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--epoll")) g_epoll_forced = 1;
        else if (!strcmp(argv[i], "--bcrypt-selftest")) {
            config_load();
            jwt_b64url_init();
            int rc = bcrypt_selftest();
            printf("bcrypt selftest: %s\n", rc ? "FAIL" : "ok");
            return rc;
        }
    }
    if (srv_init()) return 1;
    fprintf(stderr, "conduit: %d threads x %d PG conns, direct on %s:%s\n",
            cfg.threads, cfg.threads * (cfg.db_reads + cfg.db_writes),
            cfg.listen_host, cfg.listen_port);
    srv_run();
    return 0;
}
