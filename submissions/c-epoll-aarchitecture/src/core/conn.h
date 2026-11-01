#ifndef CORE_CONN_H
#define CORE_CONN_H

#include <stdbool.h>
#include <stdint.h>

#include "core/buf.h"
#include "core/http.h"
#include "core/loop.h"

/* one keep-alive client conn.
 * CONN_OPEN: no req in flight, parsing incoming
 * CONN_REQUEST: api owns one req, bytes keep buffering (pipelining)
 * CONN_RESPONSE: response queued/flushing, parsing waits
 * response queued before req released */

typedef struct srv_conn srv_conn;
struct srv_worker;

typedef struct conn_hooks {
    void (*on_request)(srv_conn *c, const http_request *rq, const char *body,
                       size_t body_len);
    /* called once if conn dies before the response completes; api releases its
     * ref here */
    void (*on_abandon)(srv_conn *c);
} conn_hooks;

typedef enum conn_state {
    CONN_OPEN = 0,
    CONN_REQUEST,
    CONN_RESPONSE,
} conn_state;

struct srv_conn {
    int fd;
    const conn_hooks *hooks;
    struct srv_worker *worker;
    loop_fd *ev;

    buf in;
    size_t in_start;            // consumed prefix of in
    buf out;
    size_t out_body_off;        // consumed prefix of out_body
    buf out_body;               // moved response body, sent via writev
    size_t request_len;         // in-flight req bytes (header+body)

    http_request rq;            // valid for req lifetime
    conn_state state;
    bool close_after;           // close after queued response flushes
    void *request;              // api req object, if any

    int64_t last_active_ms;
    struct srv_conn *next, *prev;
};

// on failure: fd closed, NULL returned
srv_conn *conn_create(struct srv_worker *worker, int fd,
                      const conn_hooks *hooks);
void conn_close(srv_conn *c);

void conn_sweep(struct srv_worker *w);
// close one CONN_OPEN conn; 1 if one freed
int conn_close_one_idle(struct srv_worker *w);

/* queue full response + arm write event; caller has exactly 1 req in flight.
 * conn_respond copies the body (static strings, rejects);
 * conn_respond_move takes ownership of `body` and frees it after the flush,
 * sparing the copy */
void conn_respond(srv_conn *c, int status, const char *body, size_t body_len);
void conn_respond_move(srv_conn *c, int status, buf *body);
void conn_respond_empty(srv_conn *c, int status);

#endif
