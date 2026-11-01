/* Planned reads: what a worker asks the drain for (IPC_PLAN), and what comes back. The drain answers with the
 * finished response body, so the worker only adds the HTTP head. */
#pragma once
#include "buf.h"
#include "pg_wire.h"

enum plan_kind {
    PK_LIST,       /* GET /api/articles (filter: none, tag, author or favorited) */
    PK_FEED,       /* GET /api/articles/feed */
    PK_ARTICLE,    /* GET /api/articles/:slug */
    PK_COMMENTS,   /* GET /api/articles/:slug/comments */
    PK_PROFILE,    /* GET /api/profiles/:username */
    PK_TAGS,       /* GET /api/tags */
    PK_KINDS
};

enum plan_filter { PF_NONE, PF_TAG, PF_AUTHOR, PF_FAVORITED };

struct plan_req {
    uint8_t kind, filter;
    uint16_t pad;
    uint32_t keylen;       /* the tag, author, favorited user, slug or username, in key[] */
    int64_t viewer;        /* 0: anonymous */
    int64_t limit, offset;
    char key[];
};

struct plan_reply {
    uint16_t status;
    uint16_t pad;
    uint32_t len;          /* JSON body bytes that follow */
    char body[];
};

/* drain.c hands planned requests to planner.c and lends it a Postgres connection per plan. */
struct dconn;
struct plan;
void planner_init(void);
void planner_add(int worker, uint64_t token, const struct plan_req *pr, uint32_t len);
/* Microseconds until the oldest waiting request is due, 0 if one is due now, -1 if nothing waits. */
int64_t planner_due_in(int64_t now_us, int64_t wait_us);
/* Takes up to the batch limit of waiting requests into a plan and writes its phase A to out; NULL if none. */
struct plan *planner_start(struct buf *out);
/* A message of the plan's current phase. On ReadyForQuery it returns true, after writing phase B to out (when
 * there is one) or answering every request and freeing the plan (*done set). */
bool planner_msg(struct plan *p, const struct pg_msg *m, struct buf *out, bool *done);
