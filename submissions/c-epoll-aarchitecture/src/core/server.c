#include "core/server.h"

#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "config.h"
#include "pg/pg.h"
#include "util.h"

static void on_accept(void *user, loop_fd *self, unsigned events);

void srv_worker_init(srv_worker *w, int id, const char *db_url, int read_conns,
                     int write_conns, int read_batch, int read_window_ms,
                     int write_group, int write_window_ms, const char *jwt_secret,
                     const char *host, const char *port, const conn_hooks *hooks) {
    memset(w, 0, sizeof *w);
    w->id = id;
    w->jwt_secret = jwt_secret;
    w->hooks = hooks;
    w->read_conns = read_conns;
    w->write_conns = write_conns;
    w->loop = loop_create();

    pg_pool_open(&w->pg, db_url, read_conns, write_conns, read_batch,
                 read_window_ms, write_group, write_window_ms, id, w->loop);

    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE | AI_NUMERICHOST | AI_NUMERICSERV;

    struct addrinfo *ai = NULL;
    int gai = getaddrinfo(host, port, &hints, &ai);
    CHECK(gai == 0, "worker %d: getaddrinfo %s:%s: %s", id, host, port,
          gai_strerror(gai));

    int fd = socket(ai->ai_family, ai->ai_socktype | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    CHECK(fd >= 0, "worker %d: socket: %s", id, strerror(errno));
    int one = 1;
    CHECK(setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one) == 0,
          "worker %d: SO_REUSEADDR: %s", id, strerror(errno));
    CHECK(setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one) == 0,
          "worker %d: SO_REUSEPORT: %s", id, strerror(errno));
    CHECK(bind(fd, ai->ai_addr, ai->ai_addrlen) == 0,
          "worker %d: bind %s:%s: %s", id, host, port, strerror(errno));
    CHECK(listen(fd, LISTEN_BACKLOG) == 0, "worker %d: listen: %s", id,
          strerror(errno));
    freeaddrinfo(ai);

    w->listen_fd = fd;
    w->listen_ev = loop_add(w->loop, fd, LOOP_IN, on_accept, w);
    CHECK(w->listen_ev != NULL, "worker %d: loop_add(listener) failed", id);
}

static void sweep_timer(void *user) {
    conn_sweep((srv_worker *)user);
}

void srv_worker_run(srv_worker *w) {
    loop_timer(w->loop, SWEEP_INTERVAL_MS, sweep_timer, w);
    for (;;) {
        /* 1 ms ceiling: read-window batching ticks off this loop */
        loop_run(w->loop, 1);
        pg_pool_tick(w->pg);
    }
}

static void on_accept(void *user, loop_fd *self, unsigned events) {
    (void)self;
    srv_worker *w = user;
    if (!(events & LOOP_IN)) return;

    int one = 1;
    for (int i = 0; i < ACCEPT_BURST; i++) {
        int fd = accept4(w->listen_fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
        if (fd < 0) {
            if (errno == EINTR || errno == ECONNABORTED) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            if (errno == EMFILE || errno == ENFILE || errno == ENOBUFS ||
                errno == ENOMEM) {
                /* EMFILE: free one idle conn, else leave the queue to the
                 * kernel */
                if (conn_close_one_idle(w)) continue;
                return;
            }
            return;             // transient: level-triggered retry
        }
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        (void)conn_create(w, fd, w->hooks);
    }
}
