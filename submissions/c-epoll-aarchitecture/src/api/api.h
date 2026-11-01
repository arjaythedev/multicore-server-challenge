#ifndef API_API_H
#define API_API_H

#include <stdbool.h>
#include <stddef.h>

#include "api/route.h"
#include "core/arena.h"
#include "core/buf.h"
#include "core/conn.h"
#include "core/http.h"
#include "core/json.h"
#include "core/server.h"
#include "pg/pg.h"

/* one in-flight req: refcounted (conn base ref, pending pg stmt, pending bcrypt
 * job); handler state arena-alloc'd, reached via callback ctx; rq = conn->rq */

typedef struct api_request {
    srv_conn *conn;
    struct srv_worker *worker;
    const api_route *route;
    const http_request *rq;

    arena arena;
    buf out;
    json_node *body;

    const char *seg[API_MAX_CAPTURES];  // arena copies of captures

    long long viewer;                   // viewer id, 0 anon
    int refs;                           // atomic: base conn ref + holds
    bool dead;
    bool responded;
    int respond_status;                 // deferred response (pool thread)
    bool respond_empty;
} api_request;

// conn_hooks impl (main.c wires these)
void api_begin(srv_conn *c, const http_request *rq, const char *body,
               size_t body_len);
void api_abandon(srv_conn *c);

void req_hold(api_request *r);
// drop one ref; false = last one, r freed
bool req_release(api_request *r);

/* pg submits with r referenced across the callback: the trampoline forwards to
 * cb and drops the hold after it returns, so a conn close can never free r
 * while its result renders on the offload pool. ctx is cb's, not r's */
void api_pg_read(api_request *r, pg_read_kind kind, const pg_read *read,
                 void *ctx, pg_cb cb);
void api_pg_write(api_request *r, pg_stmt stmt, int nparams,
                  const char *const *params, void *ctx, pg_cb cb);

/* queues the response and consumes the req; usable from any thread (a pool
 * thread defers the write back to the conn's loop) */
void req_respond(api_request *r, int status);
void req_respond_empty(api_request *r, int status);
void req_fail(api_request *r, int status, const char *message);
void req_db_fail(api_request *r);

void *req_alloc(api_request *r, size_t n);
void *req_calloc(api_request *r, size_t n);
char *req_str(api_request *r, const char *s);
char *req_strn(api_request *r, const char *s, size_t n);
const char *req_ll(api_request *r, long long value);

typedef enum {
    FIELD_ABSENT = 0,
    FIELD_OK = 1,
    FIELD_INVALID = -1,
} field_result;

// body's {"wrapper":{...}} object; NULL if missing/misshaped -> caller 422
const json_node *body_object(const api_request *r, const char *wrapper);

/* null = ABSENT, non-string (empty, body_string) = INVALID; returned ptrs
 * borrow the parsed body */
field_result body_string(const json_node *obj, const char *key,
                         const char **out);
field_result body_string_allow_empty(const json_node *obj, const char *key,
                                     const char **out);

/* json str array -> pg text[] literal; absent/null = ABSENT, non-array or
 * empty/non-str elem = INVALID; arena-alloc'd */
field_result body_text_array(api_request *r, const json_node *value,
                             char **out);

typedef enum {
    QUERY_ABSENT = 0,
    QUERY_OK = 1,
    QUERY_INVALID = -1,
} query_result;

query_result query_string(const char *query, const char *key, char *out,
                          size_t cap);
query_result query_integer(const char *query, const char *key, long long *out);

#endif
