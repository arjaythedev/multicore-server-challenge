#include "api/api.h"

#include <stdlib.h>

#include "api/handlers.h"
#include "api/render.h"

static void comment_listed(void *ctx, pg_status status,
                           const pg_result *res) {
    api_request *r = ctx;
    if (r->dead) return;
    if (status == PG_ERROR) {
        req_db_fail(r);
        return;
    }
    if (pg_result_rows(res) < 1) {
        req_fail(r, 404, "article not found");
        return;
    }

    buf_clear(&r->out);
    BUF_LIT(&r->out, "{\"comments\":[");
    int rows = pg_result_rows(res);
    int written = 0;
    for (int i = 0; i < rows; i++) {
        // article w/o comments is all-NULL row to show it exists
        if (pg_result_is_null(res, i, 0)) continue;
        if (written++) buf_putc(&r->out, ',');
        comment_view view;
        comment_view_load(&view, res, i, true);
        render_comment(&r->out, &view);
    }
    BUF_LIT(&r->out, "]}");
    req_respond(r, 200);
}

static void comment_created(void *ctx, pg_status status,
                            const pg_result *res) {
    api_request *r = ctx;
    if (r->dead) return;

    if (status == PG_ROWS && pg_result_rows(res) >= 1) {
        comment_view view;
        comment_view_load(&view, res, 0, false);
        buf_clear(&r->out);
        BUF_LIT(&r->out, "{\"comment\":");
        render_comment(&r->out, &view);
        buf_putc(&r->out, '}');
        req_respond(r, 201);
        return;
    }
    req_fail(r, status == PG_ERROR ? 500 : 404, "article not found");
}

static void comment_deleted(void *ctx, pg_status status,
                            const pg_result *res) {
    api_request *r = ctx;
    if (r->dead) return;

    if (status == PG_ERROR) {
        req_db_fail(r);
        return;
    }
    if (pg_result_rows(res) < 1) {
        req_fail(r, 404, "comment not found");
        return;
    }
    if (strtoll(pg_result_value(res, 0, 0), NULL, 10) != r->viewer) {
        req_fail(r, 403, "not the comment author");
        return;
    }
    req_respond_empty(r, 204);
}

void handle_comments_list(api_request *r) {
    const pg_read read = {
        .viewer = r->viewer,
        .key = r->seg[0],
    };
    api_pg_read(r, PG_READ_COMMENTS, &read, r, comment_listed);
}

void handle_comments_create(api_request *r) {
    const json_node *comment = body_object(r, "comment");
    if (!comment) {
        req_fail(r, 422, "comment object required");
        return;
    }
    const char *body;
    if (body_string(comment, "body", &body) != FIELD_OK) {
        req_fail(r, 422, "comment body is required");
        return;
    }

    const char *params[3] = { req_ll(r, r->viewer), r->seg[0], body };
    api_pg_write(r, PG_STMT_COMMENTS_INSERT, 3, params, r,
              comment_created);
}

void handle_comment_delete(api_request *r) {
    const char *comment_id = r->seg[1];

    /* id must be numeric: it goes to pg as a bigint */
    size_t digits = 0;
    for (const char *p = comment_id; *p; p++, digits++) {
        if (*p < '0' || *p > '9') {
            req_fail(r, 404, "comment not found");
            return;
        }
    }
    if (digits > 19) {          // bigint: max 19 digits
        req_fail(r, 404, "comment not found");
        return;
    }

    const char *params[3] = { req_ll(r, r->viewer), r->seg[0], comment_id };
    api_pg_write(r, PG_STMT_COMMENTS_DELETE, 3, params, r,
              comment_deleted);
}
