/* coro.h - libco coroutine executor.
 *
 * Every request's route() and every completion callback (PG batch, bcrypt,
 * FIFO failure) runs on a pooled coroutine stack instead of deep in the
 * event loop's C stack. The event loop stays the sole owner of all I/O;
 * coroutines only carry handler state across awaits.
 *
 * Suspension points:
 *   - pg_go()          yields until the batch completes (or FIFO fails)
 *   - req_bcrypt_submit() yields until the hash/verify job is done
 *
 * The pool is per worker (libco environments are thread-local). When the
 * pool is exhausted, requests run inline exactly as the pre-coroutine
 * engine did: every await point checks r->co and only yields when the
 * request is attached to a coroutine. Both modes are fully equivalent. */
#pragma once
#include "conduit.h"                /* C-linkage declarations built in */

#ifdef __cplusplus
extern "C" {
#endif

/* per-worker init: allocate the slot table + freelist (no stacks yet:
 * libco coroutines are created lazily on the worker's own thread) */
void coro_pool_init(worker_t *w);

/* run route() on a coroutine (inline fallback when the pool is exhausted) */
void coro_dispatch(req_t *r);

/* resume r's coroutine so it runs r->cb() (PG completion / FIFO failure) */
void req_kick(req_t *r);

/* resume the requesting coroutine so it runs j->done() */
void bcrypt_kick(bcrypt_job_t *j);

/* bcrypt_submit + suspend until the job completes (no-op inline) */
void req_bcrypt_submit(req_t *r, bcrypt_job_t *j);

/* C-linkage wrappers around libco (whose headers are C++-only) */
void coro_yield(void);              /* suspend to the resumer (loop) */
void coro_resume_co(void *co);      /* start/resume a coroutine */

#ifdef __cplusplus
}
#endif
