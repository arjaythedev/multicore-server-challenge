#include "api/api.h"

#include "api/handlers.h"
#include "api/render.h"

static void profile_loaded(void *ctx, pg_status status,
                           const pg_result *res) {
    api_request *r = ctx;
    if (r->dead) return;

    if (status == PG_ROWS && pg_result_rows(res) >= 1) {
        profile_view view;
        profile_view_load(&view, res, 0);
        buf_clear(&r->out);
        render_profile(&r->out, &view);
        req_respond(r, 200);
        return;
    }
    req_fail(r, status == PG_ERROR ? 500 : 404, "profile not found");
}

void handle_profile_get(api_request *r) {
    const pg_read read = {
        .viewer = r->viewer,
        .key = r->seg[0],
    };
    api_pg_read(r, PG_READ_PROFILE, &read, r, profile_loaded);
}

static void follow_begin(api_request *r, bool follow) {
    const char *params[2] = { req_ll(r, r->viewer), r->seg[0] };
    api_pg_write(r,
                 follow ? PG_STMT_FOLLOWS_INSERT : PG_STMT_FOLLOWS_DELETE,
                 2, params, r, profile_loaded);
}

void handle_profile_follow(api_request *r) {
    follow_begin(r, true);
}

void handle_profile_unfollow(api_request *r) {
    follow_begin(r, false);
}
