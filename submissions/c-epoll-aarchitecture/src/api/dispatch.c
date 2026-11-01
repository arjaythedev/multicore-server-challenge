#include "api/api.h"

#include <string.h>

#include "api/handlers.h"
#include "api/route.h"
#include "core/server.h"
#include "crypto/jwt.h"
#include "util.h"

/* one ctx per req: conn owns the base ref, each async step resuming later its
 * own */

static void run_handler(api_request *r) {
    r->route->handler(r);
}

static void authenticate(api_request *r) {
    switch (r->route->auth) {
    case AUTH_IGNORE:
        run_handler(r);
        return;
    case AUTH_REQUIRED:
        if (r->rq->auth == AUTH_NONE) {
            req_fail(r, 401, "Unauthorized");
            return;
        }
        break;
    case AUTH_OPTIONAL:
        if (r->rq->auth == AUTH_NONE) {
            run_handler(r);
            return;
        }
        break;
    }

    if (r->rq->auth != AUTH_TOKEN) {
        req_fail(r, 401, "Unauthorized");
        return;
    }

    long long viewer = 0;
    if (!jwt_verify(&viewer, r->rq->auth_token, r->worker->jwt_secret)) {
        req_fail(r, 401, "Unauthorized");
        return;
    }
    r->viewer = viewer;

    /* no user-existence probe: viewer-keyed statements return zero rows for a
     * deleted user and the routes map that to 401 */
    run_handler(r);
}

void api_begin(srv_conn *c, const http_request *rq, const char *body,
               size_t body_len) {
    api_capture captures[API_MAX_CAPTURES];
    unsigned ncaptures = 0;
    const api_route *route =
        route_match(rq->method, rq->path, captures, &ncaptures);

    if (!route) {
        static const char NOT_FOUND[] =
            "{\"errors\":{\"body\":[\"not found\"]}}";
        conn_respond(c, 404, NOT_FOUND, sizeof NOT_FOUND - 1);
        return;
    }

    api_request *r = xcalloc(1, sizeof *r);
    r->conn = c;
    r->worker = c->worker;
    r->route = route;
    r->rq = rq;
    r->refs = 1;
    arena_init(&r->arena);
    buf_init(&r->out);
    c->request = r;

    for (unsigned i = 0; i < ncaptures; i++)
        r->seg[i] = req_strn(r, captures[i].ptr, captures[i].len);

    if (body_len > 0) {
        const char *error = NULL;
        r->body = json_parse(body, body_len, &error);
        if (!r->body) {
            req_fail(r, 422, "malformed request body");
            return;
        }
    }

    authenticate(r);
}
