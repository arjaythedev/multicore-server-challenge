/* coro.cpp - libco coroutine executor (see coro.h).
 *
 * Compiled as C++ only because Tencent libco's headers are C++; the code
 * itself is C-style. Each pooled slot owns one libco coroutine with a
 * 64 KiB stack. The trampoline is an infinite command loop:
 *
 *   resume #1  -> cmd CO_ROUTE   -> route(r)                  -> park
 *   resume #n  -> cmd CO_CB      -> r->cb(r)                  -> park
 *            or     cmd CO_BCRYPT -> j->done(j)             -> park
 *
 * A resume that lands on a *nested* yield (inside pg_go() or
 * req_bcrypt_submit()) first unwinds that await, then the loop runs the
 * newly queued command in the same resume. So one resume always equals:
 * "finish what you were doing, then do the next thing".
 *
 * Retirement: when the request has been replied, the slot detaches it,
 * returns the arena to the pool and parks. srv_reply() deliberately does
 * not release coroutine-attached requests; the trampoline owns that. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "coro.h"
#include "co_routine.h"

enum { CO_IDLE = 0, CO_ROUTE = 1, CO_CB = 2, CO_BCRYPT = 3 };

#define CO_STACK (64 * 1024)

typedef struct {
    stCoRoutine_t *co;
    req_t *req;
    bcrypt_job_t *job;
    int cmd;
    int live;                   /* co_create succeeded */
} coslot_t;

typedef struct {
    coslot_t *slots;
    int used;                   /* slots created so far */
    int cap;
    int *freev;
    int nfree;
} copool_t;

static copool_t *g_pools;

static inline copool_t *pool_of(worker_t *w)
{
    if (!g_pools) g_pools = (copool_t *)calloc((size_t)cfg.threads, sizeof(copool_t));
    return &g_pools[w->idx];
}

void coro_pool_init(worker_t *w)
{
    copool_t *p = pool_of(w);
    if (p->slots) return;               /* already initialized */
    p->cap = cfg.co_max;
    p->slots = (coslot_t *)calloc((size_t)p->cap, sizeof(coslot_t));
    p->freev = (int *)malloc(sizeof(int) * (size_t)p->cap);
    p->nfree = 0;
    p->used = 0;
}

static void slot_retire(coslot_t *s)
{
    req_t *r = s->req;
    worker_t *w = r->w;
    copool_t *p = pool_of(w);
    int idx = (int)(s - p->slots);

    r->co = NULL;
    s->req = NULL;
    s->job = NULL;
    req_release(r);
    if (idx >= 0 && idx < p->cap && p->nfree < p->cap)
        p->freev[p->nfree++] = idx;
}

static void post_route(req_t *r)
{
    if (!r->replied && !r->pending && r->nstmts == 0) {
        static const char e500[] = "{\"errors\":{\"body\":[\"internal error\"]}}";
        srv_reply(r, 500, e500, sizeof e500 - 1);
    }
}

static void *tramp(void *arg)
{
    coslot_t *s = (coslot_t *)arg;
    for (;;) {
        /* capture-then-consume: a resumer may have queued a new command
         * while we were unwinding a nested yield — never clobber it */
        int cmd = s->cmd;
        req_t *r = s->req;
        bcrypt_job_t *job = s->job;
        s->cmd = CO_IDLE;
        s->job = NULL;

        if (cmd == CO_ROUTE) {
            route(r);
            post_route(r);
        } else if (cmd == CO_CB) {
            if (r->cb) r->cb(r);
        } else if (cmd == CO_BCRYPT) {
            if (job->done) job->done(job);
        }

        if (s->req && s->req->replied) slot_retire(s);
        if (s->cmd == CO_IDLE) co_yield_ct();   /* park only when nothing queued */
    }
    return NULL;                        /* never reached */
}

void coro_dispatch(req_t *r)
{
    copool_t *p = pool_of(r->w);
    coslot_t *s = NULL;

    if (p->nfree) {
        s = &p->slots[p->freev[--p->nfree]];
    } else if (p->used < p->cap) {
        s = &p->slots[p->used];
        stCoRoutineAttr_t attr;
        memset(&attr, 0, sizeof attr);
        attr.stack_size = CO_STACK;
        if (co_create(&s->co, &attr, tramp, s) < 0) {
            s = NULL;
        } else {
            s->live = 1;
            p->used++;
        }
    }

    if (!s) {                           /* pool exhausted: inline, pre-coroutine flow */
        route(r);
        post_route(r);
        return;
    }

    s->cmd = CO_ROUTE;
    s->req = r;
    s->job = NULL;
    r->co = s;
    co_resume(s->co);
}

void req_kick(req_t *r)
{
    if (r->co) {
        /* always resume: the trampoline runs r->cb (or nothing when NULL)
         * and retires the request if it ended up replied */
        coslot_t *s = (coslot_t *)r->co;
        s->cmd = CO_CB;
        co_resume(s->co);
    } else if (r->cb) {
        r->cb(r);
    } else if (!r->replied) {
        static const char e500[] = "{\"errors\":{\"body\":[\"internal error\"]}}";
        srv_reply(r, 500, e500, sizeof e500 - 1);
    }
}

void bcrypt_kick(bcrypt_job_t *j)
{
    req_t *r = (req_t *)j->req;
    if (r && r->co) {
        coslot_t *s = (coslot_t *)r->co;
        s->cmd = CO_BCRYPT;
        s->job = j;
        s->req = r;
        co_resume(s->co);
    } else if (j->done) {
        j->done(j);
    }
}

void req_bcrypt_submit(req_t *r, bcrypt_job_t *j)
{
    bcrypt_submit(j);
    if (r->co) coro_yield();           /* resumes when bcrypt_kick queues CO_BCRYPT */
}

/* C-linkage wrappers for the two libco primitives C files use */
extern "C" void coro_yield(void) { co_yield_ct(); }
extern "C" void coro_resume_co(void *c) { co_resume((stCoRoutine_t *)c); }
