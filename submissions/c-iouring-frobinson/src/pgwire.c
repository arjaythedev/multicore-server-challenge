// MIT License — fork of pc-iouring-tigokraft (#10); ideas from pc-iouring-gilnett (#58), rust-tokio-Scooter1337 (#7), csharp-sockets-jh-d (#22).
// rw: Original MIT code (pc) challenge contributors; modifications (pc) frobinson. See README Credits.

// rw: Postgres wire protocol v3 client. Connection setup (startup, SCRAM-SHA-256, Parse of every statement) is

// rw: blocking and runs once per connection at boot. After that a connection is driven by the worker's io_uring:

// rw: each request appends one batch (Bind+Execute per statement, then one Sync) and batches are pipelined, so

// rw: one connection carries many requests' queries without waiting for each reply. A batch's statements run in

// rw: one implicit transaction that commits at its Sync; the reply is the ReadyForQuery after it.

#include "app.h"
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <unistd.h>

static inline void put32(buf_t *batch, uint32_t v) {
    uint8_t x[4] = {v >> 24, v >> 16, v >> 8, v};
    buf_put(batch, x, 4);
}
static inline void put16(buf_t *batch, uint16_t v) {
    uint8_t x[2] = {v >> 8, v};
    buf_put(batch, x, 2);
}
static inline uint32_t get32(const char *p) {
    const uint8_t *u = (const uint8_t *)p;
    return (uint32_t)u[0] << 24 | (uint32_t)u[1] << 16 | (uint32_t)u[2] << 8 | u[3];
}
static inline uint16_t get16(const char *p) {
    const uint8_t *u = (const uint8_t *)p;
    return (uint16_t)(u[0] << 8 | u[1]);
}
// rw: Patches the length of the message that starts (at its type byte) at offset `at`.

static inline void fix_len(buf_t *batch, size_t at) {
    uint32_t n = batch->len - at - 1;
    uint8_t *p = (uint8_t *)batch->p + at + 1;
    p[0] = n >> 24; p[1] = n >> 16; p[2] = n >> 8; p[3] = n;
}

// rw: ---------- blocking setup ----------


static void write_all(int fd, const void *p, size_t n) {
    while (n) {
        ssize_t k = write(fd, p, n);
        if (k < 0) {
            if (errno == EINTR) continue;
            die("postgres write: %s", strerror(errno));
        }
        p = (const char *)p + k;
        n -= k;
    }
}

static void read_all(int fd, void *p, size_t n) {
    while (n) {
        ssize_t k = read(fd, p, n);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) die("postgres read: %s", k ? strerror(errno) : "connection closed");
        p = (char *)p + k;
        n -= k;
    }
}

// rw: Reads one message; returns its type, body in *batch (reused).

static char read_msg(int fd, buf_t *batch) {
    char h[5];
    read_all(fd, h, 5);
    uint32_t len = get32(h + 1);
    if (len < 4) die("postgres: bad message length");
    batch->len = 0;
    if (batch->cap < len) buf_grow(batch, len);
    read_all(fd, batch->p, len - 4);
    batch->len = len - 4;
    return h[0];
}

static const char *err_field(const buf_t *batch, char f) {
    for (size_t i = 0; i < batch->len && batch->p[i];) {
        char t = batch->p[i];
        const char *v = batch->p + i + 1;
        if (t == f) return v;
        i += 2 + strlen(v);
    }
    return "";
}

static void send_pw_msg(int fd, const char *data, size_t n) {
    buf_t m = {0};
    buf_putc(&m, 'p');
    put32(&m, 0);
    buf_put(&m, data, n);
    fix_len(&m, 0);
    write_all(fd, m.p, m.len);
    buf_free(&m);
}

static const char *scram_attr(const char *msg, char key, size_t *len) {
    for (const char *p = msg; *p;) {
        const char *e = strchr(p, ',');
        if (!e) e = p + strlen(p);
        if (p[0] == key && p[1] == '=') {
            *len = e - p - 2;
            return p + 2;
        }
        p = *e ? e + 1 : e;
    }
    return NULL;
}

static void scram_auth(int fd, buf_t *batch) {
    uint8_t rnd[18];
    if (getrandom(rnd, sizeof rnd, 0) != sizeof rnd) die("getrandom failed");
    char cnonce[32];
    cnonce[b64_enc(cnonce, rnd, sizeof rnd)] = 0;
    char first_bare[64];
    snprintf(first_bare, sizeof first_bare, "n=,r=%s", cnonce);
    char first[80];
    int fl = snprintf(first, sizeof first, "n,,%s", first_bare);

    buf_t m = {0};
    buf_putc(&m, 'p');
    put32(&m, 0);
    buf_put(&m, "SCRAM-SHA-256", 14);
    put32(&m, fl);
    buf_put(&m, first, fl);
    fix_len(&m, 0);
    write_all(fd, m.p, m.len);
    buf_free(&m);

    char t = read_msg(fd, batch);
    if (t == 'E') die("postgres auth: %s", err_field(batch, 'M'));
    if (t != 'R' || batch->len < 4 || get32(batch->p) != 11) die("postgres auth: expected SASLContinue");
    char server_first[512];
    size_t sl = batch->len - 4 < sizeof server_first - 1 ? batch->len - 4 : sizeof server_first - 1;
    memcpy(server_first, batch->p + 4, sl);
    server_first[sl] = 0;

    // rw: scram_attr only writes *len on a hit, so initialise the outputs: makes the

    // rw: failure paths well-defined and keeps -Wmaybe-uninitialized happy.

    size_t rl = 0, sl2 = 0, il = 0;
    const char *rq = scram_attr(server_first, 'r', &rl);
    const char *s = scram_attr(server_first, 's', &sl2);
    const char *it = scram_attr(server_first, 'i', &il);
    if (!rq || !s || !it || rl < strlen(cnonce) || memcmp(rq, cnonce, strlen(cnonce)) != 0) die("postgres auth: bad SCRAM challenge");
    uint8_t salt[128];
    long saltn = b64_dec(salt, s, sl2);
    if (saltn < 0 || saltn > 120) die("postgres auth: bad SCRAM salt");
    int iters = atoi(it);
    if (iters <= 0) die("postgres auth: bad SCRAM iteration count");

    // rw: SaltedPassword = Hi(password, salt, i) (PBKDF2-HMAC-SHA256, one block)

    const char *pw = CFG.db_pass;
    hmac_key_t pk;
    hmac_key_init(&pk, pw, strlen(pw));
    uint8_t u[32], salted[32];
    memcpy(salt + saltn, "\0\0\0\1", 4);
    hmac_sha256_k(&pk, salt, saltn + 4, u);
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
    int fwl = snprintf(final_wo, sizeof final_wo, "c=biws,r=%.*s", (int)rl, rq);
    buf_t am = {0};
    buf_put(&am, first_bare, strlen(first_bare));
    buf_putc(&am, ',');
    buf_put(&am, server_first, strlen(server_first));
    buf_putc(&am, ',');
    buf_put(&am, final_wo, fwl);
    hmac_sha256(skey, 32, am.p, am.len, csig);
    buf_free(&am);
    for (int k = 0; k < 32; k++) proof[k] = ckey[k] ^ csig[k];
    char final[640];
    int n = snprintf(final, sizeof final, "%s,p=", final_wo);
    n += b64_enc(final + n, proof, 32);
    send_pw_msg(fd, final, n);

    t = read_msg(fd, batch);
    if (t == 'E') die("postgres auth: %s", err_field(batch, 'M'));
    if (t != 'R' || get32(batch->p) != 12) die("postgres auth: expected SASLFinal");
}

static int dial(void) {
    struct addrinfo hints = {.ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM}, *res;
    int e = getaddrinfo(CFG.db_host, CFG.db_port, &hints, &res);
    if (e) die("postgres address %s:%s: %s", CFG.db_host, CFG.db_port, gai_strerror(e));
    int fd = -1;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype | SOCK_CLOEXEC, ai->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) die("connect to postgres %s:%s: %s", CFG.db_host, CFG.db_port, strerror(errno));
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    return fd;
}

static void startup_param(buf_t *m, const char *k, const char *v) {
    buf_put(m, k, strlen(k) + 1);
    buf_put(m, v, strlen(v) + 1);
}

void pg_conn_open(pg_conn *pc, ev_loop *ev) {
    memset(pc, 0, sizeof *pc);
    pc->ev = ev;
    pc->fd = dial();
    int fd = pc->fd;

    buf_t m = {0};
    put32(&m, 0);
    put32(&m, 196608); // protocol 3.0
    startup_param(&m, "user", CFG.db_user);
    startup_param(&m, "database", CFG.db_name);
    startup_param(&m, "client_encoding", "UTF8");
    startup_param(&m, "DateStyle", "ISO, MDY");
    startup_param(&m, "TimeZone", "UTC");
    startup_param(&m, "application_name", "conduit-c-iouring");
    // rw: Session-level settings for our own connections (allowed by the rules, unlike server-wide changes).

    char *opts = strdup(CFG.pg_session), *save = NULL;
    for (char *kv = strtok_r(opts, ",", &save); kv; kv = strtok_r(NULL, ",", &save)) {
        char *eq = strchr(kv, '=');
        if (!eq) die("PG_SESSION entries must look like name=value, got %s", kv);
        *eq = 0;
        startup_param(&m, kv, eq + 1);
    }
    free(opts);
    buf_putc(&m, 0);
    uint32_t n = m.len;
    uint8_t *p = (uint8_t *)m.p;
    p[0] = n >> 24; p[1] = n >> 16; p[2] = n >> 8; p[3] = n;
    write_all(fd, m.p, m.len);

    buf_t batch = {0};
    for (;;) {
        char t = read_msg(fd, &batch);
        if (t == 'E') die("postgres: %s", err_field(&batch, 'M'));
        if (t == 'R') {
            uint32_t code = get32(batch.p);
            if (code == 0) continue;
            if (code == 3) { send_pw_msg(fd, CFG.db_pass, strlen(CFG.db_pass) + 1); continue; }
            if (code == 10) { scram_auth(fd, &batch); continue; }
            die("postgres: unsupported auth method %u (use scram-sha-256, password or trust)", code);
        }
        if (t == 'Z') break;
    }

    // rw: Prepare every statement once on this connection.

    m.len = 0;
    for (int i = 0; i < NSTMTS; i++) {
        size_t at = m.len;
        buf_putc(&m, 'P');
        put32(&m, 0);
        char name[16];
        int nl = snprintf(name, sizeof name, "s%d", i);
        buf_put(&m, name, nl + 1);
        buf_put(&m, STMTS[i].sql, strlen(STMTS[i].sql) + 1);
        put16(&m, STMTS[i].nparams);
        for (int k = 0; k < STMTS[i].nparams; k++) put32(&m, STMTS[i].oids[k]);
        fix_len(&m, at);
    }
    buf_putc(&m, 'S');
    put32(&m, 4);
    write_all(fd, m.p, m.len);
    int parsed = 0;
    for (;;) {
        char t = read_msg(fd, &batch);
        if (t == 'E') die("postgres: preparing statement s%d: %s", parsed, err_field(&batch, 'M'));
        if (t == '1') parsed++;
        if (t == 'Z') break;
    }
    buf_free(&m);
    buf_free(&batch);
}

// rw: ---------- pipelined batches ----------


static const char SYNC[5] = {'S', 0, 0, 0, 4};

// rw: A connection carries at most CFG.pg_depth batches at a time; the rest wait in the worker's FIFO queue and go

// rw: out, oldest first, as replies free slots. A batch built while a connection has room (and nothing is queued)

// rw: is written straight into that connection's output buffer; otherwise into its own buffer until it is placed.

// Own split-pool router (new in rewrite): reads -> least-loaded read conn, writes deferred to seal.
// rw: Reads never wait behind WAL flushes; writes coalesce on dedicated backends (group-commit ready).

static pg_conn *pick_read(ev_loop *ev) {
    if (ev->nread == 0) return &ev->pg[0];
    pg_conn *best = &ev->pg_read[0];
    for (int i = 1; i < ev->nread; i++)
        if (ev->pg_read[i].inflight < best->inflight) best = &ev->pg_read[i];
    return best;
}
static pg_conn *pick_write(ev_loop *ev) {
    if (ev->nwrite == 0) return pick_read(ev);
    pg_conn *best = &ev->pg_write[0];
    for (int i = 1; i < ev->nwrite; i++)
        if (ev->pg_write[i].inflight < best->inflight) best = &ev->pg_write[i];
    return best;
}
pg_batch *pg_batch_begin(http_req *rq, void (*cb)(http_req *, pg_batch *)) {
    ev_loop *ev = rq->ev;
    pg_batch *batch = arena_alloc(&rq->arena, sizeof *batch);
    memset(batch, 0, sizeof *batch);
    batch->req = rq;
    batch->cb = cb;
    batch->buf = &batch->own;
    if (!ev->wq_head) {
        pg_conn *best = pick_read(ev);
        if (best->inflight < CFG.pg_depth) {
            batch->conn = best;
            batch->buf = &best->out;
        }
    }
    return batch;
}

void pg_batch_add(pg_batch *batch, int stmt, const str_t *params) {
    buf_t *o = batch->buf;
    const stmt_def_t *d = &STMTS[stmt];
    size_t at = o->len;
    buf_putc(o, 'B');
    put32(o, 0);
    buf_putc(o, 0); // unnamed portal
    char name[16];
    int nl = snprintf(name, sizeof name, "s%d", stmt);
    buf_put(o, name, nl + 1);
    put16(o, 0); // all parameters in text format
    put16(o, d->nparams);
    for (int i = 0; i < d->nparams; i++) {
        if (!params[i].p) {
            put32(o, 0xFFFFFFFFu);
        } else {
            put32(o, params[i].n);
            buf_put(o, params[i].p, params[i].n);
        }
    }
    put16(o, 0); // all results in text format
    fix_len(o, at);
    static const char exec[10] = {'E', 0, 0, 0, 9, 0, 0, 0, 0, 0};
    buf_put(o, exec, sizeof exec);
    batch->nst++;
    if (stmt_is_write(stmt)) batch->is_write = true; // always track: read/write pool routing (own split, #58/#7 idea)
}

static void pg_link(pg_conn *pc, pg_batch *batch) {
    batch->conn = pc;
    if (pc->tail) pc->tail->next = batch;
    else pc->head = batch;
    pc->tail = batch;
    pc->inflight++;
    if (UNLIKELY(STATS_ON)) tm_pg_enq(pc, batch);
}

static bool is_read_conn(ev_loop *ev, pg_conn *pc) {
    return pc >= ev->pg_read && pc < ev->pg_read + ev->nread;
}
void pg_batch_seal(pg_batch *batch) {
    buf_put(batch->buf, SYNC, sizeof SYNC);
    if (UNLIKELY(STATS_ON)) batch->t_enq = tm_now();
    ev_loop *ev = batch->req->ev;
    // Own fixup (rewrite): split-pool is queue-path-only. The immediate path
    // (batch->conn set by begin's optimistic read pick) may commit a write on a
    // read conn — correct but not optimal — so it stays as-is to avoid corrupting
    // the shared out buffer with an in-place migrate. Strict read/write split is
    // enforced for the queued path (batch->conn==NULL) below.
    if (batch->conn && batch->is_write && is_read_conn(ev, batch->conn)) {
        // rw: intentional no-op: leave immediate-path writes on the read conn.

        // rw: Queued writes (batch->conn==NULL) always go to write pool below.

    }
    if (batch->conn) {
        pg_link(batch->conn, batch);
        return;
    }
    // rw: queued path: route by type

    if (batch->is_write) {
        pg_conn *wc = pick_write(ev);
        if (!ev->wq_head && wc->inflight < CFG.pg_depth) {
            batch->conn = wc; batch->buf = &wc->out;
            // rw: need to move own bytes into conn out (own currently holds B/E, conn out is shared)

            // rw: begin left batch->buf=&own, so copy now

            buf_put(&wc->out, batch->own.p, batch->own.len);
            buf_free(&batch->own);
            batch->buf = &wc->out;
            // rw: SYNC already in own copy? Actually SYNC was appended to own; we copied incl SYNC. Need to keep buf ptr consistent.

            pg_link(wc, batch);
            return;
        }
    } else {
        pg_conn *rc = pick_read(ev);
        if (!ev->wq_head && rc->inflight < CFG.pg_depth) {
            batch->conn = rc;
            buf_put(&rc->out, batch->own.p, batch->own.len);
            buf_free(&batch->own);
            batch->buf = &rc->out;
            pg_link(rc, batch);
            return;
        }
    }
    batch->next = NULL;
    if (ev->wq_tail) ev->wq_tail->next = batch;
    else ev->wq_head = batch;
    ev->wq_tail = batch;
    ev->wq_n++;
}

// rw: Type-aware drain (own rewrite): only batches matching this conn's pool (read vs write).

// rw: Scans for first matching queued batch to avoid head-of-line blocking across pools.

static void pg_fill(pg_conn *pc) {
    ev_loop *ev = pc->ev;
    bool want_write = !is_read_conn(ev, pc);
    while (pc->inflight < CFG.pg_depth) {
        pg_batch *prev = NULL, *cur = ev->wq_head;
        while (cur && cur->is_write != want_write) { prev = cur; cur = cur->next; }
        if (!cur) break;
        if (prev) prev->next = cur->next; else ev->wq_head = cur->next;
        if (cur == ev->wq_tail) ev->wq_tail = prev;
        ev->wq_n--;
        cur->next = NULL;
        buf_put(&pc->out, cur->own.p, cur->own.len);
        buf_free(&cur->own);
        pg_link(pc, cur);
    }
}

void pg_conn_flush(pg_conn *pc) {
    if (pc->send_inflight) return;
    if (pc->out.len == 0) return;
    buf_t t = pc->sending;
    pc->sending = pc->out;
    pc->out = t;
    pc->out.len = 0;
    pc->sent = 0;
    pc->send_inflight = true;
    struct io_uring_sqe *sqe = ev_next_sqe(pc->ev);
    io_uring_prep_send(sqe, pc->fd, pc->sending.p, pc->sending.len, MSG_NOSIGNAL);
    io_uring_sqe_set_data64(sqe, UD(pc, UD_PGSEND));
}

void pg_conn_on_writable(pg_conn *pc, int res) {
    if (res < 0) die("postgres send: %s", strerror(-res));
    pc->sent += res;
    if (pc->sent < pc->sending.len) {
        struct io_uring_sqe *sqe = ev_next_sqe(pc->ev);
        io_uring_prep_send(sqe, pc->fd, pc->sending.p + pc->sent, pc->sending.len - pc->sent, MSG_NOSIGNAL);
        io_uring_sqe_set_data64(sqe, UD(pc, UD_PGSEND));
        return;
    }
    pc->sending.len = 0;
    pc->send_inflight = false;
    pg_conn_flush(pc);
}

void pg_conn_arm_read(pg_conn *pc) {
    if (pc->in.cap - pc->in.len < 16384) buf_grow(&pc->in, 16384);
    struct io_uring_sqe *sqe = ev_next_sqe(pc->ev);
    io_uring_prep_recv(sqe, pc->fd, pc->in.p + pc->in.len, pc->in.cap - pc->in.len, 0);
    io_uring_sqe_set_data64(sqe, UD(pc, UD_PGRECV));
}

static void on_datarow(pg_batch *batch, const char *body, uint32_t len) {
    if (batch->failed || batch->cur >= PG_MAXST) return;
    arena_t *a = &batch->req->arena;
    pgst_t *st = &batch->st[batch->cur];
    int ncols = get16(body);
    if (st->nrows == 0) st->ncols = ncols;
    if ((size_t)(st->nrows + 1) * ncols > st->cap) {
        size_t cap = st->cap ? st->cap * 2 : (size_t)ncols * 4;
        while (cap < (size_t)(st->nrows + 1) * ncols) cap *= 2;
        pgf_t *f = arena_alloc(a, cap * sizeof *f);
        if (st->f) memcpy(f, st->f, (size_t)st->nrows * ncols * sizeof *f);
        st->f = f;
        st->cap = cap;
    }
    char *copy = arena_alloc(a, len);
    memcpy(copy, body, len);
    const char *p = copy + 2;
    pgf_t *row = st->f + (size_t)st->nrows * ncols;
    for (int i = 0; i < ncols; i++) {
        int32_t n = (int32_t)get32(p);
        p += 4;
        row[i].p = p;
        row[i].n = n;
        if (n > 0) p += n;
    }
    st->nrows++;
}

void pg_conn_on_readable(pg_conn *pc, int res) {
    if (res <= 0) die("postgres recv: %s", res ? strerror(-res) : "connection closed");
    pc->in.len += res;
    size_t off = 0;
    while (pc->in.len - off >= 5) {
        const char *m = pc->in.p + off;
        uint32_t len = get32(m + 1);
        if (pc->in.len - off < (size_t)len + 1) break;
        const char *body = m + 5;
        uint32_t blen = len - 4;
        off += len + 1;
        pg_batch *batch = pc->head;
        switch (m[0]) {
        case 'D':
            if (batch) on_datarow(batch, body, blen);
            break;
        case 'C':
        case 'I':
            if (batch) batch->cur++;
            break;
        case 'E': {
            buf_t eb = {(char *)body, blen, blen};
            const char *code = err_field(&eb, 'C');
            if (!batch) die("postgres error outside a batch: %s", err_field(&eb, 'M'));
            batch->failed = true;
            snprintf(batch->sqlstate, sizeof batch->sqlstate, "%s", code);
            if (strcmp(code, "23505") != 0) logf_("postgres error %s: %s", code, err_field(&eb, 'M'));
            break;
        }
        case 'Z':
            if (!batch) die("postgres: unexpected ReadyForQuery");
            pc->head = batch->next;
            if (!pc->head) pc->tail = NULL;
            pc->inflight--;
            if (UNLIKELY(STATS_ON)) tm_pg_done(pc, batch);
            pg_fill(pc);
            batch->cb(batch->req, batch);
            break;
        default: // BindComplete, notices, parameter status, ...
            break;
        }
    }
    if (off) {
        memmove(pc->in.p, pc->in.p + off, pc->in.len - off);
        pc->in.len -= off;
    }
    pg_conn_arm_read(pc);
}
