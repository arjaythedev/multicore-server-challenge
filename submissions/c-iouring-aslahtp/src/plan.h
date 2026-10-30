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

/* Planned reads wait in one queue per lane, and each plan takes requests of one lane only: feeds (the dearest
 * read) and comments (their own statement and nothing to enrich) don't hold up the rest. With LANES=0 every
 * request waits in PL_SHARED. */
enum plan_lane { PL_FEED, PL_CMT, PL_SHARED, PL_N };

/* drain.c hands planned requests to planner.c and lends it a Postgres connection per plan. */
struct dconn;
struct plan;
void planner_init(void);
void planner_add(int worker, uint64_t token, const struct plan_req *pr, uint32_t len);
/* Microseconds until the lane's oldest waiting request has waited wait_us (0 if it has, or if the lane holds a
 * full plan), -1 if nothing waits on the lane. */
int64_t planner_due_in(int lane, int64_t now_us, int64_t wait_us);
/* Requests waiting on the lane. */
uint32_t planner_waiting(int lane);
/* Takes up to the batch limit of the lane's waiting requests into a plan and writes its phase A to out; NULL if
 * none. */
struct plan *planner_start(int lane, struct buf *out);
/* A message of the plan's current phase. On ReadyForQuery it returns true, after writing phase B to out (when
 * there is one) or answering every request and freeing the plan (*done set). */
bool planner_msg(struct plan *p, const struct pg_msg *m, struct buf *out, bool *done);
