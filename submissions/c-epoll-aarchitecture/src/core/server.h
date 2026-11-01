#ifndef CORE_SERVER_H
#define CORE_SERVER_H

#include "core/conn.h"
#include "core/loop.h"

/* everything a worker thread owns; no other worker touches it after startup */

struct pg_pool;
struct srv_worker;

typedef struct srv_worker {
    int id;
    loop *loop;
    struct pg_pool *pg;
    const char *jwt_secret;         // process-lifetime env value
    const conn_hooks *hooks;
    srv_conn *conns;                // live conns, for idle sweep
    int listen_fd;
    loop_fd *listen_ev;
    int read_conns;
    int write_conns;
} srv_worker;

/* loop + pg pool + SO_REUSEPORT listener */
void srv_worker_init(srv_worker *w, int id, const char *db_url, int read_conns,
                     int write_conns, int read_batch, int read_window_ms,
                     int write_group, int write_window_ms, const char *jwt_secret,
                     const char *host, const char *port, const conn_hooks *hooks);

void srv_worker_run(srv_worker *w);

#endif
