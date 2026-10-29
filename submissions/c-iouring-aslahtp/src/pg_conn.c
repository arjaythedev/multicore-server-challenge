#include "pg_conn.h"

#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <unistd.h>

#include "sql.h"

void random_bytes(void *buf, size_t n) {
    uint8_t *p = buf;
    while (n) {
        ssize_t r = getrandom(p, n, 0);
        if (r < 0) {
            if (errno == EINTR) continue;
            die("getrandom: %s", strerror(errno));
        }
        p += r, n -= (size_t)r;
    }
}

struct conn_io {
    int fd;
    struct buf in, out;
    size_t pos;  /* consumed bytes in `in` */
};

static bool flush(struct conn_io *c) {
    size_t off = 0;
    while (off < c->out.len) {
        ssize_t n = send(c->fd, c->out.p + off, c->out.len - off, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        off += (size_t)n;
    }
    c->out.len = 0;
    return true;
}

/* Blocks until a whole message is available. */
static bool next_msg(struct conn_io *c, struct pg_msg *m) {
    for (;;) {
        ptrdiff_t n = pg_next((const uint8_t *)c->in.p + c->pos, c->in.len - c->pos, m);
        if (n < 0) return false;
        if (n > 0) {
            c->pos += (size_t)n;
            return true;
        }
        if (c->pos) {
            memmove(c->in.p, c->in.p + c->pos, c->in.len - c->pos);
            c->in.len -= c->pos;
            c->pos = 0;
        }
        char *dst = buf_reserve(&c->in, 16384);
        ssize_t r = recv(c->fd, dst, c->in.cap - c->in.len, 0);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return false;
        c->in.len += (size_t)r;
    }
}

static int connect_tcp(const struct pg_url *u, char *err, size_t errlen) {
    struct addrinfo hints = {.ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM}, *res, *ai;
    int rc = getaddrinfo(u->host, u->port, &hints, &res);
    if (rc) {
        snprintf(err, errlen, "resolve %s:%s: %s", u->host, u->port, gai_strerror(rc));
        return -1;
    }
    int fd = -1;
    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype | SOCK_CLOEXEC, ai->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) {
        snprintf(err, errlen, "connect %s:%s: %s", u->host, u->port, strerror(errno));
        return -1;
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    return fd;
}

static bool authenticate(struct conn_io *c, const struct pg_url *u, char *err, size_t errlen) {
    struct pg_auth auth;
    struct pg_msg m;
    uint8_t nonce[18];
    random_bytes(nonce, sizeof nonce);
    pg_auth_init(&auth, u->user, u->password, nonce);
    pg_startup(&c->out, u->user, u->dbname);
    if (!flush(c)) goto io_error;
    for (;;) {
        if (!next_msg(c, &m)) goto io_error;
        int st = pg_auth_step(&auth, &m, &c->out);
        if (st == PG_AUTH_FAILED) {
            snprintf(err, errlen, "authentication: %s", auth.error);
            return false;
        }
        if (c->out.len && !flush(c)) goto io_error;
        if (st == PG_AUTH_READY) return true;
    }
io_error:
    snprintf(err, errlen, "connection lost during startup");
    return false;
}

/* Runs the session SETs (simple query protocol), all sent at once. */
static bool session_settings(struct conn_io *c, char *err, size_t errlen) {
    struct pg_msg m;
    int pending = 0;
    for (const char *const *q = session_sql; *q; q++, pending++) pg_query(&c->out, *q);
    if (session_tune)
        for (const char *const *q = session_tune_sql; *q; q++, pending++) pg_query(&c->out, *q);
    if (!flush(c)) goto io_error;
    while (pending) {
        if (!next_msg(c, &m)) goto io_error;
        if (m.type == 'E') {
            struct pg_error e;
            pg_parse_error(&m, &e);
            snprintf(err, errlen, "session setting: %s %s", e.sqlstate, e.message);
            return false;
        }
        if (m.type == 'Z') pending--;
    }
    return true;
io_error:
    snprintf(err, errlen, "connection lost during session settings");
    return false;
}

/* Parse + Describe for every statement, one Sync, then check each RowDescription. */
static bool prepare_all(struct conn_io *c, char *err, size_t errlen) {
    struct pg_msg m;
    for (int i = 0; i < S_COUNT; i++) {
        pg_parse(&c->out, stmt_names[i], stmts[i].sql, stmts[i].nparams, stmts[i].params);
        pg_describe_stmt(&c->out, stmt_names[i]);
    }
    pg_sync(&c->out);
    if (!flush(c)) goto io_error;

    int i = 0;  /* statement whose description comes next */
    for (;;) {
        if (!next_msg(c, &m)) goto io_error;
        switch (m.type) {
        case 'E': {
            struct pg_error e;
            pg_parse_error(&m, &e);
            snprintf(err, errlen, "prepare %s: %s %s", i < S_COUNT ? stmt_names[i] : "?", e.sqlstate, e.message);
            return false;
        }
        case 'n':  /* NoData: a statement without result columns */
            if (i >= S_COUNT || stmts[i].ncols != 0) {
                snprintf(err, errlen, "statement %s returns no rows, expected %d columns", stmt_names[i],
                         i < S_COUNT ? stmts[i].ncols : -1);
                return false;
            }
            i++;
            break;
        case 'T': {
            if (i >= S_COUNT || m.len < 2) goto protocol;
            uint16_t n = load_be16(m.body);
            if (n != stmts[i].ncols) {
                snprintf(err, errlen, "statement %s returns %u columns, expected %u", stmt_names[i], n,
                         stmts[i].ncols);
                return false;
            }
            const uint8_t *p = m.body + 2, *end = m.body + m.len;
            for (uint16_t col = 0; col < n; col++) {
                const uint8_t *name = p;
                p = memchr(p, 0, (size_t)(end - p));
                if (!p || end - p < 19) goto protocol;
                p++;
                uint32_t oid = load_be32(p + 6);  /* after table oid (4) and column number (2) */
                if (oid != stmts[i].cols[col]) {
                    snprintf(err, errlen, "statement %s column %u (%s) has type %u, expected %u", stmt_names[i],
                             col, (const char *)name, oid, stmts[i].cols[col]);
                    return false;
                }
                p += 18;
            }
            i++;
            break;
        }
        case 'Z':
            if (i != S_COUNT) goto protocol;
            return true;
        default:  /* ParseComplete, ParameterDescription, notices */
            break;
        }
    }
protocol:
    snprintf(err, errlen, "unexpected reply while preparing statements");
    return false;
io_error:
    snprintf(err, errlen, "connection lost while preparing statements");
    return false;
}

int pg_open(const struct pg_url *u, char *err, size_t errlen) {
    struct conn_io c = {.fd = connect_tcp(u, err, errlen)};
    if (c.fd < 0) return -1;
    buf_init(&c.in, 16384);
    buf_init(&c.out, 16384);
    bool ok = authenticate(&c, u, err, errlen) && session_settings(&c, err, errlen) && prepare_all(&c, err, errlen);
    if (ok && c.pos != c.in.len) {
        snprintf(err, errlen, "unexpected bytes after startup");
        ok = false;
    }
    buf_free(&c.in);
    buf_free(&c.out);
    if (!ok) {
        close(c.fd);
        return -1;
    }
    return c.fd;
}
