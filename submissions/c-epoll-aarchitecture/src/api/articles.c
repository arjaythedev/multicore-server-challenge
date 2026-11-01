#include "api/api.h"

#include <stdlib.h>
#include <string.h>

#include "api/handlers.h"
#include "api/render.h"
#include "config.h"
#include "core/json.h"

#define ARTICLE_SQLSTATE_UNIQUE "23505"   // unique_violation

typedef enum page_kind {
    PAGE_ALL = 0,
    PAGE_TAG,
    PAGE_AUTHOR,
    PAGE_FAVORITED,
    PAGE_FEED,
} page_kind;

typedef struct page_state {
    api_request *r;
    page_kind kind;
    long long limit;
    long long offset;
    const char *filter;
} page_state;

static void article_loaded(void *ctx, pg_status status,
                           const pg_result *res) {
    api_request *r = ctx;
    if (r->dead) return;

    if (status == PG_ROWS && pg_result_rows(res) >= 1) {
        article_view view;
        article_view_load(&view, res, 0, true);
        buf_clear(&r->out);
        BUF_LIT(&r->out, "{\"article\":");
        render_article(&r->out, &view);
        buf_putc(&r->out, '}');
        req_respond(r, 200);
        return;
    }
    req_fail(r, status == PG_ERROR ? 500 : 404, "article not found");
}

static void article_created(void *ctx, pg_status status,
                            const pg_result *res) {
    api_request *r = ctx;
    if (r->dead) return;

    if (status == PG_ROWS && pg_result_rows(res) >= 1) {
        article_view view;
        article_view_load(&view, res, 0, true);
        buf_clear(&r->out);
        BUF_LIT(&r->out, "{\"article\":");
        render_article(&r->out, &view);
        buf_putc(&r->out, '}');
        req_respond(r, 201);
        return;
    }
    if (status == PG_ERROR &&
        strcmp(pg_result_sqlstate(res), ARTICLE_SQLSTATE_UNIQUE) == 0) {
        req_fail(r, 422, "article title already exists");
        return;
    }
    req_fail(r, status == PG_ERROR ? 500 : 404, "article not found");
}

static void page_loaded(void *ctx, pg_status status, const pg_result *res) {
    page_state *state = ctx;
    api_request *r = state->r;
    if (r->dead) return;
    if (status == PG_ERROR) {
        req_db_fail(r);
        return;
    }

    int rows = pg_result_rows(res);
    /* count is LEFT JOINed onto the page: empty page = one all-NULL row */
    int articles = rows;
    if (rows == 1 && pg_result_is_null(res, 0, 0)) articles = 0;

    long long count = 0;
    int fields = pg_result_fields(res);
    if (rows > 0 && fields > 0)
        count = strtoll(pg_result_value(res, 0, fields - 1), NULL, 10);

    buf_clear(&r->out);
    BUF_LIT(&r->out, "{\"articles\":[");
    for (int i = 0; i < articles; i++) {
        if (i) buf_putc(&r->out, ',');
        article_view view;
        article_view_load(&view, res, i, false);
        render_article(&r->out, &view);
    }
    buf_printf(&r->out, "],\"articlesCount\":%lld}", count);
    req_respond(r, 200);
}

static void page_begin(page_state *state) {
    api_request *r = state->r;
    const char *key = state->filter ? state->filter : "";

    unsigned char list_kind;
    switch (state->kind) {
    case PAGE_TAG:
        list_kind = PG_LIST_TAG;
        break;
    case PAGE_AUTHOR:
        list_kind = PG_LIST_AUTHOR;
        break;
    case PAGE_FAVORITED:
        list_kind = PG_LIST_FAVORITED;
        break;
    case PAGE_FEED:
        list_kind = PG_LIST_FEED;
        break;
    case PAGE_ALL:
    default:
        list_kind = PG_LIST_ALL;
        key = "";
        break;
    }

    const pg_read read = {
        .viewer = r->viewer,
        .limit = (int)state->limit,
        .offset = state->offset,
        .key = key,
        .list_kind = list_kind,
    };
    api_pg_read(r, PG_READ_LIST, &read, state, page_loaded);
}

void handle_articles_list(api_request *r) {
    char tag[FILTER_MAX] = "";
    char author[FILTER_MAX] = "";
    char favorited[FILTER_MAX] = "";
    query_result query_tag =
        query_string(r->rq->query, "tag", tag, sizeof tag);
    query_result query_author =
        query_string(r->rq->query, "author", author, sizeof author);
    query_result query_favorited =
        query_string(r->rq->query, "favorited", favorited, sizeof favorited);

    long long limit = PAGE_LIMIT_DEFAULT;
    long long offset = 0;
    query_result query_limit =
        query_integer(r->rq->query, "limit", &limit);
    query_result query_offset =
        query_integer(r->rq->query, "offset", &offset);

    if (query_tag == QUERY_INVALID || query_author == QUERY_INVALID ||
        query_favorited == QUERY_INVALID || query_limit == QUERY_INVALID ||
        query_offset == QUERY_INVALID) {
        req_fail(r, 422, "invalid query parameters");
        return;
    }
    if (limit < 1 || limit > PAGE_LIMIT_MAX || offset > OFFSET_MAX) {
        req_fail(r, 422, "invalid query parameters");
        return;
    }

    page_state *state = req_calloc(r, sizeof *state);
    state->r = r;
    state->limit = limit;
    state->offset = offset;
    state->kind = PAGE_ALL;

    // precedence tag > author > favorited; empty = absent
    if (tag[0]) {
        state->kind = PAGE_TAG;
        state->filter = req_str(r, tag);
    } else if (author[0]) {
        state->kind = PAGE_AUTHOR;
        state->filter = req_str(r, author);
    } else if (favorited[0]) {
        state->kind = PAGE_FAVORITED;
        state->filter = req_str(r, favorited);
    }
    page_begin(state);
}

void handle_articles_feed(api_request *r) {
    long long limit = PAGE_LIMIT_DEFAULT;
    long long offset = 0;
    query_result query_limit =
        query_integer(r->rq->query, "limit", &limit);
    query_result query_offset =
        query_integer(r->rq->query, "offset", &offset);

    if (query_limit == QUERY_INVALID || query_offset == QUERY_INVALID ||
        limit < 1 || limit > PAGE_LIMIT_MAX || offset > OFFSET_MAX) {
        req_fail(r, 422, "invalid query parameters");
        return;
    }

    page_state *state = req_calloc(r, sizeof *state);
    state->r = r;
    state->kind = PAGE_FEED;
    state->limit = limit;
    state->offset = offset;
    page_begin(state);
}

void handle_article_get(api_request *r) {
    const pg_read read = {
        .viewer = r->viewer,
        .key = r->seg[0],
    };
    api_pg_read(r, PG_READ_ARTICLE_SLUG, &read, r,
                   article_loaded);
}

void handle_article_create(api_request *r) {
    const json_node *article = body_object(r, "article");
    if (!article) {
        req_fail(r, 422, "article object required");
        return;
    }

    const char *title;
    const char *description;
    const char *body;
    if (body_string(article, "title", &title) != FIELD_OK ||
        body_string(article, "description", &description) != FIELD_OK ||
        body_string(article, "body", &body) != FIELD_OK) {
        req_fail(r, 422, "title, description and body are required");
        return;
    }

    const json_node *tag_value = json_get(article, "tagList");
    char *tag_array = NULL;
    field_result tags = body_text_array(r, tag_value, &tag_array);
    if (tags == FIELD_INVALID) {
        if (tag_value && tag_value->kind != JSON_NULL &&
            tag_value->kind != JSON_ARR)
            req_fail(r, 422, "tagList must be an array");
        else
            req_fail(r, 422, "tagList entries must be strings");
        return;
    }

    const char *params[5] = { req_ll(r, r->viewer), title, description, body,
                              tag_array };
    api_pg_write(r, PG_STMT_ARTICLE_INSERT, 5, params, r,
              article_created);
}

static void article_updated(void *ctx, pg_status status,
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
    /* the UPDATE fired only for the author: a NULL RETURNING row means the
     * viewer is not it. the row already carries the post-update columns */
    if (pg_result_is_null(res, 0, 0)) {
        req_fail(r, 403, "not the article author");
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

static void article_deleted(void *ctx, pg_status status,
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
    if (strtoll(pg_result_value(res, 0, 0), NULL, 10) != r->viewer) {
        req_fail(r, 403, "not the article author");
        return;
    }
    req_respond_empty(r, 204);
}

void handle_article_update(api_request *r) {
    const json_node *article = body_object(r, "article");
    if (!article) {
        req_fail(r, 422, "article object required");
        return;
    }

    const char *title = NULL;
    const char *description = NULL;
    const char *body = NULL;
    if (body_string(article, "title", &title) == FIELD_INVALID ||
        body_string(article, "description", &description) == FIELD_INVALID ||
        body_string(article, "body", &body) == FIELD_INVALID) {
        req_fail(r, 422, "invalid fields");
        return;
    }

    const char *params[5] = { req_ll(r, r->viewer), r->seg[0], title,
                              description, body };
    api_pg_write(r, PG_STMT_ARTICLE_UPDATE, 5, params, r,
              article_updated);
}

void handle_article_delete(api_request *r) {
    const char *params[2] = { req_ll(r, r->viewer), r->seg[0] };
    api_pg_write(r, PG_STMT_ARTICLE_DELETE, 2, params, r,
              article_deleted);
}
