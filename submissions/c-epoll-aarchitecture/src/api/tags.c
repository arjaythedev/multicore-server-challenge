#include "api/api.h"

#include "api/handlers.h"
#include "api/render.h"
#include "core/json.h"

static void tags_loaded(void *ctx, pg_status status, const pg_result *res) {
    api_request *r = ctx;
    if (r->dead) return;
    if (status == PG_ERROR) {
        req_db_fail(r);
        return;
    }

    const char *literal = pg_result_rows(res) > 0
                              ? pg_result_value(res, 0, 0)
                              : NULL;
    buf_clear(&r->out);
    BUF_LIT(&r->out, "{\"tags\":");
    render_tag_array(&r->out, literal);
    BUF_LIT(&r->out, "}");
    req_respond(r, 200);
}

void handle_tags_list(api_request *r) {
    api_pg_read(r, PG_READ_TAGS, NULL, r, tags_loaded);
}
