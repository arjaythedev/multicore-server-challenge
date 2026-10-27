// Asynchronous PostgreSQL wire-protocol v3 client with dedicated Read and Write connection pools.
// Startup sets plan_cache_mode=force_generic_plan, jit=off, max_parallel_workers_per_gather=0, and
// synchronous_commit=on. Read connections serve coalesced batches from api.c; write connections
// pipeline durable Sync batches without head-of-line blocking reads.
#include "conduit.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <unistd.h>

#define MAX_WRITE_PIPELINE 32

static char pg_host[128] = "127.0.0.1";
static char pg_port[16] = "5432";
static char pg_user[64] = "postgres";
static char pg_pass[128] = "";
static char pg_db[64] = "conduit";

void pg_parse_url(const char *url) {
    if (!url || strncmp(url, "postgres", 8) != 0) return;
    const char *p = strstr(url, "://");
    if (!p) return;
    p += 3;
    const char *slash = strchr(p, '/');
    const char *end = slash ? slash : p + strlen(p);
    const char *at = memchr(p, '@', (size_t)(end - p));
    const char *hostp = p;
    if (at) {
        const char *col = memchr(p, ':', (size_t)(at - p));
        if (col) {
            snprintf(pg_user, sizeof pg_user, "%.*s", (int)(col - p), p);
            snprintf(pg_pass, sizeof pg_pass, "%.*s", (int)(at - col - 1), col + 1);
        } else {
            snprintf(pg_user, sizeof pg_user, "%.*s", (int)(at - p), p);
        }
        hostp = at + 1;
    }
    const char *col = memchr(hostp, ':', (size_t)(end - hostp));
    if (col) {
        snprintf(pg_host, sizeof pg_host, "%.*s", (int)(col - hostp), hostp);
        snprintf(pg_port, sizeof pg_port, "%.*s", (int)(end - col - 1), col + 1);
    } else if (end > hostp) {
        snprintf(pg_host, sizeof pg_host, "%.*s", (int)(end - hostp), hostp);
    }
    if (slash && slash[1]) {
        const char *q = strchr(slash + 1, '?');
        size_t dlen = q ? (size_t)(q - (slash + 1)) : strlen(slash + 1);
        snprintf(pg_db, sizeof pg_db, "%.*s", (int)dlen, slash + 1);
    }
}

static inline void put_u32(buf_t *b, uint32_t v) {
    uint32_t be = __builtin_bswap32(v);
    buf_put(b, &be, 4);
}
static inline void put_u16(buf_t *b, uint16_t v) {
    uint16_t be = __builtin_bswap16(v);
    buf_put(b, &be, 2);
}
static void put_cstr(buf_t *b, const char *s) { buf_put(b, s, strlen(s) + 1); }

static inline uint32_t rd_u32(const char *p) {
    uint32_t v;
    memcpy(&v, p, 4);
    return __builtin_bswap32(v);
}
static inline uint16_t rd_u16(const char *p) {
    uint16_t v;
    memcpy(&v, p, 2);
    return __builtin_bswap16(v);
}

static void write_all(int fd, const void *buf, size_t n) {
    const char *p = buf;
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w <= 0) {
            if (errno == EINTR) continue;
            die("pg startup write");
        }
        p += w;
        n -= (size_t)w;
    }
}

static void read_exact(int fd, void *buf, size_t n) {
    char *p = buf;
    while (n > 0) {
        ssize_t r = read(fd, p, n);
        if (r <= 0) {
            if (r < 0 && errno == EINTR) continue;
            die("pg startup read");
        }
        p += r;
        n -= (size_t)r;
    }
}

static int dial_pg(void) {
    struct addrinfo hints = {.ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM}, *res = NULL;
    if (getaddrinfo(pg_host, pg_port, &hints, &res) != 0 || !res) die("getaddrinfo pg");
    int fd = socket(res->ai_family, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) die("socket pg");
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    if (connect(fd, res->ai_addr, res->ai_addrlen) < 0) die("connect pg");
    freeaddrinfo(res);
    return fd;
}

static char read_msg_sync(int fd, buf_t *b) {
    char h[5];
    read_exact(fd, h, 5);
    uint32_t len = rd_u32(h + 1);
    if (len < 4) die("postgres: bad message length");
    b->len = 0;
    buf_reserve(b, len + 1);
    read_exact(fd, b->p, len - 4);
    b->len = len - 4;
    b->p[b->len] = 0;
    return h[0];
}

static const char *scram_attr(const char *msg, char key, size_t *len) {
    for (const char *p = msg; *p;) {
        const char *e = strchr(p, ',');
        if (!e) e = p + strlen(p);
        if (p[0] == key && p[1] == '=') {
            *len = (size_t)(e - p - 2);
            return p + 2;
        }
        p = *e ? e + 1 : e;
    }
    return NULL;
}

static void scram_auth(int fd, buf_t *b) {
    uint8_t rnd[18];
    if (getrandom(rnd, sizeof rnd, 0) != (ssize_t)sizeof rnd) die("getrandom failed");
    char cnonce[32];
    cnonce[b64_enc(cnonce, rnd, sizeof rnd)] = 0;
    char first_bare[64];
    snprintf(first_bare, sizeof first_bare, "n=,r=%s", cnonce);
    char first[80];
    int fl = snprintf(first, sizeof first, "n,,%s", first_bare);

    buf_t m = {0};
    buf_putc(&m, 'p');
    put_u32(&m, 0);
    buf_put(&m, "SCRAM-SHA-256", 14);
    put_u32(&m, (uint32_t)fl);
    buf_put(&m, first, (size_t)fl);
    uint32_t ml = (uint32_t)m.len - 1;
    m.p[1] = (char)(ml >> 24); m.p[2] = (char)(ml >> 16); m.p[3] = (char)(ml >> 8); m.p[4] = (char)ml;
    write_all(fd, m.p, m.len);
    buf_free(&m);

    char t = read_msg_sync(fd, b);
    if (t == 'E') die("postgres auth error");
    if (t != 'R' || b->len < 4 || rd_u32(b->p) != 11) die("postgres auth: expected SASLContinue");
    char server_first[512];
    size_t sl = b->len - 4 < sizeof server_first - 1 ? b->len - 4 : sizeof server_first - 1;
    memcpy(server_first, b->p + 4, sl);
    server_first[sl] = 0;

    size_t rl = 0, sl2 = 0, il = 0;
    const char *r = scram_attr(server_first, 'r', &rl);
    const char *s = scram_attr(server_first, 's', &sl2);
    const char *it = scram_attr(server_first, 'i', &il);
    if (!r || !s || !it || rl < strlen(cnonce) || memcmp(r, cnonce, strlen(cnonce)) != 0) die("postgres auth: bad SCRAM challenge");
    uint8_t salt[128];
    long saltn = b64_dec(salt, s, sl2);
    if (saltn < 0 || saltn > 120) die("postgres auth: bad SCRAM salt");
    int iters = atoi(it);
    if (iters <= 0) die("postgres auth: bad SCRAM iteration count");

    // SaltedPassword = Hi(password, salt, i) (PBKDF2-HMAC-SHA256, one block)
    const char *pw = pg_pass;
    hmac_key_t pk;
    hmac_key_init(&pk, pw, strlen(pw));
    uint8_t u[32], salted[32];
    memcpy(salt + saltn, "\0\0\0\1", 4);
    hmac_sha256_k(&pk, salt, (size_t)saltn + 4, u);
    memcpy(salted, u, 32);
    for (int i = 1; i < iters; i++) {
        hmac_sha256_k(&pk, u, 32, u);
        for (int k = 0; k < 32; k++) salted[k] ^= u[k];
    }
    uint8_t ckey[32], skey[32], csig[32], proof[32];
    hmac_sha256(salted, 32, "Client Key", 10, ckey);
    sha256_t sh;
    sha256_init(&sh);
    sha256_update(&sh, ckey, 32);
    sha256_final(&sh, skey);

    char final_wo[512];
    int fwl = snprintf(final_wo, sizeof final_wo, "c=biws,r=%.*s", (int)rl, r);
    buf_t am = {0};
    buf_put(&am, first_bare, strlen(first_bare));
    buf_putc(&am, ',');
    buf_put(&am, server_first, strlen(server_first));
    buf_putc(&am, ',');
    buf_put(&am, final_wo, (size_t)fwl);
    hmac_sha256(skey, 32, am.p, am.len, csig);
    buf_free(&am);
    for (int k = 0; k < 32; k++) proof[k] = ckey[k] ^ csig[k];
    char final[640];
    int n = snprintf(final, sizeof final, "%s,p=", final_wo);
    n += (int)b64_enc(final + n, proof, 32);

    m = (buf_t){0};
    buf_putc(&m, 'p');
    put_u32(&m, (uint32_t)(4 + n));
    buf_put(&m, final, (size_t)n);
    write_all(fd, m.p, m.len);
    buf_free(&m);

    t = read_msg_sync(fd, b);
    if (t == 'E') die("postgres auth: SASLFinal error");
    if (t != 'R' || rd_u32(b->p) != 12) die("postgres auth: expected SASLFinal");
}

static void startup_and_prepare(int fd) {
    buf_t b = {0};
    put_u32(&b, 0);
    put_u32(&b, 196608); // v3.0
    put_cstr(&b, "user");
    put_cstr(&b, pg_user);
    put_cstr(&b, "database");
    put_cstr(&b, pg_db);
    put_cstr(&b, "client_encoding");
    put_cstr(&b, "UTF8");
    put_cstr(&b, "TimeZone");
    put_cstr(&b, "UTC");
    put_cstr(&b, "options");
    put_cstr(&b, "-c synchronous_commit=on -c jit=off -c max_parallel_workers_per_gather=0 -c work_mem=16MB");
    buf_putc(&b, 0);
    uint32_t l = (uint32_t)b.len;
    b.p[0] = (char)(l >> 24);
    b.p[1] = (char)(l >> 16);
    b.p[2] = (char)(l >> 8);
    b.p[3] = (char)l;
    write_all(fd, b.p, b.len);

    buf_t m = {0};
    for (;;) {
        char hdr[5];
        read_exact(fd, hdr, 5);
        char type = hdr[0];
        uint32_t len = rd_u32(hdr + 1) - 4;
        m.len = 0;
        buf_reserve(&m, len + 1);
        read_exact(fd, m.p, len);
        m.p[len] = 0;

        if (type == 'R') {
            uint32_t code = rd_u32(m.p);
            if (code == 0) continue;
            if (code == 10) { scram_auth(fd, &m); continue; }
            if (code == 3) {
                b.len = 0;
                buf_putc(&b, 'p');
                put_u32(&b, (uint32_t)(4 + strlen(pg_pass) + 1));
                put_cstr(&b, pg_pass);
                write_all(fd, b.p, b.len);
            } else {
                fprintf(stderr, "unsupported pg auth code %u (use scram-sha-256, password or trust)\n", code);
                exit(1);
            }
        } else if (type == 'E') {
            fprintf(stderr, "pg startup error: %s\n", m.p + 1);
            exit(1);
        } else if (type == 'Z') {
            break;
        }
    }

    // Session-level settings (rule 2 explicitly allows this): force generic plans, disable JIT,
    // parallel gather workers, expand temporary buffers for CTE/materialized batches, and disable timeouts.
    const char *opt_query = "SET plan_cache_mode = force_generic_plan; SET jit = off; SET max_parallel_workers_per_gather = 0;";
    size_t qlen = strlen(opt_query) + 1;
    b.len = 0;
    buf_putc(&b, 'Q');
    put_u32(&b, (uint32_t)(4 + qlen));
    buf_put(&b, opt_query, qlen);
    write_all(fd, b.p, b.len);

    for (;;) {
        char hdr[5];
        read_exact(fd, hdr, 5);
        char type = hdr[0];
        uint32_t len = rd_u32(hdr + 1) - 4;
        m.len = 0;
        buf_reserve(&m, len + 1);
        read_exact(fd, m.p, len);
        if (type == 'E') {
            fprintf(stderr, "pg session set error: %s\n", m.p + 1);
            exit(1);
        }
        if (type == 'Z') break;
    }

    b.len = 0;
    for (int i = 0; i < N_STMTS; i++) {
        size_t nl = strlen(STMTS[i].name) + 1, sl = strlen(STMTS[i].sql) + 1;
        buf_putc(&b, 'P');
        put_u32(&b, (uint32_t)(4 + nl + sl + 2));
        buf_put(&b, STMTS[i].name, nl);
        buf_put(&b, STMTS[i].sql, sl);
        put_u16(&b, 0);
    }
    buf_putc(&b, 'S');
    put_u32(&b, 4);
    write_all(fd, b.p, b.len);

    for (;;) {
        char hdr[5];
        read_exact(fd, hdr, 5);
        char type = hdr[0];
        uint32_t len = rd_u32(hdr + 1) - 4;
        m.len = 0;
        buf_reserve(&m, len + 1);
        read_exact(fd, m.p, len);
        if (type == 'E') {
            const char *p = m.p, *end = m.p + len;
            const char *msg = "unknown", *det = "";
            while (p < end && *p) {
                char code = *p++;
                if (code == 'M') msg = p;
                else if (code == 'D') det = p;
                p += strlen(p) + 1;
            }
            fprintf(stderr, "pg prepare error: %s (%s)\n", msg, det);
            exit(1);
        }
        if (type == 'Z') break;
    }

    buf_free(&b);
    buf_free(&m);
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

// ---------- io_uring user_data tagging (shared with server.c) ----------
enum { T_ACCEPT = 1, T_CLIENT_POLL, T_CLIENT_SEND, T_PG_RECV, T_PG_SEND, T_BCRYPT_EVENT };
static inline uint64_t tag_ptr(int tag, void *p) { return ((uint64_t)tag << 56) | (uint64_t)(uintptr_t)p; }

static void arm_pg_recv(pgconn_t *c) {
    if (c->recv_armed) return;
    if (c->in_rp > 0) {
        size_t rem = c->in.len - c->in_rp;
        if (rem) memmove(c->in.p, c->in.p + c->in_rp, rem);
        c->in.len = rem;
        c->in_rp = 0;
    }
    buf_reserve(&c->in, 65536);
    struct io_uring_sqe *sqe = io_uring_get_sqe(&c->w->ring);
    if (!sqe) {
        io_uring_submit(&c->w->ring);
        sqe = io_uring_get_sqe(&c->w->ring);
    }
    io_uring_prep_recv(sqe, c->fd, c->in.p + c->in.len, c->in.cap - c->in.len, 0);
    io_uring_sqe_set_data64(sqe, tag_ptr(T_PG_RECV, c));
    c->recv_armed = true;
}

static void arm_pg_send(pgconn_t *c) {
    if (c->sending) return;
    while (c->out_sp < c->out.len) {
        ssize_t n = send(c->fd, c->out.p + c->out_sp, c->out.len - c->out_sp, MSG_NOSIGNAL);
        if (n > 0) {
            c->out_sp += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct io_uring_sqe *sqe = io_uring_get_sqe(&c->w->ring);
            if (!sqe) {
                io_uring_submit(&c->w->ring);
                sqe = io_uring_get_sqe(&c->w->ring);
            }
            io_uring_prep_send(sqe, c->fd, c->out.p + c->out_sp, c->out.len - c->out_sp, MSG_NOSIGNAL);
            io_uring_sqe_set_data64(sqe, tag_ptr(T_PG_SEND, c));
            c->sending = true;
            return;
        }
        die("pg send");
    }
    c->out.len = 0;
    c->out_sp = 0;
}

void pg_worker_init(worker_t *w, int npg_r, int npg_w) {
    w->npg_r = npg_r;
    w->npg_w = npg_w;
    w->npg = npg_r + npg_w;
    w->pg = calloc((size_t)w->npg, sizeof(pgconn_t));
    for (int i = 0; i < w->npg; i++) {
        pgconn_t *c = &w->pg[i];
        c->w = w;
        c->id = i;
        c->is_write_conn = (i >= npg_r);
        c->fd = dial_pg();
        startup_and_prepare(c->fd);
        c->ready = true;
        buf_reserve(&c->in, 65536);
        buf_reserve(&c->out, 65536);
        arm_pg_recv(c);
    }
}

pgbatch_t *pg_begin_ex(worker_t *w, req_t *r, pg_cb cb, bool is_write) {
    pgbatch_t *b = w->free_batch;
    if (b) {
        w->free_batch = b->next;
    } else {
        b = calloc(1, sizeof(pgbatch_t));
        if (!b) die("out of memory");
    }
    b->next = NULL;
    b->r = r;
    b->cb = cb;
    b->wire.len = 0;
    b->nst = 0;
    b->cur = 0;
    b->failed = false;
    b->is_write = is_write;
    b->behind_w = false;
    b->sqlstate[0] = 0;
    b->errmsg[0] = 0;
    return b;
}

static void pg_batch_free(worker_t *w, pgbatch_t *b) {
    arena_reset(&b->arena);
    b->next = w->free_batch;
    w->free_batch = b;
}

void pg_stmt(pgbatch_t *b, int stmt, const str_t *params) {
    if (__builtin_expect(STATS_ON, 0) && stmt_is_write(stmt)) b->is_write = true;
    else if (stmt_is_write(stmt)) b->is_write = true;

    const stmt_def_t *d = &STMTS[stmt];
    size_t nl = strlen(d->name) + 1;
    size_t body = 1 + nl + 2 + 2;
    for (int i = 0; i < d->nparams; i++) {
        body += 4;
        if (params[i].n != SIZE_MAX) body += params[i].n;
    }
    body += 2;

    buf_t *w = &b->wire;
    buf_putc(w, 'B');
    put_u32(w, (uint32_t)(4 + body));
    buf_putc(w, 0);
    buf_put(w, d->name, nl);
    put_u16(w, 0);
    put_u16(w, (uint16_t)d->nparams);
    for (int i = 0; i < d->nparams; i++) {
        if (params[i].n == SIZE_MAX) {
            put_u32(w, (uint32_t)-1);
        } else {
            put_u32(w, (uint32_t)params[i].n);
            buf_put(w, params[i].p, params[i].n);
        }
    }
    put_u16(w, 0);

    buf_putc(w, 'E');
    put_u32(w, 4 + 1 + 4);
    buf_putc(w, 0);
    put_u32(w, 0);

    pgst_t *st = &b->st[b->nst++];
    st->ncols = 0;
    st->nrows = 0;
    st->cap = 0;
    st->f = NULL;
}

static void send_batch(pgconn_t *c, pgbatch_t *b) {
    if (__builtin_expect(STATS_ON, 0)) b->t_enq = stats_now();
    b->next = NULL;
    if (c->tail) c->tail->next = b;
    else c->head = b;
    c->tail = b;
    c->inflight++;
    if (__builtin_expect(STATS_ON, 0)) stats_pg_enq(c, b);

    if (!c->sending && c->out_sp == c->out.len) {
        c->out.len = 0;
        c->out_sp = 0;
    }
    buf_put(&c->out, b->wire.p, b->wire.len);
    arm_pg_send(c);
}

pgconn_t *pg_pick_idle_read(worker_t *w) {
    for (int depth = 0; depth < 2; depth++) {
        for (int i = 0; i < w->npg_r; i++) {
            pgconn_t *c = &w->pg[i];
            if (c->inflight == depth && !c->sending) return c;
        }
        for (int i = 0; i < w->npg_r; i++) {
            pgconn_t *c = &w->pg[i];
            if (c->inflight == depth) return c;
        }
    }
    return NULL;
}

void pg_end_on(pgconn_t *c, pgbatch_t *b) {
    buf_putc(&b->wire, 'S');
    put_u32(&b->wire, 4);
    send_batch(c, b);
}

static pgconn_t *pick_write_conn(worker_t *w) {
    int start = w->npg_w > 0 ? w->npg_r : 0;
    int end = w->npg;
    int best = -1, best_score = 1 << 30;
    for (int i = start; i < end; i++) {
        pgconn_t *c = &w->pg[i];
        if (c->inflight >= MAX_WRITE_PIPELINE) continue;
        int score = c->inflight * 2 + (c->sending ? 1 : 0);
        if (score < best_score) {
            best = i;
            best_score = score;
        }
    }
    return best >= 0 ? &w->pg[best] : NULL;
}

static pgconn_t *pick_read_conn_fallback(worker_t *w) {
    int end = w->npg_r > 0 ? w->npg_r : w->npg;
    int best = 0, best_score = 1 << 30;
    for (int i = 0; i < end; i++) {
        pgconn_t *c = &w->pg[i];
        int score = c->inflight * 2 + (c->sending ? 1 : 0);
        if (score < best_score) {
            best = i;
            best_score = score;
        }
    }
    return &w->pg[best];
}

void pg_end(pgbatch_t *b) {
    buf_putc(&b->wire, 'S');
    put_u32(&b->wire, 4);

    worker_t *w = b->r ? b->r->w : NULL;
    if (!b->is_write) {
        pgconn_t *c = pg_pick_idle_read(w);
        if (!c) c = pick_read_conn_fallback(w);
        send_batch(c, b);
        return;
    }

    pgconn_t *c = pick_write_conn(w);
    if (c) {
        send_batch(c, b);
    } else {
        b->next = NULL;
        if (w->wq_tail) w->wq_tail->next = b;
        else w->wq_head = b;
        w->wq_tail = b;
        w->wq_n++;
    }
}

void pg_send_done(pgconn_t *c, int res) {
    c->sending = false;
    if (res <= 0) die("pg async send");
    c->out_sp += (size_t)res;
    arm_pg_send(c);
}

static void parse_datarow(pgbatch_t *b, const char *body, uint32_t len) {
    if (b->cur >= b->nst) return;
    pgst_t *st = &b->st[b->cur];
    int ncols = rd_u16(body);
    if (st->nrows == 0) st->ncols = ncols;
    if (st->nrows == st->cap) {
        int ncap = st->cap ? st->cap * 2 : 8;
        pgf_t *nf = arena_alloc(&b->arena, (size_t)ncap * (size_t)(ncols ? ncols : 1) * sizeof(pgf_t));
        if (st->nrows > 0) memcpy(nf, st->f, (size_t)st->nrows * (size_t)ncols * sizeof(pgf_t));
        st->f = nf;
        st->cap = ncap;
    }
    char *copy = arena_alloc(&b->arena, len);
    memcpy(copy, body, len);
    const char *p = copy + 2;
    pgf_t *row = st->f + (size_t)st->nrows * (size_t)ncols;
    for (int i = 0; i < ncols; i++) {
        int32_t flen = (int32_t)rd_u32(p);
        p += 4;
        if (flen < 0) {
            row[i] = (pgf_t){NULL, -1};
        } else {
            row[i] = (pgf_t){p, flen};
            p += flen;
        }
    }
    st->nrows++;
}

static void parse_error(pgbatch_t *b, const char *p, uint32_t len) {
    b->failed = true;
    const char *end = p + len;
    while (p < end && *p) {
        char code = *p++;
        size_t sl = strlen(p);
        if (code == 'C') snprintf(b->sqlstate, sizeof b->sqlstate, "%s", p);
        else if (code == 'M') snprintf(b->errmsg, sizeof b->errmsg, "%s", p);
        p += sl + 1;
    }
}

static void finish_head(pgconn_t *c) {
    worker_t *w = c->w;
    pgbatch_t *b = c->head;
    if (!b) return;
    c->head = b->next;
    if (!c->head) c->tail = NULL;
    c->inflight--;
    if (__builtin_expect(STATS_ON, 0)) stats_pg_done(c, b);

    b->cb(b->r, b);
    pg_batch_free(w, b);

    if (c->is_write_conn) {
        while (w->wq_head && c->inflight < MAX_WRITE_PIPELINE) {
            pgbatch_t *nx = w->wq_head;
            w->wq_head = nx->next;
            if (!w->wq_head) w->wq_tail = NULL;
            w->wq_n--;
            send_batch(c, nx);
        }
    }
}

void pg_readable(pgconn_t *c, int res) {
    c->recv_armed = false;
    if (res <= 0) die("pg connection closed");
    c->in.len += (size_t)res;

    for (;;) {
        size_t avail = c->in.len - c->in_rp;
        if (avail < 5) break;
        const char *hdr = c->in.p + c->in_rp;
        char type = hdr[0];
        uint32_t mlen = rd_u32(hdr + 1);
        if (avail < 1 + (size_t)mlen) break;
        const char *body = hdr + 5;
        uint32_t blen = mlen - 4;
        c->in_rp += 1 + (size_t)mlen;

        pgbatch_t *b = c->head;
        switch (type) {
        case '2':
        case 'n':
            break;
        case 'D':
            if (b && !b->failed) parse_datarow(b, body, blen);
            break;
        case 'C':
        case 'I':
            if (b && !b->failed) b->cur++;
            break;
        case 'E':
            if (b) parse_error(b, body, blen);
            break;
        case 'Z':
            finish_head(c);
            api_flush_coalesced(c->w);
            break;
        default:
            break;
        }
    }
    arm_pg_recv(c);
}
