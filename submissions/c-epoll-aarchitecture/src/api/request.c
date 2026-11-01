#include "api/api.h"

#include <string.h>

#include "crypto/offload.h"
#include "core/loop.h"
#include "util.h"

void req_hold(api_request *r) {
    int prev = __atomic_fetch_add(&r->refs, 1, __ATOMIC_ACQ_REL);
    CHECK(prev > 0, "request hold after release");
}

bool req_release(api_request *r) {
    int prev = __atomic_sub_fetch(&r->refs, 1, __ATOMIC_ACQ_REL);
    CHECK(prev >= 0, "request release underflow");
    if (prev > 0) return true;

    json_free(r->body);
    arena_reset(&r->arena);
    buf_free(&r->out);
    free(r);
    return false;
}

void *req_alloc(api_request *r, size_t n) {
    return arena_alloc(&r->arena, n);
}

void *req_calloc(api_request *r, size_t n) {
    return arena_calloc(&r->arena, n);
}

char *req_str(api_request *r, const char *s) {
    return arena_strdup(&r->arena, s);
}

char *req_strn(api_request *r, const char *s, size_t n) {
    return arena_str(&r->arena, s, n);
}

const char *req_ll(api_request *r, long long value) {
    return arena_printf(&r->arena, "%lld", value);
}

/* pg trampolines: one arena-allocated wrap holds r across the callback and
 * drops that hold once cb returns, so the ref cb sees is stable even if the
 * conn is closed mid-render */
struct api_pg {
    api_request *r;
    void *ctx;
    pg_cb cb;
};

static void api_pg_trampoline(void *arg, pg_status status,
                              const pg_result *res) {
    struct api_pg *w = arg;
    w->cb(w->ctx, status, res);
    req_release(w->r);
}

void api_pg_read(api_request *r, pg_read_kind kind, const pg_read *read,
                 void *ctx, pg_cb cb) {
    struct api_pg *w = req_calloc(r, sizeof *w);
    w->r = r;
    w->ctx = ctx;
    w->cb = cb;
    req_hold(r);
    pg_read_submit(r->worker->pg, kind, read, w, api_pg_trampoline);
}

void api_pg_write(api_request *r, pg_stmt stmt, int nparams,
                  const char *const *params, void *ctx, pg_cb cb) {
    struct api_pg *w = req_calloc(r, sizeof *w);
    w->r = r;
    w->ctx = ctx;
    w->cb = cb;
    req_hold(r);
    pg_submit(r->worker->pg, stmt, nparams, params, w, api_pg_trampoline);
}

/* deferred finish runs on the conn's loop; refs there = posted hold + conn
 * base (or just the hold if abandon already dropped the base) */
static void req_respond_finish(void *arg) {
    api_request *r = arg;
    if (r->dead) {
        req_release(r);
        return;
    }
    srv_conn *c = r->conn;
    c->request = NULL;
    if (r->respond_empty) conn_respond_empty(c, r->respond_status);
    else conn_respond_move(c, r->respond_status, &r->out);
    req_release(r);
    req_release(r);
}

static void req_respond_now(api_request *r, int status, bool empty) {
    CHECK(!r->responded, "double response");

    if (loop_current() != r->worker->loop) {
        r->responded = true;
        r->respond_status = status;
        r->respond_empty = empty;
        req_hold(r);
        crypto_post(r->worker->id, req_respond_finish, r);
        return;
    }

    CHECK(!r->dead, "response on an abandoned request");

    srv_conn *c = r->conn;
    r->responded = true;
    c->request = NULL;
    if (empty) conn_respond_empty(c, status);
    else conn_respond_move(c, status, &r->out);
    req_release(r);
}

void req_respond(api_request *r, int status) {
    req_respond_now(r, status, false);
}

void req_respond_empty(api_request *r, int status) {
    req_respond_now(r, status, true);
}

void req_fail(api_request *r, int status, const char *message) {
    CHECK(!r->responded, "failure after response");
    buf_clear(&r->out);
    BUF_LIT(&r->out, "{\"errors\":{\"body\":[");
    json_quote(&r->out, message);
    BUF_LIT(&r->out, "]}}");
    req_respond(r, status);
}

void req_db_fail(api_request *r) {
    req_fail(r, 500, "database unavailable");
}

void api_abandon(srv_conn *c) {
    api_request *r = c->request;
    if (!r) return;
    c->request = NULL;
    r->dead = true;
    (void)req_release(r);
}
