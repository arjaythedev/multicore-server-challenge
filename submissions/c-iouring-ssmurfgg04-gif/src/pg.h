/* pg.h - async PostgreSQL wire client (see pg.c) */
#pragma once
#include "conduit.h"

typedef struct pgconn pgconn_t;

/* connection states */
#define PGS_CONNECTING 0
#define PGS_STARTUP 1          /* startup sent */
#define PGS_SASL_SENT 2        /* client-first sent */
#define PGS_FINAL_SENT 3       /* client-final sent */
#define PGS_PREP 4             /* Parse batch sent */
#define PGS_READY 5
#define PGS_DEAD 6

struct pgconn {
    int fd;
    worker_t *w;
    int id;
    int state;
    int inflight;               /* requests in flight on this connection */
    req_t *q_head, *q_tail;     /* FIFO of in-flight batches, in Sync order */
    buf_t out, in;
    size_t out_off, in_off;
    char stage[16384];          /* recv staging (ring-completion target) */
    int recv_armed;
    uint64_t born_ms;           /* when the current connect attempt started */
    /* scram */
    char client_nonce_b64[32];
    char server_first[512];
    uint8_t saltbin[16];
    int sasl_iters;
    int authed;                 /* backend accepted us */
    int want_out;               /* epoll: EPOLLOUT pending (partial send) */
};

void pg_connect(pgconn_t *pc);
void pg_reconnect(pgconn_t *pc);
void pg_on_readable(pgconn_t *pc);
void pg_on_writable(pgconn_t *pc);
void pg_tick(worker_t *w);      /* reconnect DEAD connections */
void pg_fifo_check(worker_t *w); /* fail requests stuck too long in the FIFO */
void pg_advance_pgconn(pgconn_t *pc); /* parse whatever has arrived */
int pg_total_conns(void);
