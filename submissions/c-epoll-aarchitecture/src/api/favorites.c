#include "api/api.h"

#include "api/handlers.h"
#include "api/render.h"

/* the write returns the full article (count already adjusted), so there is no
 * read-back: one round trip per favorite */

static void favorite_written(void *ctx, pg_status status,
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
    article_view view;
    article_view_load(&view, res, 0, true);
    buf_clear(&r->out);
    BUF_LIT(&r->out, "{\"article\":");
    render_article(&r->out, &view);
    buf_putc(&r->out, '}');
    req_respond(r, 200);
}

static void favorite_begin(api_request *r, bool add) {
    const char *params[2] = { req_ll(r, r->viewer), r->seg[0] };
    api_pg_write(r,
                 add ? PG_STMT_FAVORITES_INSERT : PG_STMT_FAVORITES_DELETE,
                 2, params, r, favorite_written);
}

void handle_favorite_add(api_request *r) {
    favorite_begin(r, true);
}

void handle_favorite_remove(api_request *r) {
    favorite_begin(r, false);
}
